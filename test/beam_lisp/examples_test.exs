defmodule BeamLisp.ExamplesTest do
  use ExUnit.Case, async: false

  # The examples are executable documentation; keep them honest.
  # A crash fails the test; return values vary by file.
  #
  # `**` so examples in SUBDIRECTORIES are covered too. The datom
  # tutorials live in examples/datom/ and were unchecked under a
  # single-level glob — which matters, because writing them found three
  # real defects: a tutorial uses an API the way its NAME invites rather
  # than the way its implementer remembers.
  #
  # Determinism: a subdirectory example may `(:require [relations.corpus])`
  # — a NAMESPACED require whose file is `examples/relations/corpus.bl`,
  # resolvable only when `examples/` is on the loader's search path. Under a
  # shared image that path was present or absent depending on WHICH earlier
  # example ran first, so the suite passed or failed by test ORDER (a seed
  # flake: 18/19 one seed, 10/19 another). Registering `examples/` as an
  # ambient search root once, before any example runs, makes every
  # namespaced require resolve the same way regardless of order — the
  # ordering-dependence dissolves because the dependency is no longer
  # order-dependent. The root is Agent-backed (`:global`), so the loader
  # server process sees it too, which a per-process load path would not.
  setup_all do
    BeamLisp.init()
    BeamLisp.Env.add_search_path("examples")
    :ok
  end

  for file <- Path.wildcard("examples/**/*.bl") do
    test "#{file} runs clean" do
      _ = BeamLisp.run_file(unquote(file))
    end
  end
end
