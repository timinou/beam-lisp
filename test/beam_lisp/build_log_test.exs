defmodule BeamLisp.BuildLogTest do
  @moduledoc """
  The build's memory is a LOG OF FACTS; the manifest is its projection.

  Three properties, none of which the manifest could carry on its own:

    * what a build left behind can be QUERIED — stale, impact, coverage —
      instead of only asked one yes/no question per source;
    * a build directory whose manifest is gone still knows what it did (the
      log resumes it), which is what makes an interrupted build resumable;
    * the log and the manifest say exactly the same thing, because one is
      computed from the other rather than written beside it.

  The fixtures are a two-source tree: `log.a` alone, `log.b` requiring it, so
  a stale set and an impact set are both non-trivial.
  """
  use ExUnit.Case, async: false

  @src Path.join(System.tmp_dir!(), "beam_lisp_buildlog_src")
  @out Path.join(System.tmp_dir!(), "beam_lisp_buildlog_out")
  @manifest Path.join(@out, "compile.beam_lisp")

  setup do
    BeamLisp.init()
    File.rm_rf!(@src)
    File.rm_rf!(@out)
    File.mkdir_p!(@src)

    write("a.bl", """
    (ns log.a)
    (defn one [] 1)
    """)

    write("b.bl", """
    (ns log.b (:require [log.a :as a]))
    (defn two [] (+ 1 (a/one)))
    """)

    on_exit(fn -> File.rm_rf!(@src) end)
    :ok
  end

  test "a build logs facts, and the manifest is their projection" do
    assert {:ok, _} = build!(force: true)

    log = log_path()
    assert File.exists?(log), "the build wrote no fact log"
    text = File.read!(log)
    assert text =~ "[:build/built ", "facts are text data, not a serialised term"

    facts = BeamLisp.BuildLog.facts(log)
    tags = facts |> Enum.map(fn f -> bl(f) |> hd() end) |> Enum.uniq()
    assert :"build/run" in tags
    assert :"build/built" in tags
    assert :"build/end" in tags

    runs = Enum.count(facts, fn f -> (bl(f) |> hd()) == :"build/run" end)
    assert runs == 1, "the compaction keeps the LAST run, not a history"

    state = BeamLisp.BuildLog.state(log)
    assert map_size(state.sources) == 2, "both sources are remembered"

    assert BeamLisp.BuildLog.manifest(state) == read_manifest(),
           "the manifest on disk must be exactly the log's projection"
  end

  test "the stale set is a query, and an edit moves exactly what it should" do
    assert {:ok, _} = build!(force: true)

    state = BeamLisp.BuildLog.state(log_path())
    assert bl(BeamLisp.BuildLog.stale(plan(), state, @out)) == [],
           "nothing to do after a clean build"

    # A BODY edit: the interface `b` compiled against is unchanged, so `a` is
    # still fresh and only `b` is not.
    write("b.bl", """
    (ns log.b (:require [log.a :as a]))
    (defn two [] (+ 2 (a/one)))
    """)

    assert bl(BeamLisp.BuildLog.stale(plan(), state, @out)) == [Path.join(@src, "b.bl")]

    # `a` is what an edit to `a` would reach: b, and nothing else.
    assert bl(BeamLisp.BuildLog.impact(plan(), Path.join(@src, "a.bl"))) ==
             [Path.join(@src, "b.bl")]

    assert bl(BeamLisp.BuildLog.impact(plan(), Path.join(@src, "b.bl"))) == []
  end

  test "coverage says how much of the plan the log accounts for" do
    assert {:ok, _} = build!(force: true)

    state = BeamLisp.BuildLog.state(log_path())
    cov = BeamLisp.BuildLog.coverage(plan(), state, @out)

    assert cov.sources == 2
    assert cov.fresh == 2
    assert cov.recorded == 2
    assert bl(cov.stale) == []
  end

  test "a build with no manifest resumes from the log alone" do
    assert {:ok, _} = build!(force: true)
    manifest = read_manifest()
    assert map_size(manifest) == 2

    File.rm!(manifest_path())

    # Nothing changed, so the log alone is enough to know there is no work —
    # the property a single rewritten document cannot have, because the
    # document IS the memory.
    assert {:noop, []} = build!()

    assert read_manifest() == manifest, "the resumed build rewrote the projection"
  end

  test "a source that fails records WHY, and is not claimed as built" do
    write("c.bl", """
    (ns log.c (:require [log.nope :as nope]))
    (defn three [] (nope/missing))
    """)

    assert {:error, errors} = build!(force: true)
    assert Enum.any?(errors, fn e -> String.contains?(to_string(e), "c.bl") end),
           "the failure must name the source, got: #{inspect(errors)}"

    log = log_path()
    text = File.read!(log)
    assert text =~ "[:build/failed ", "the log records the failure as a fact"
    assert text =~ "log.nope", "and carries the reason with it"

    state = BeamLisp.BuildLog.state(log)
    refute Map.has_key?(BeamLisp.BuildLog.manifest(state), Path.join(@src, "c.bl")),
           "a failed source is not part of the projection"

    assert Path.join(@src, "c.bl") in bl(BeamLisp.BuildLog.stale(plan(), state, @out))
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp write(rel, text), do: File.write!(Path.join(@src, rel), text)

  # The language's collections cross back as host structs: a `Vector` is not an
  # Elixir list, so a bl `[]` never compares equal to `[]`. Normalise at the
  # boundary rather than weakening the assertions.
  defp bl(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp bl(list) when is_list(list), do: list
  defp bl(other), do: other

  defp build!(opts \\ []) do
    args = ["--source-dir", @src, "--out", @out, "--jobs", "1"]
    args = if opts[:force], do: args ++ ["--force"], else: args
    Mix.Tasks.Compile.BeamLisp.run(args)
  end

  defp sources, do: Path.wildcard(Path.join(@src, "*.bl")) |> Enum.sort()

  defp plan, do: BeamLisp.BuildPlan.plan_paths(sources())

  defp manifest_path, do: Path.join(@out, "compile.beam_lisp")

  defp read_manifest, do: manifest_path() |> File.read!() |> :erlang.binary_to_term()

  defp log_path, do: BeamLisp.BuildLog.path_for(manifest_path())
end
