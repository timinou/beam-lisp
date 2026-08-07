defmodule BeamLisp.Trace do
  @moduledoc """
  Bounded tracing: the BEAM's `:dbg` exposed as data.

  Any function call in a live system can be traced without instrumentation.
  beam-lisp lowers that to a first-class form:

  ```clojure
  (trace 'my-fn (fn [call] (println (pr-str call))))
  (untrace 'my-fn)
  ```

  Each `trace` starts a real `:dbg` tracer, installs a match spec for the
  ONE named function, and delivers every `:call` event to the handler. The
  handler receives the trace event `{:trace pid :call {mod fun args}}`
  (an Erlang tuple — destructure with `erlang/element`, or pass it to
  `pr-str`).

  ## Rails — why this is safe where raw `:dbg` is a footgun

  `:dbg` can take down a production node under load: a blanket trace turns
  every matching call into a message, and the match spec and process scope
  are all too easy to get wrong. beam-lisp's `trace` refuses every one of
  those mistakes:

  - **One function at a time.** `trace` requires a quoted symbol that
    resolves to a defined var. There is no "trace everything" form.
  - **One active trace per node.** A second `trace` raises until `untrace`.
  - **Bounded match spec.** Only the exact `{module, fn, arity}` triples of
    the named fn are matched — never `:all`, never a wildcard.
  - **Calling-process scope.** Only the process that calls `trace` is
    traced, so a trace can never instrument every process on the node.
  - **Count cap.** After `max-calls` events (default 1000) the match spec
    is cleared and extra in-flight events are dropped, so the handler is
    invoked **at most** `max-calls` times. Pass `{:max-calls n}` to set it.

  The one thing tracing cannot bound away is the cost of the traced fn
  itself — but the trace overhead (one message per call, capped) is
  contained by the rails above.
  """

  alias BeamLisp.Env

  # `:dbg` lives in `runtime_tools`, pulled in on demand by
  # `ensure_runtime_tools/0` (see below) — it is never a compile-time
  # dependency, so silence the undefined-module call warning.
  @compile {:no_warn_undefined, :dbg}

  @default_max_calls 1000

  # Registry cell in the shared vars table (a bare-atom key, distinct from
  # every `{ns, name}` and `{:alias, ns, name}` key). Carries the active
  # trace so `untrace` and the count cap share one source of truth.
  @state_key :beam_lisp_trace_state

  # The match spec for a plain `:call` event: match every call of the
  # traced function, emit no extra events. `:dbg` enriches this with the
  # process/function metadata itself.
  @match_spec [{:_, [], []}]

  @doc """
  Trace calls to `name`, delivering each `:call` event to `handler`.

  `name` is the quoted-symbol datum `{:symbol, name}` that `'my-fn` hands
  over. `opts` is a map with optional `:max-calls` (count cap, default
  1000). Returns `:ok`.
  """
  def trace(ns, {:symbol, name}, handler), do: trace(ns, name, handler, %{})

  def trace(ns, {:symbol, name}, handler, opts),
    do: trace(ns, name, handler, opts)

  def trace(ns, name, handler, opts) when is_binary(name) and is_function(handler, 1) do
    ensure_runtime_tools()
    ensure_inactive!(name)
    {mod, fixed} = resolve(ns, name)
    max_calls = Map.get(opts, :"max-calls", @default_max_calls)
    installed = for {arity, fname} <- fixed, do: {mod, fname, arity}
    me = self()

    # The tracer handler carries the per-trace state through its `Data`
    # argument (OTP 29's `fun(Event, Data) -> NewData`), so the count cap
    # lives inside the tracer process itself — no cross-process race.
    initial = %{handler: handler, count: 0, max: max_calls, installed: installed, done: false}
    {:ok, _tracer} = :dbg.tracer(:process, {&dispatch/2, initial})

    for {m, f, a} <- installed, do: :dbg.tpl(m, f, a, @match_spec)
    :dbg.p(me, [:c])

    :ets.insert(:beam_lisp_vars, {@state_key, %{active: true, name: name, installed: installed}})
    :ok
  end

  def trace(_ns, name, _handler, _opts) when is_binary(name) do
    raise "trace: handler must be a function of one argument"
  end

  @doc "Stop tracing `name` and clear its match spec. Returns `:ok`."
  def untrace(ns, {:symbol, name}), do: untrace(ns, name)

  def untrace(_ns, _name) do
    case :ets.lookup(:beam_lisp_vars, @state_key) do
      [{_, %{installed: installed}}] ->
        clear_patterns(installed)
        :dbg.stop_clear()
        :ets.delete(:beam_lisp_vars, @state_key)
        :ok

      _ ->
        # Not tracing is the desired end state, so say so rather than
        # raising: an `untrace` in a cleanup path must never itself fail
        # and mask the error that made cleanup necessary.
        :ok
    end
  end

  # Route a `:call` event. Delivers it to the handler until the count cap
  # is reached; after that it clears the pattern (so no further events are
  # generated) and marks the trace done — any events already in flight are
  # dropped, so the handler is called exactly `max_calls` times.
  defp dispatch({:trace, pid, :call, {mod, fname, args}}, st) do
    arity = length(args)

    cond do
      st.done ->
        st

      {mod, fname, arity} in st.installed and st.count < st.max ->
        deliver(st, pid, {mod, fname, args})

      {mod, fname, arity} in st.installed ->
        clear_patterns(st.installed)
        mark_inactive()
        %{st | done: true}

      true ->
        st
    end
  end

  defp dispatch(_event, st), do: st

  defp deliver(st, pid, mfa) do
    event = {:trace, pid, :call, mfa}
    safe_call(st.handler, event)
    new_count = st.count + 1

    if new_count >= st.max do
      clear_patterns(st.installed)
      mark_inactive()
      %{st | count: new_count, done: true}
    else
      %{st | count: new_count}
    end
  end

  # A raising handler must not silently kill the tracer (which would leave
  # a half-installed trace and a dead node tracer); report and continue.
  defp safe_call(handler, event) do
    handler.(event)
  rescue
    e -> IO.puts("trace: handler raised #{Exception.message(e)}")
  end

  # `Env.current_ns/0` is process-global and survives across evaluations,
  # so the namespace threaded in at CALL time is not always the namespace
  # the traced fn was defined in — a REPL session or a test that evaluated
  # in another namespace first leaves it pointing elsewhere. Resolve
  # against the given namespace, then fall back to the namespace that
  # actually holds a linkable var of this name before giving up.
  defp resolve(ns, name) do
    case link_in(ns, name) do
      nil ->
        case Enum.find_value(Env.namespaces(), &link_in(&1, name)) do
          nil -> raise "trace: #{name} does not resolve to a defined function in #{ns}"
          found -> found
        end

      found ->
        found
    end
  end

  defp link_in(ns, name) do
    case Env.link(ns, name) do
      {:ok, {mod, fixed, _variadic}} when is_map(fixed) and map_size(fixed) > 0 -> {mod, fixed}
      _ -> nil
    end
  end

  defp ensure_inactive!(name) do
    case :ets.lookup(:beam_lisp_vars, @state_key) do
      [{_, %{active: true}}] ->
        raise "trace: #{name} — a trace is already active (untrace first)"

      _ ->
        :ok
    end
  end

  defp clear_patterns(installed) do
    for {m, f, a} <- installed, do: :dbg.ctpl(m, f, a)
    :ok
  end

  defp mark_inactive do
    case :ets.lookup(:beam_lisp_vars, @state_key) do
      [{_, st}] -> :ets.insert(:beam_lisp_vars, {@state_key, Map.put(st, :active, false)})
      _ -> :ok
    end
  end

  # `:dbg` lives in `runtime_tools`, which is not a beam-lisp application
  # dependency. Pull it in on demand — add its ebin dir to the code path if
  # it is absent, then start it — so the beam-lisp app never pays for it
  # unless tracing is actually used.
  defp ensure_runtime_tools do
    case Application.ensure_all_started(:runtime_tools) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        root = Path.join(:code.root_dir() |> List.to_string(), "lib")

        case Path.wildcard(Path.join(root, "runtime_tools-*")) |> List.first() do
          nil ->
            raise "trace: :dbg needs runtime_tools, not found under #{root}"

          dir ->
            :code.add_patha(String.to_charlist(Path.join(dir, "ebin")))

            case Application.ensure_all_started(:runtime_tools) do
              {:ok, _} -> :ok
              {:error, reason} -> raise "trace: could not start runtime_tools: #{inspect(reason)}"
            end
        end
    end
  end
end
