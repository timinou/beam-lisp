defmodule BeamLisp.LazySeq do
  @moduledoc """
  A lazy sequence with resource-owned memo state. Successful answers are shared;
  known failed attempts may be retried. Recursive force, cyclic retained values,
  and evaluator loss are terminal. Metadata is immutable and value-owned.
  """
  alias BeamLisp.LazyMemo
  @chunk_size 32
  defstruct resource: nil, metadata: nil

  defmodule ForceError do
    defexception [:reason, :message]
    @impl true
    def exception(reason),
      do: %__MODULE__{reason: reason, message: "LazySeq force failed: #{inspect(reason)}"}
  end

  @type t :: %__MODULE__{resource: reference(), metadata: map() | nil}
  @doc "Wrap a recipe in a shared lazy node. A successful result is memoized."
  def new(thunk) when is_function(thunk, 0),
    do: %__MODULE__{resource: LazyMemo.create({:pending, thunk})}

  def from_fun(thunk) when is_function(thunk, 0), do: new(thunk)
  def lazy?(%__MODULE__{}), do: true
  def lazy?(_), do: false
  def chunk_size, do: @chunk_size

  @doc false
  def input(%BeamLisp.Vector{} = vector), do: input(BeamLisp.Vector.to_list(vector))

  def input(list) when is_list(list) do
    size =
      try do
        length(list)
      rescue
        ArgumentError -> 0
      end

    if size > @chunk_size, do: BeamLisp.SeqCursor.new(list), else: list
  end

  def input(other), do: other
  def chain([], _tail_fun), do: nil

  def chain(elems, tail_fun) when is_function(tail_fun, 0),
    do: List.foldr(elems, new(tail_fun), fn e, acc -> [e | acc] end)

  def force(%__MODULE__{resource: resource}), do: force_state(resource)
  @doc false
  def memo_state(%__MODULE__{resource: resource}), do: LazyMemo.read(resource)

  defp force_state(resource) do
    case LazyMemo.read(resource) do
      {:completed, value} ->
        value

      {:terminal, reason} ->
        raise ForceError, reason

      {:running, _thunk, owner, attempt, _waiters} when owner == self() ->
        resource |> publish_attempt(attempt, {:terminal, :recursive_force}) |> return_outcome()

      {:running, _thunk, owner, attempt, _waiters} ->
        wait_for_attempt(resource, owner, attempt)

      {:pending, thunk} = old ->
        claim_attempt(resource, old, thunk)

      {:failed, thunk, _kind, _reason, _stacktrace} = old ->
        claim_attempt(resource, old, thunk)
    end
  end

  defp claim_attempt(resource, old, thunk) do
    LazyMemo.admit!()
    attempt = make_ref()

    case LazyMemo.exchange(resource, old, {:running, thunk, self(), attempt, []}) do
      :ok -> evaluate_attempt(resource, attempt, thunk)
      :retry -> force_state(resource)
      :cycle -> raise ForceError, :cyclic_memo
    end
  end

  defp evaluate_attempt(resource, attempt, thunk) do
    state =
      try do
        {:completed, thunk.()}
      catch
        kind, reason -> {:failed, thunk, kind, reason, __STACKTRACE__}
      end

    # Publication errors are not recipe failures and must not be republished.
    resource |> publish_attempt(attempt, state) |> return_outcome()
  end

  defp publish_attempt(resource, attempt, state) do
    case LazyMemo.read(resource) do
      {:running, _thunk, owner, ^attempt, waiters} = old when owner == self() ->
        outcome = attempt_outcome(state)
        notifications = notifications(resource, attempt, waiters, outcome)

        case LazyMemo.exchange(resource, old, state, notifications) do
          :ok -> outcome
          :retry -> publish_attempt(resource, attempt, state)
          :cycle -> publish_attempt(resource, attempt, {:terminal, :cyclic_memo})
        end

      {:terminal, reason} ->
        {:terminal, reason}

      _ ->
        raise ForceError, {:stale_force_owner, attempt}
    end
  end

  defp notifications(resource, attempt, waiters, outcome) do
    identity = LazyMemo.id(resource)
    Enum.map(waiters, &{&1, {:lazy_attempt, identity, attempt, outcome}})
  end

  defp attempt_outcome({:failed, _thunk, kind, reason, trace}), do: {:failed, kind, reason, trace}
  defp attempt_outcome(outcome), do: outcome
  defp return_outcome({:completed, value}), do: value
  defp return_outcome({:failed, kind, reason, trace}), do: :erlang.raise(kind, reason, trace)
  defp return_outcome({:terminal, reason}), do: raise(ForceError, reason)

  defp wait_for_attempt(resource, owner, attempt) do
    identity = LazyMemo.id(resource)
    monitor = Process.monitor(owner)

    case LazyMemo.read(resource) do
      {:running, thunk, ^owner, ^attempt, waiters} = old ->
        case LazyMemo.exchange(
               resource,
               old,
               {:running, thunk, owner, attempt, [self() | waiters]}
             ) do
          :ok ->
            receive_attempt(resource, identity, owner, attempt, monitor)

          :retry ->
            Process.demonitor(monitor, [:flush])
            force_state(resource)

          :cycle ->
            Process.demonitor(monitor, [:flush])
            raise ForceError, :cyclic_memo
        end

      _ ->
        Process.demonitor(monitor, [:flush])
        force_state(resource)
    end
  end

  defp receive_attempt(resource, identity, owner, attempt, monitor) do
    receive do
      {:lazy_attempt, ^identity, ^attempt, outcome} ->
        Process.demonitor(monitor, [:flush])
        return_outcome(outcome)

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        owner_lost(resource, owner, attempt)
        # Commit and notifications are one native operation. If commit won
        # before owner death, its exact reply is delivered, even after a retry
        # starts. Otherwise owner_lost publishes a terminal reply to us.
        receive do
          {:lazy_attempt, ^identity, ^attempt, outcome} -> return_outcome(outcome)
        end
    end
  end

  defp owner_lost(resource, owner, attempt) do
    case LazyMemo.read(resource) do
      {:running, _thunk, ^owner, ^attempt, waiters} = old ->
        terminal = {:terminal, {:force_owner_lost, owner, attempt}}
        messages = notifications(resource, attempt, waiters, terminal)

        case LazyMemo.exchange(resource, old, terminal, messages) do
          :ok -> :ok
          :retry -> owner_lost(resource, owner, attempt)
          :cycle -> raise ForceError, :cyclic_memo
        end

      _ ->
        :ok
    end
  end

  @doc "Force a node and normalize to a realized cell: `nil` or `[head | tail]`."
  def realize(%__MODULE__{} = l), do: realize_loop(l, 0)

  # A lazy-seq body may hand back any seqable rather than a cons cell —
  # jank writes `(lazy-seq c1)` around a bare collection — so normalize
  # it here, at the one place a thunk's value enters the walk. Without
  # this a realized vector reached the walk loops as an opaque value and
  # crashed with no matching clause.
  #
  # The invariant every walk relies on is: forcing a node yields `nil`
  # or a `[h | t]` cell, never a bare LazySeq. Clojure `lazy-seq` bodies
  # routinely *return another seq* — `(lazy-seq (concat …))` nests — so
  # a thunk that hands back a bare LazySeq is idiomatic, not an error.
  # Peel those nested nodes here rather than leaving them for every
  # `case LazySeq.cell(_)` consumer (concat, first, next, take, …) to
  # rediscover and crash on. Only the HEAD is normalized; the tail stays
  # lazy, so an infinite seq still realizes one cell at a time.
  defp realize_loop(%__MODULE__{} = l, depth) do
    if depth > 100_000 do
      raise "LazySeq.realize: thunk chain #{depth} deep without a head — " <>
              "a self-referential lazy seq never produces a cell; it would hang forever"
    end

    case force(l) do
      [] -> nil
      %BeamLisp.Vector{} = v -> normalize_cell(BeamLisp.Vector.to_list(v))
      %BeamLisp.Set{} = s -> normalize_cell(BeamLisp.Set.to_list(s))
      %__MODULE__{} = nested -> realize_loop(nested, depth + 1)
      %BeamLisp.SeqCursor{} = cursor -> BeamLisp.SeqCursor.cell(cursor)
      value -> value
    end
  end

  @doc """
  Normalize any seqable to a realized cell: `nil`, a `[head | tail]` list
  (whose tail may be a `LazySeq`), or, for non-seqables, the value itself.
  This is the one chokepoint every seq walk (forcing, `first`, `rest`,
  `take`, `count`, `Enum`) goes through.
  """
  def cell(nil), do: nil
  def cell([]), do: nil
  def cell(%__MODULE__{} = l), do: realize(l)
  def cell(%BeamLisp.SeqCursor{} = cursor), do: BeamLisp.SeqCursor.cell(cursor)
  def cell(xs) when is_list(xs), do: xs
  def cell(%BeamLisp.Vector{} = v), do: normalize_cell(BeamLisp.Vector.to_list(v))
  # A lazy-seq body may return any seqable — jank wraps a bare
  # collection in `(lazy-seq c1)` — so anything Enumerable becomes a
  # cell rather than falling through as an opaque value that the walk
  # loops then cannot match. Non-seqable values still pass through.
  def cell(%BeamLisp.Set{} = s), do: normalize_cell(BeamLisp.Set.to_list(s))

  # A string is seqable (elements are 1-char strings, matching `count`
  # and `subs`). Without this it fell through as an opaque value, and
  # `reduce` — which every `into` goes through — produced `[nil]` for
  # `(into [] "ab")`: no error, a plausible vector, and a nil surfacing
  # far from its cause.
  def cell(str) when is_binary(str), do: normalize_cell(String.graphemes(str))

  def cell(other) do
    # Reaching here means `other` is neither nil, a list, nor one of
    # our collection structs. If it is Enumerable (a range, a map,
    # a MapSet), treat it as a seq; otherwise pass it through.
    case Enumerable.impl_for(other) do
      nil -> other
      _ -> normalize_cell(Enum.to_list(other))
    end
  end

  defp normalize_cell([]), do: nil
  defp normalize_cell(xs), do: xs

  @doc "Fully realize into a proper list (iterative — a 100k `doall` cannot blow the stack)."
  def to_list(lazy), do: to_list_loop(cell(lazy), [])

  defp to_list_loop(nil, acc), do: Enum.reverse(acc)
  defp to_list_loop([h | t], acc), do: to_list_loop(cell(t), [h | acc])

  @doc "Realize up to `n` elements (iterative)."
  def prefix(lazy, n) when is_integer(n), do: prefix_loop(cell(lazy), n, [])

  defp prefix_loop(_cell, n, acc) when n <= 0, do: Enum.reverse(acc)
  defp prefix_loop(nil, _n, acc), do: Enum.reverse(acc)
  defp prefix_loop([h | t], n, acc), do: prefix_loop(cell(t), n - 1, [h | acc])

  @doc "`{taken, truncated?}`: sample up to `n` elements, flag if more remain."
  def sample(lazy, n) do
    taken = prefix(lazy, n + 1)

    case taken do
      xs when length(xs) > n -> {Enum.take(xs, n), true}
      xs -> {xs, false}
    end
  end

  @doc "Element count, forcing the whole seq (iterative)."
  def count(lazy), do: count_loop(cell(lazy), 0)

  defp count_loop(nil, acc), do: acc
  defp count_loop([_ | t], acc), do: count_loop(cell(t), acc + 1)

  @doc "Element at `i`, or `nil` (iterative)."
  def nth(lazy, i) when is_integer(i) and i >= 0, do: nth_loop(cell(lazy), i)

  defp nth_loop(nil, _i), do: nil
  defp nth_loop([h | _], 0), do: h
  defp nth_loop([_ | t], i), do: nth_loop(cell(t), i - 1)

  @doc "Force the whole seq for side effects, discarding elements."
  def run(lazy), do: run_loop(cell(lazy))

  defp run_loop(nil), do: :ok
  defp run_loop([_ | t]), do: run_loop(cell(t))

  defimpl Enumerable do
    def count(lazy), do: {:ok, BeamLisp.LazySeq.count(lazy)}

    def member?(_lazy, _x), do: {:error, __MODULE__}

    def reduce(lazy, acc, fun), do: do_reduce(acc, lazy, fun)

    defp do_reduce({:halt, acc}, _lazy, _fun), do: {:halted, acc}

    defp do_reduce({:suspend, acc}, lazy, fun),
      do: {:suspended, acc, &do_reduce(&1, lazy, fun)}

    defp do_reduce({:cont, acc}, lazy, fun) do
      case BeamLisp.LazySeq.cell(lazy) do
        nil ->
          {:done, acc}

        [h | t] ->
          case fun.(h, acc) do
            {:cont, acc} -> do_reduce({:cont, acc}, t, fun)
            {:halt, acc} -> {:halted, acc}
            {:suspend, acc} -> {:suspended, acc, &do_reduce(&1, t, fun)}
          end
      end
    end

    def slice(_lazy), do: {:error, __MODULE__}
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(lazy, opts) do
      limit = if is_integer(opts.limit) and opts.limit > 0, do: opts.limit, else: 20
      {elems, truncated} = BeamLisp.LazySeq.sample(lazy, limit)

      body = Enum.map(elems, &Inspect.Algebra.to_doc(&1, opts))
      body = Enum.intersperse(body, " ")
      # concat/1 wants a FLAT list of docs; a nested list is not a doc
      # and crashes the algebra formatter, which made a lazy seq
      # impossible to inspect — including inside a test failure message.
      body = if truncated, do: body ++ ["…"], else: body

      concat(["("] ++ body ++ [")"])
    end
  end
end
