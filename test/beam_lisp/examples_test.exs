defmodule BeamLisp.ExamplesTest do
  use ExUnit.Case, async: false

  # The examples under examples/ are executable documentation; keep them honest.
  # They run through WARD's example runner (priv/std/reload/ward.bl → run-examples),
  # the same isolated-fork machinery the .bl test suites use, extended for the
  # three things a bare script needs and a deftest suite does not:
  #
  #   * ISOLATED   — each example runs in its OWN env fork, destroyed on exit, so
  #     it cannot contaminate the next. This dissolves the old seed-order flake
  #     (18/19 one seed, 10/19 another): there is no shared mutable ground for
  #     one example to pull out from under another. Multi-process examples
  #     survive isolation because the language's `spawn` conveys the fork's env
  #     into every child (docs/the-environment-and-process-conveyance.md).
  #   * TIMED      — each example is deadlined, so a genuine block fails that one
  #     example instead of wedging the whole run.
  #   * DEP-AWARE  — an example needing an absent optional dependency (the z3
  #     solver binary, Phoenix.PubSub, Bandit) is SKIPPED with its reason, not
  #     failed — absence of an optional dependency is an environment fact, not a
  #     defect. Skipped examples are reported, not counted as failures.
  #
  # One ward run in `setup_all` produces every file's result; the per-file tests
  # below just look theirs up, so the suite is both granular (a named test per
  # example) and fast (a single warm base, one pass).

  @examples Path.wildcard("examples/**/*.bl") |> Enum.sort()

  setup_all do
    BeamLisp.init()

    # `examples/` on the loader's Agent-backed search path so a namespaced
    # sibling require (`[relations.corpus]` → examples/relations/corpus.bl,
    # `[geometry]` → examples/geometry.bl) resolves the same way regardless of
    # order. The loader server process reads this root; a per-process load path
    # would not reach it.
    BeamLisp.Env.add_search_path("examples")
    BeamLisp.Loader.ensure_loaded("reload")
    BeamLisp.Loader.ensure_loaded("reload.ward")

    # Pre-load the heavy shared libraries ONCE at :global so every example fork
    # inherits them through the env chain (a ~8x speedup vs recompiling datom's
    # ~17 files from source per example). Guarded: a lib whose optional dep is
    # absent stays unloaded and its examples are skipped later.
    for ns <- ~w(datom auth reload.migrate) do
      try do
        BeamLisp.Loader.ensure_loaded(ns)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    entries = Enum.map(@examples, fn p -> %{"path" => p, "src" => File.read!(p)} end)
    BeamLisp.Env.intern("user", "__ward_examples__", entries)

    result =
      BeamLisp.eval("""
      (reload.ward/run-examples (BeamLisp.Env/fetch! "user" "__ward_examples__"))
      """)

    files =
      case bl_get(result, "files") do
        %BeamLisp.Vector{} = v -> BeamLisp.Vector.to_list(v)
        list when is_list(list) -> list
        _ -> []
      end

    by_path =
      files
      |> Enum.map(fn r -> {bl_get(r, "path"), {bl_get(r, "status"), bl_get(r, "reason")}} end)
      |> Map.new()

    {:ok, results: by_path}
  end

  # Read a beam-lisp map field whether it comes back keyed by string or atom.
  defp bl_get(map, key) when is_map(map) do
    Map.get(map, key) ||
      (try do
         Map.get(map, String.to_existing_atom(key))
       rescue
         ArgumentError -> nil
       end)
  end

  defp bl_get(_, _), do: nil

  for file <- @examples do
    test "#{file} runs clean", %{results: results} do
      case Map.get(results, unquote(file)) do
        {:passed, _} ->
          :ok

        {:skipped, reason} ->
          # An absent optional dependency — reported, not a failure, so the run
          # stays green without pretending the example actually executed.
          IO.puts("\n  ~ skipped #{unquote(file)}: #{reason || "optional dependency absent"}")

        {:failed, reason} ->
          flunk("example failed: #{unquote(file)}\n  #{reason}")

        nil ->
          flunk("no ward result for #{unquote(file)} (ward did not report it)")
      end
    end
  end
end
