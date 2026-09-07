defmodule BeamLisp.LazyMemo do
  @moduledoc false
  @load_lock {__MODULE__, :load_nif}
  @default_budget_bytes 512 * 1024 * 1024

  def ensure_loaded! do
    if nif_loaded?() do
      :ok
    else
      case :global.trans({@load_lock, self()}, &load_nif!/0) do
        :ok -> :ok
        failure -> raise "lazy memo NIF load lock failed: #{inspect(failure)}"
      end
    end
  end

  defp load_nif! do
    unless nif_loaded?() do
      path = Path.join(BeamLisp.Tiers.priv_root(), "native/lazy_memo")

      case :erlang.load_nif(String.to_charlist(path), 0) do
        :ok ->
          :ok

        {:error, reason} ->
          raise """
          BeamLisp LazySeq requires the lazy_memo native runtime.
          Cannot load #{path}: #{inspect(reason)}.
          Run `mix compile` to build it. After changing native runtime modules,
          restart the VM; live NIF upgrades are intentionally unsupported.
          """
      end
    end

    :ok
  end

  def create(state) do
    ensure_loaded!()
    deps = dependencies(state)
    bytes = estimate_bytes(state)

    # A small initial value is copied on a regular scheduler; a large one
    # (which copies megabytes into the cell) takes the dirty lane. The
    # estimate is known here, before the call, so the lane is chosen directly
    # — no reroute round-trip needed for creation.
    if bytes <= nif_fast_lane_bytes() do
      nif_new_fast(state, deps, bytes)
    else
      nif_new(state, deps, bytes)
    end
  end

  def exchange(resource, expected, state, notifications \\ []) do
    ensure_loaded!()
    deps = dependencies(state)
    bytes = estimate_bytes(state)

    # Two scheduler lanes, one cell. The fast lane is a regular-scheduler NIF
    # and must finish well under 1 ms. The NIF itself guarantees that bound:
    # it answers `:reroute` for a large current value, a large replacement, or
    # any NEW dependency edge (an unbounded cycle walk), and we then take the
    # dirty lane. The router only skips the fast attempt when the replacement
    # is obviously too big, so the common tiny-memo case costs one crossing.
    if bytes <= nif_fast_lane_bytes() do
      case nif_compare_exchange_fast(resource, expected, state, deps, bytes, notifications) do
        :reroute -> nif_compare_exchange(resource, expected, state, deps, bytes, notifications)
        outcome -> outcome
      end
    else
      nif_compare_exchange(resource, expected, state, deps, bytes, notifications)
    end
  end

  def dependencies(term) do
    ensure_loaded!()
    walk([term], MapSet.new(), MapSet.new(), [])
  end

  # A memo handle is a graph boundary; its transitive dependencies live in the
  # native graph. Immutable metadata belongs to the wrapper and must be walked.
  defp walk([], _ids, _functions, resources), do: resources

  defp walk(
         [%{__struct__: BeamLisp.LazySeq, resource: resource} = lazy | rest],
         ids,
         functions,
         resources
       ) do
    include_resource(resource, [Map.get(lazy, :metadata) | rest], ids, functions, resources)
  end

  defp walk([term | rest], ids, functions, resources) when is_reference(term) do
    case nif_dependency_resource(term) do
      nil -> walk(rest, ids, functions, resources)
      resource -> include_resource(resource, rest, ids, functions, resources)
    end
  end

  defp walk([term | rest], ids, functions, resources) when is_function(term) do
    if MapSet.member?(functions, term) do
      walk(rest, ids, functions, resources)
    else
      {:env, values} = :erlang.fun_info(term, :env)
      work = Enum.reduce(values, rest, fn value, acc -> [value | acc] end)
      walk(work, ids, MapSet.put(functions, term), resources)
    end
  end

  defp walk([term | rest], ids, functions, resources) when is_tuple(term),
    do: walk(prepend_tuple(term, tuple_size(term) - 1, rest), ids, functions, resources)

  # is_map-ok: ownership scanning must include fields of arbitrary structs.
  defp walk([term | rest], ids, functions, resources) when is_map(term),
    do:
      walk(
        :maps.fold(fn key, value, acc -> [key, value | acc] end, rest, term),
        ids,
        functions,
        resources
      )

  defp walk([[head | tail] | rest], ids, functions, resources),
    do: walk([head, tail | rest], ids, functions, resources)

  defp walk([_term | rest], ids, functions, resources), do: walk(rest, ids, functions, resources)

  defp include_resource(resource, rest, ids, functions, resources) do
    identity = nif_id(resource)

    if MapSet.member?(ids, identity),
      do: walk(rest, ids, functions, resources),
      else: walk(rest, MapSet.put(ids, identity), functions, [resource | resources])
  end

  defp prepend_tuple(_tuple, index, rest) when index < 0, do: rest

  defp prepend_tuple(tuple, index, rest),
    do: prepend_tuple(tuple, index - 1, [elem(tuple, index) | rest])

  def cursor(list) do
    ensure_loaded!()
    nif_cursor(list, dependencies(list), estimate_bytes(list))
  end

  @doc "Whether this cursor's chunks must take the dirty lane (decided at creation)."
  def cursor_dirty_chunks?(resource), do: nif_cursor_dirty_chunks(resource)

  @doc "Pull the next chunk. `dirty?` (from `cursor_dirty_chunks?/1`) picks the lane."
  def cursor_chunk(resource, dirty? \\ false)
  def cursor_chunk(resource, false), do: nif_cursor_chunk_fast(resource)
  def cursor_chunk(resource, true), do: nif_cursor_chunk(resource)

  def estimate_bytes(term), do: :erts_debug.flat_size(term) * :erlang.system_info(:wordsize)

  def admit! do
    budget = Application.get_env(:beam_lisp, :lazy_cache_budget_bytes, @default_budget_bytes)

    unless is_integer(budget) and budget >= 0,
      do: raise(ArgumentError, "lazy_cache_budget_bytes must be a non-negative integer")

    if budget == 0, do: raise(BeamLisp.LazySeq.ForceError, {:lazy_cache_budget_exceeded, budget})
    # Off-heap resource destruction can finish after the caller's GC returns.
    # Give that deferred work a bounded grace period; live answers are untouched.
    if stats().retained_bytes >= budget do
      :erlang.garbage_collect()
      await_budget(budget, System.monotonic_time(:millisecond) + 25)
    end
    :ok
  end

  defp await_budget(budget, deadline) do
    cond do
      stats().retained_bytes < budget -> :ok
      System.monotonic_time(:millisecond) >= deadline ->
        raise BeamLisp.LazySeq.ForceError, {:lazy_cache_budget_exceeded, budget}
      true -> Process.sleep(1); await_budget(budget, deadline)
    end
  end

  def new(state, dependencies, bytes) do
    ensure_loaded!()
    nif_new(state, dependencies, bytes)
  end

  def read(resource) do
    ensure_loaded!()

    case nif_lane(resource) do
      :fast -> nif_read_fast(resource)
      :dirty -> nif_read(resource)
    end
  end

  @doc "Byte ceiling below which cell reads/writes take the regular-scheduler lane."
  def fast_lane_bytes do
    ensure_loaded!()
    nif_fast_lane_bytes()
  end

  @doc "Tune the fast-lane ceiling. Raising it trades scheduler fairness for throughput."
  def set_fast_lane_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    ensure_loaded!()
    nif_set_fast_lane_bytes(bytes)
  end

  def compare_exchange(resource, expected, replacement, dependencies, bytes) do
    ensure_loaded!()
    nif_compare_exchange(resource, expected, replacement, dependencies, bytes, [])
  end

  def id(resource) do
    ensure_loaded!()
    nif_id(resource)
  end

  def stats do
    ensure_loaded!()
    nif_stats()
  end

  # Runtime loading happens after Elixir compilation. The probe deliberately
  # lives in the NIF, not persistent_term, so host-module reload cannot lie.
  @doc false
  def nif_loaded?, do: false
  @doc false
  def nif_new(_state, _dependencies, _bytes), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def nif_read(_resource), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def nif_read_fast(_resource), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def nif_lane(_resource), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def nif_fast_lane_bytes, do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def nif_set_fast_lane_bytes(_bytes), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def nif_compare_exchange_fast(
        _resource,
        _expected,
        _replacement,
        _dependencies,
        _bytes,
        _notifications
      ),
      do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def nif_compare_exchange(
        _resource,
        _expected,
        _replacement,
        _dependencies,
        _bytes,
        _notifications
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def nif_id(_resource), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def nif_resource_id(_term), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def nif_stats, do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def nif_new_fast(_state, _dependencies, _bytes), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def nif_cursor(_list, _dependencies, _bytes), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def nif_cursor_chunk(_cursor), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def nif_cursor_chunk_fast(_cursor), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def nif_cursor_dirty_chunks(_cursor), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def nif_dependency_resource(_term), do: :erlang.nif_error(:nif_not_loaded)
end
