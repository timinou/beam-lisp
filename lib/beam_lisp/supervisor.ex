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
