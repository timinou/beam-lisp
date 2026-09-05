defmodule BeamLisp.Supervisor do
  @moduledoc """
  Supervision trees as data.

  A supervision tree is a nested data structure — and Lisp is the language
  where that is literally true. `supervise` lowers a strategy keyword and a
  list of child specs into a **real** Elixir `Supervisor`: the same OTP
  process `Supervisor.which_children/1`, `Supervisor.count_children/1` and
  `:observer` recognise, with genuine restart behaviour.

  ```clojure
  (supervise :one-for-one [(worker :counter (fn [] (counter-loop)))
                           (worker :logger (fn [] (logger-loop)))])
  ```

  Everything is plain data: restart strategies (`:one-for-one`,
  `:one-for-all`, `:rest-for-one`), restart types
  (`:permanent`/`:transient`/`:temporary`) and the restart-intensity
  limits (`max-restarts`, `max-seconds`). No macro, no special form — the
  supervisor is an ordinary function over ordinary values, which is the
  whole point of supervising from a Lisp.
  """

  @doc """
  Build a child spec for one worker.

  `start` is either a **zero-arity function** — wrapped as a `Task` process
  running it, the plainest BEAM worker — or an explicit `{module, fun,
  args}` MFA tuple, which is passed through untouched so any OTP process
  with a `start_link/1` is superviseable.

  `opts` is a map with optional keys:

    * `:restart` — `:permanent` (default), `:transient` (restart only on
      abnormal exit) or `:temporary` (never restart)
    * `:shutdown` — milliseconds to wait, or `:infinity`
    * `:type` — `:worker` (default) or `:supervisor`
  """
  def worker(id, start), do: %{id: id, start: start_spec(start)}

  # is_map-ok: opts is the internal supervisor option map (restart/shutdown/type),
  # never a user collection value.
  def worker(id, start, opts) when is_map(opts) do
    %{id: id, start: start_spec(start)}
    |> maybe_put(opts, :restart)
    |> maybe_put(opts, :shutdown)
    |> maybe_put(opts, :type)
  end

  # A bare function becomes a `Task` process running it — start it and it
  # runs; crash it and it exits abnormally so the supervisor restarts it.
  defp start_spec(start) when is_function(start, 0), do: {Task, :start_link, [start]}

  # An explicit MFA tuple is used directly — a supervisor child spec is
  # just `{mod, fun, args}` no matter what process it starts.
  defp start_spec({m, f, args}) when is_atom(m) and is_atom(f) and is_list(args),
    do: {m, f, args}

  defp maybe_put(spec, opts, key) do
    case Map.get(opts, key) do
      nil -> spec
      value -> Map.put(spec, key, value)
    end
  end

  @doc """
  Start a supervision tree. Returns the supervisor pid (the `{:ok, pid}` is
  unwrapped, so the tree hands you its handle directly).

  ```clojure
  (supervise :one-for-one [(worker :a f) (worker :b g)])
  (supervise :rest-for-one [(worker :a f)] {:max-restarts 3 :max-seconds 10})
  ```

  `children` is a list of child specs — `worker/2` results, or hand-built
  maps, anything `Supervisor.start_link/2` accepts. `opts` may carry
  `:max-restarts` and `:max-seconds` (dashed beam-lisp keys become
  `:"max-restarts"` / `:"max-seconds"`).
  """
  def supervise(strategy, children) when is_atom(strategy) do
    supervise(strategy, children, %{})
  end

  def supervise(strategy, children, opts) when is_atom(strategy) do
    sup_opts = [strategy: normalize_strategy(strategy)] ++ intensity_opts(opts)
    {:ok, pid} = Supervisor.start_link(child_list(children), sup_opts)
    pid
  end

  @doc """
  Child spec for a defserver child: the child IS the gen_server, not a wrapper.

  A bare-fn child (`worker/2`) runs the fn as a `Task` — right for a loop,
  wrong for a gen_server: the fn would return the pid, the task would exit
  `:normal`, and a `:permanent` supervisor would restart it forever. So a
  defserver child is an MFA tuple pointing here, and `start_server/2` returns
  the `{:ok, pid}` shape OTP requires.
  """
  def server(id, mod), do: server(id, mod, nil, %{})
  def server(id, mod, arg), do: server(id, mod, arg, %{})

  def server(id, mod, arg, opts) when is_map(opts) do
    %{id: id, start: {__MODULE__, :start_server, [mod, arg]}}
    |> maybe_put(opts, :restart)
    |> maybe_put(opts, :shutdown)
    |> maybe_put(opts, :type)
  end

  @doc "The child-start entry of a defserver child spec (see `server/4`)."
  def start_server(mod, arg) do
    {:ok, BeamLisp.Server.start_link(mod, arg)}
  end

  @doc """
  Child spec for a POOL: a named one-for-one sub-supervisor owning one
  dispatcher (whose init arg is the pool's registered name) and `n` identical
  workers (each receives its index as init arg). The whole sub-tree is one
  child: it restarts and dies as a unit.
  """
  def pool(id, sup_name, dispatcher_mod, target, n) do
    children =
      [%{id: :dispatcher, start: {__MODULE__, :start_server, [dispatcher_mod, sup_name]}}] ++
        for i <- 0..(n - 1), do: server(String.to_atom("w#{i}"), target, i)

    %{id: id, type: :supervisor, start: {__MODULE__, :start_named_sup, [children, sup_name]}}
  end

  @doc "The child-start entry of a pool spec: start the named sub-supervisor."
  def start_named_sup(children, name) do
    Supervisor.start_link(children, strategy: :one_for_one, name: name)
  end

  @doc """
  Start a tree from a `defsupervisor` spec map — what the prelude `start-link`
  dispatches to when its argument carries the `__supervisor__` marker.

      {:__supervisor__ true
       :strategy :one-for-one
       :intensity [3 5000]              ; bl vector → max_restarts/max_seconds
       :children (list worker-spec …)}
  """
  def start_link(%{strategy: strategy, children: children} = spec) do
    sup_opts = [strategy: normalize_strategy(strategy)] ++ intensity_from(spec)
    {:ok, pid} = Supervisor.start_link(child_list(children), sup_opts)
    pid
  end

  defp intensity_from(%{intensity: %BeamLisp.Vector{items: {max_r, max_s}}}),
    do: [max_restarts: max_r, max_seconds: max_s]

  defp intensity_from(_), do: []

  # beam-lisp writes restart strategies the way the reader spells them —
  # `:one-for-one` — while Elixir's Supervisor wants `:one_for_one`. A
  # dashed atom is just the same strategy with its hyphens turned to
  # underscores, so normalize rather than ask the caller to know both.
  defp normalize_strategy(strategy) do
    strategy |> Atom.to_string() |> String.replace("-", "_") |> String.to_atom()
  end

  # A child list in beam-lisp is a literal vector (`[(worker :a f) ...]`),
  # a list, or any seqable — `Supervisor` wants a plain list.
  defp child_list(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp child_list(list) when is_list(list), do: list

  defp intensity_opts(opts) do
    for {key, opt} <- [{:"max-restarts", :max_restarts}, {:"max-seconds", :max_seconds}],
        value = Map.get(opts, key),
        value != nil,
        do: {opt, value}
  end
end
