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

  @fixture_dir "test/fixtures/aot"
  @out Path.join(System.tmp_dir!(), "beam_lisp_aot_build_key")
  @manifest Path.join(@out, "compile.beam_lisp")

  setup do
    BeamLisp.init()
    Mix.Tasks.Compile.BeamLisp.clean(@out)
    on_exit(fn -> Mix.Tasks.Compile.BeamLisp.clean(@out) end)
    :ok
  end

  defp build!, do: Mix.Tasks.Compile.BeamLisp.run(["--source-dir", @fixture_dir, "--out", @out])

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

  test "a toolchain-key drift forces a rebuild without --force" do
    assert {:ok, _} = build!()
    path = math_source_path()

    # Sanity: a plain second run is a no-op (key + hash both match).
    assert {:noop, []} = build!()

    # Forge the exact desync a codegen edit produces: same source bytes, but
    # the beam was stamped by a toolchain whose key no longer matches. Rewrite
    # ONLY the stored key; leave the source-hash correct.
    m = read_manifest()
    entry = Map.fetch!(m, path)
    stale = %{entry | key: "deadbeef-not-the-current-compiler-key"}
    write_manifest(Map.put(m, path, stale))

    # The build must now REBUILD (not no-op): the key check in up_to_date?/5
    # fails even though the source hash is unchanged. This is the whole fix —
    # the build gate agreeing with the runtime gate.
    assert {:ok, _} = build!()

    # And it re-stamps the entry with the live key, so the tree is warm again.
    restamped = read_manifest() |> Map.fetch!(path)
    assert restamped.key == BeamLisp.AOTCache.compiler_key()
    assert {:noop, []} = build!()
  end

  test "an old-format manifest entry (no :key) rebuilds once, then warms" do
    assert {:ok, _} = build!()
    path = math_source_path()

    # Simulate a manifest written by the pre-fix task: entries had only
    # :hash and :modules. Such an entry must fail the match exactly once and
    # rebuild (re-stamping the key), a safe one-time migration.
    m = read_manifest()
    entry = Map.fetch!(m, path)
    legacy = Map.delete(entry, :key)
    write_manifest(Map.put(m, path, legacy))

    assert {:ok, _} = build!()
    assert read_manifest() |> Map.fetch!(path) |> Map.has_key?(:key)
    assert {:noop, []} = build!()
  end
end
