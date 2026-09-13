defmodule BeamLisp.AotBuildKeyTest do
  use ExUnit.Case, async: false

  # Build-gate regression: `compile.beam_lisp` must recompile a source whose
  # beam was built by a DIFFERENT toolchain — even when the source bytes are
  # unchanged.
  #
  # The bug this locks in: the runtime drift gate (`AOT.stale?/2`) trusts a
  # beam only when BOTH its source-hash AND its `compiler_key` (a hash of the
  # codegen modules + prelude) match the live toolchain. The build task's
  # `up_to_date?/5`, however, used to compare ONLY the source-hash. So after a
  # codegen edit moved `compiler_key`, the two gates disagreed:
  #
  #   * runtime  → key mismatch → REJECT the beam → recompile from source on
  #                EVERY boot (the ~20s startup tax the field hit)
  #   * build    → hash matches → "up to date" → NEVER re-stamp the beam
  #
  # The stale beam was pinned on disk forever; neither side healed. The fix
  # records `compiler_key` in each manifest entry and adds it to the
  # up-to-date test, so a toolchain drift invalidates the entry and an ordinary
  # `mix compile` rebuilds + re-stamps — no `--force` needed. This test forges
  # the drift by rewriting the manifest's stored key and asserts the next
  # (non-force) run rebuilds rather than no-ops.
  #
  # WHERE THE DRIFT IS FORGED MOVED: the build's memory is the fact log now
  # (`priv/build/build-log.bl`) and the manifest is its projection, so a
  # manifest edit changes nothing at all (pinned below) and the forge has to
  # happen where the memory is. Same property, one layer down.

  @fixture_dir "test/fixtures/aot"
  @out Path.join(System.tmp_dir!(), "beam_lisp_aot_build_key")
  @manifest Path.join(@out, "compile.beam_lisp")

  setup do
    BeamLisp.init()
    BeamLisp.BuildTask.clean(@out)
    on_exit(fn -> BeamLisp.BuildTask.clean(@out) end)
    :ok
  end

  defp build!, do: BeamLisp.BuildTask.run(["--source-dir", @fixture_dir, "--out", @out])

  defp read_manifest, do: @manifest |> File.read!() |> :erlang.binary_to_term()
  defp write_manifest(m), do: File.write!(@manifest, :erlang.term_to_binary(m))

  defp math_source_path do
    read_manifest()
    |> Map.keys()
    |> Enum.find(&String.ends_with?(&1, "math.bl"))
  end

  test "a warm build records the compiler_key and no-ops on the second run" do
    assert {:ok, _} = build!()

    m = read_manifest()
    path = math_source_path()
    entry = Map.fetch!(m, path)

    # The entry now carries the toolchain key alongside the source hash.
    assert Map.has_key?(entry, :key), "manifest entry must record :key"
    assert entry.key == BeamLisp.AOTCache.compiler_key()

    # An unchanged tree with a matching key recompiles nothing.
    assert {:noop, []} = build!()
  end

  test "a tier-key drift forces a rebuild without --force" do
    assert {:ok, _} = build!()
    path = math_source_path()

    # Sanity: a plain second run is a no-op (key + tier both match).
    assert {:noop, []} = build!()

    # The manifest is a PROJECTION, so rewriting it changes nothing: the build
    # no longer reads it. Worth pinning, because "the manifest is derived" is
    # now the shape of the whole build.
    m = read_manifest()
    write_manifest(Map.put(m, path, %{Map.fetch!(m, path) | key: "deadbeef-not-current"}))
    assert {:noop, []} = build!()

    # Forge the exact desync a codegen edit produces, where the memory is: same
    # source bytes, but the recorded fact says the beam came from a toolchain
    # whose key is gone. The build must REBUILD, not no-op — the build gate
    # agreeing with the runtime gate. This is the whole fix.
    forge_recorded_tier!(path, "deadbeef-not-the-current-compiler-key")
    refute recorded_tier(path) == BeamLisp.AOTCache.compiler_key()

    assert {:ok, _} = build!()

    # And it re-records the live key, so the tree is warm again.
    assert recorded_tier(path) == BeamLisp.AOTCache.compiler_key()
    assert {:noop, []} = build!()
  end

  test "a pre-log build directory migrates from its manifest, then warms" do
    assert {:ok, _} = build!()
    path = math_source_path()

    # A build directory written before the log existed: a manifest, no log, and
    # an entry in the OLD shape (no :key). The build reads it ONCE — rebuilding
    # the source whose tier key it cannot vouch for, re-stamping it — and is
    # warm from then on. Safe by construction: a missing tier key can only fail
    # the match, never pass it.
    File.rm!(log_path())
    m = read_manifest()
    legacy = m |> Map.fetch!(path) |> Map.delete(:key)
    write_manifest(Map.put(m, path, legacy))

    assert {:ok, _} = build!()
    assert recorded_tier(path) == BeamLisp.AOTCache.compiler_key()
    assert read_manifest() |> Map.fetch!(path) |> Map.has_key?(:key)
    assert {:noop, []} = build!()
  end

  # ── the fact log ─────────────────────────────────────────────────────────

  defp log_path, do: BeamLisp.BuildLog.path_for(@manifest)

  defp recorded_tier(path),
    do: Map.fetch!(BeamLisp.BuildLog.state(log_path()).sources, path).tier

  # The log is TEXT — that is the point of it — so a forge is a string edit, not
  # a rebuild of the structures the reader uses. If the format moves out from
  # under this pattern the test fails loudly rather than passing vacuously.
  defp forge_recorded_tier!(path, tier) do
    text = File.read!(log_path())
    pattern = ~r/(\[:build\/built "#{Regex.escape(path)}" "[0-9a-f]+" )"[^"]*"/
    assert Regex.match?(pattern, text), "no :build/built fact for #{path} in the log"
    File.write!(log_path(), Regex.replace(pattern, text, "\\1\"#{tier}\"", global: false))
  end
end
