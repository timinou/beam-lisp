defmodule Mix.Tasks.BeamLisp.Examples do
  @shortdoc "Run the examples/ scripts in ward's isolated, timed, dep-aware runner"

  @moduledoc """
  Run every example under `examples/` (executable documentation) through ward's
  example runner.

      mix beam_lisp.examples [GLOB ...]

  With no argument, runs `examples/**/*.bl`. Each example runs in its OWN
  isolated env fork off a warm base, so:

    * ISOLATED   — one example's defs and state live in its fork, destroyed on
      exit; it cannot contaminate the next. Multi-process examples survive
      isolation because the language's `spawn` conveys the fork's env into every
      child (see docs/the-environment-and-process-conveyance.md).
    * TIMED      — each example is deadlined; a genuine block fails that one
      example rather than wedging the whole run.
    * DEP-AWARE  — an example needing an absent optional dependency (the z3
      solver binary, Phoenix.PubSub, Bandit) is SKIPPED with its reason, not
      failed: absence of an optional dependency is an environment fact.

  Exits non-zero only when an example genuinely FAILS — a skip is not a failure.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    globs = if argv == [], do: ["examples/**/*.bl"], else: argv
    paths = globs |> Enum.flat_map(&Path.wildcard/1) |> Enum.uniq() |> Enum.sort()

    if paths == [], do: Mix.raise("no example files matched: #{inspect(globs)}")

    BeamLisp.init()

    # `examples/` on the search path so a namespaced sibling require
    # (`[relations.corpus]` → examples/relations/corpus.bl, `[geometry]` →
    # examples/geometry.bl) resolves the same way regardless of run order — the
    # loader server reads this Agent-backed root, which a per-process load path
    # would not reach.
    BeamLisp.Env.add_search_path("examples")

    BeamLisp.Loader.ensure_loaded("reload")
    BeamLisp.Loader.ensure_loaded("reload.ward")

    # Pre-load the heavy libraries the examples require most (datom 57×, auth
    # 12×, …) ONCE at :global, so every example fork inherits them through the
    # env chain instead of recompiling ~17 datom files from source per example.
    # Each is guarded: a lib whose own optional dep is absent (system.core needs
    # z3) simply stays unloaded, and the examples that need it are skipped later.
    for ns <- ~w(datom auth reload.migrate) do
      try do
        BeamLisp.Loader.ensure_loaded(ns)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    # Hand ward the {path, source} entries as data; it runs + reports in bl.
    entries =
      Enum.map(paths, fn p ->
        %{"path" => p, "src" => File.read!(p)}
      end)

    BeamLisp.Env.intern("user", "__ward_examples__", entries)

    ok? =
      BeamLisp.eval("""
      (let [r (reload.ward/run-examples (BeamLisp.Env/fetch! "user" "__ward_examples__"))]
        (println (reload.ward/report-examples r))
        (:ok? r))
      """)

    unless ok?, do: exit({:shutdown, 1})
  end
end
