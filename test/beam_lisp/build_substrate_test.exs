defmodule BeamLisp.BuildSubstrateTest do
  @moduledoc """
  The Elixir substrate stage: `lib/**/*.ex` compiled in-process, tracked in the
  same fact log as the AOT waves.

  What this pins, and why each one is worth a test:

    * a full pass over `lib/` minus the Mix-task shells and the dev server
      produces a beam for every module — the ebin a release needs;
    * no `Mix` beam comes out of it, which is the whole point of doing this
      without a Mix project;
    * freshness is the content hash, so a second pass compiles NOTHING, an
      edited file compiles alone, and a beam that vanished pulls its own source
      back in (the hole W1-R1 documents for the AOT side);
    * a file that will not compile is REPORTED and records no fact, so it stays
      stale for the next run instead of being marked done.
  """
  use ExUnit.Case, async: false

  @mix_excludes ["mix"]
  @src Path.join(System.tmp_dir!(), "beam_lisp_substrate_src")
  @out Path.join(System.tmp_dir!(), "beam_lisp_substrate_out")

  setup do
    BeamLisp.init()
    File.rm_rf!(@src)
    File.rm_rf!(@out)
    File.mkdir_p!(@src)
    on_exit(fn -> File.rm_rf!(@src) end)
    :ok
  end

  test "the project's own substrate compiles with no Mix beam in the output" do
    # The stage's root is the SOURCE root (`lib`), with exclusions relative to
    # it: `mix/` is the Mix-task shells, which `use Mix.Task` and so cannot
    # compile without Mix.
    root = Path.join(File.cwd!(), "lib")
    sources = BeamLisp.Substrate.sources(root, @mix_excludes)
    count = Enum.count(sources)
    assert count > 50, "expected the project's Elixir sources, got #{count}"
    refute Enum.any?(sources, &String.starts_with?(Path.relative_to(&1, root), "mix")), "the Mix-task shells must not be in the set"

    result = BeamLisp.Substrate.compile!(sources, @out)
    assert bl(result.errors) == [], "substrate errors: #{inspect(Enum.take(bl(result.errors), 3))}"
    assert result.compiled == count

    beams = Path.wildcard(Path.join(@out, "*.beam"))
    refute File.exists?(Path.join(@out, "Elixir.Mix.beam")),
           "the substrate must not need — or produce — Mix"

    # One fact per source, every one naming at least one beam it produced.
    assert Enum.count(result.facts) == count

    fact_modules =
      result.facts
      |> Enum.flat_map(fn f -> bl(f) |> Enum.at(3) |> bl() end)
      |> MapSet.new()

    assert MapSet.size(fact_modules) >= length(beams),
           "modules attributed (#{MapSet.size(fact_modules)}) must cover the beams written (#{length(beams)})"
  end

  test "a second pass compiles nothing, and an edit compiles one file" do
    sources = fixture!()
    out = @out

    first = BeamLisp.Substrate.compile!(stale(sources, out), out)
    assert first.compiled == 3
    state = state_after(first)

    assert bl(BeamLisp.Substrate.stale(state, sources, out)) == [], "nothing stale after a full pass"

    # A body edit: the hash moves, and only that file is stale.
    File.write!(Path.join(@src, "b.ex"), "(defmodule Sub.B do\n  def v, do: 2\nend)\n")
    assert bl(BeamLisp.Substrate.stale(state, sources, out)) == [Path.join(@src, "b.ex")]

    second = BeamLisp.Substrate.compile!(BeamLisp.Substrate.stale(state, sources, out), out)
    assert second.compiled == 1
  end

  test "a beam that vanished makes its own source stale again" do
    sources = fixture!()
    first = BeamLisp.Substrate.compile!(sources, @out)
    state = state_after(first)
    assert bl(BeamLisp.Substrate.stale(state, sources, @out)) == []

    # The hash still matches; the OUTPUT is gone. A freshness rule that only
    # compared hashes would call this source done forever.
    File.rm!(Path.join(@out, "Elixir.Sub.A.beam"))

    assert bl(BeamLisp.Substrate.stale(state, sources, @out)) == [Path.join(@src, "a.ex")]
  end

  test "a source that will not compile is reported and stays stale" do
    sources = fixture!()
    File.write!(Path.join(@src, "c.ex"), "(defmodule Sub.C do\n  def v, do: (\nend)\n")

    result = BeamLisp.Substrate.compile!(sources, @out)

    assert result.compiled == 0
    assert bl(result.facts) == [], "a failed batch records nothing"
    assert Enum.any?(bl(result.errors), &String.contains?(to_string(&1), "c.ex")),
           "the failure must name the file, got: #{inspect(bl(result.errors))}"

    # Nothing was recorded, so every source is still stale — the next run
    # retries rather than believing a broken file is done.
    assert Enum.count(BeamLisp.Substrate.stale(%{ex: %{}}, sources, @out)) == 3
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp fixture! do
    File.write!(Path.join(@src, "a.ex"), "(defmodule Sub.A do\n  def v, do: 1\nend)\n")
    File.write!(Path.join(@src, "b.ex"), "(defmodule Sub.B do\n  def v, do: Sub.A.v()\nend)\n")
    File.write!(Path.join(@src, "c.ex"), "(defmodule Sub.C do\n  def v, do: 3\nend)\n")
    BeamLisp.Substrate.sources(@src, [])
  end

  defp stale(sources, out), do: BeamLisp.Substrate.stale(%{ex: %{}}, sources, out)

  # The stage returns facts; the build owns appending them. Here the test is the
  # caller, so it folds them the same way the build does.
  defp state_after(result) do
    BeamLisp.Loader.ensure_loaded("build-log")
    apply = BeamLisp.Env.fetch!("build-log", "apply-facts")
    BeamLisp.RT.invoke(apply, [%{sources: %{}, ex: %{}, runs: [], errors: []}, result.facts])
  end

  # The language's collections cross back as host structs (a `Vector` is not an
  # Elixir list), so normalise at the boundary.
  defp bl(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp bl(list) when is_list(list), do: list
  defp bl(other), do: other
end
