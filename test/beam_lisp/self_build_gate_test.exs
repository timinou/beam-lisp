defmodule BeamLisp.SelfBuildGateTest do
  @moduledoc """
  THE FIXPOINT GATE (PLAN-108 W6) — the whole chain, run, and compared.

  Tagged `:selfbuild`: it packs a 100 MB drop three times and rebuilds 166 tier
  sources twice, so it takes minutes and is opt-in:

      mix test test/beam_lisp/self_build_gate_test.exs --include selfbuild

  What it asserts, in the order the wave's gates were written:

    G1  the new generation BOOTS: `version` answers, `eval` computes.
    G4  the FIXPOINT is exact: gen-2 and gen-3 are byte-identical.

  Why it runs the ARTIFACTS rather than the functions: a self-build's whole claim
  is that a shipped drop can reproduce itself, so the thing invoked must be the
  packed compound, launched the way a user launches it. `gen-1` is the last
  artefact the Rust tooling makes; every generation after it comes from
  `bl self-build` inside the previous one.
  """
  use ExUnit.Case, async: false

  @moduletag :selfbuild
  @moduletag timeout: 1_800_000

  @tree "/tmp/beam_lisp_gate_tree"
  @gen1 "/tmp/bl-gate-gen1"
  @gen2 "/tmp/bl-gate-gen2"
  @gen3 "/tmp/bl-gate-gen3"
  @stock_launcher "/home/user/.cache/cargo-target/release/drop-launcher"

  defp run!(bin, args) do
    {out, code} = System.cmd(bin, args, stderr_to_stdout: true, env: [{"BL_DAEMON", "off"}])
    {out, code}
  end

  defp self_build!(from, to, scratch) do
    File.rm_rf!(scratch)
    File.rm_rf!(to)
    {out, code} = run!(from, ["self-build", "--out", to, "--scratch", scratch])
    assert code == 0, "self-build #{from} → #{to} failed:\n#{out}"
    assert out =~ "tier sources rebuilt"
    out
  end

  test "gen-1 builds gen-2, gen-2 builds gen-3, and the fixpoint is exact" do
    if File.exists?(@stock_launcher) do
      BeamLisp.init()
      BeamLisp.Loader.ensure_loaded("release")

      # ── gen-1: the last artefact the Rust tooling makes ──────────────────
      value = BeamLisp.RT.invoke(BeamLisp.Env.fetch!("release", "value"), [:beam_lisp])
      a = BeamLisp.RT.invoke(BeamLisp.Env.fetch!("release", "assemble"), [value, @tree])
      assert a[:ok?], "assemble failed: #{inspect(a[:errors])}"

      p = BeamLisp.Drop.pack(@tree, @stock_launcher, @gen1)
      assert p[:ok?]
      File.chmod!(@gen1, 0o755)

      # ── G1: each generation boots ────────────────────────────────────────
      self_build!(@gen1, @gen2, "/tmp/bl-gate-sb2")
      File.chmod!(@gen2, 0o755)

      {v, c1} = run!(@gen2, ["version"])
      assert c1 == 0 and v =~ "beam-lisp"
      {e, c2} = run!(@gen2, ["eval", "(+ 40 2)"])
      assert c2 == 0 and e =~ "42"

      self_build!(@gen2, @gen3, "/tmp/bl-gate-sb3")

      # ── G4: the fixpoint, byte for byte ──────────────────────────────────
      assert BeamLisp.Pristine.compounds_identical?(@gen2, @gen3),
             "gen-2 and gen-3 differ:\n" <> BeamLisp.Pristine.report(BeamLisp.Pristine.drops(@gen2, @gen3))

      d = BeamLisp.Pristine.drops(@gen2, @gen3)
      assert d[:same?]
      assert d[:compressed][:same?]
      assert d[:sizes][:same?]
      assert BeamLisp.Pristine.report(d) == "identical"

      # gen-3 runs too: a fixpoint that cannot boot is a coincidence.
      File.chmod!(@gen3, 0o755)
      {v3, c3} = run!(@gen3, ["version"])
      assert c3 == 0 and v3 =~ "beam-lisp"

      # ── and the disk is given back: three compounds and three trees ──────
      for f <- [@gen1, @gen2, @gen3], do: File.rm_rf!(f)
      for d <- [@tree, "/tmp/bl-gate-sb2", "/tmp/bl-gate-sb3", "/tmp/bl-selfbuild-src"], do: File.rm_rf!(d)
    else
      IO.puts("SelfBuildGateTest: skipped — no stock launcher at #{@stock_launcher}")
      assert true
    end
  end
end
