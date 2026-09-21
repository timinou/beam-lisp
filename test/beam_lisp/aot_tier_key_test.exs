defmodule BeamLisp.AotTierKeyTest do
  use ExUnit.Case, async: false

  # W1: the toolchain has TWO keys, and the split is what stops a build-tool edit
  # from invalidating every beam in the tree. Codegen (`priv/boot/`) hashes into
  # `compiler_key/0`; the build driver (`priv/build/`) into `build_key/0`, which
  # folds `compiler_key/0` in because the driver is compiled BY the codegen.
  #
  # Before the split, `compiler_key/0` hashed the whole of `priv/boot/` — the
  # driver included — so editing `build.bl` moved the toolchain key and rebuilt
  # ~300 beams. Measured cost of that amplifier: 8 key generations in ~21h.

  test "the two tier keys exist, differ, and are stable across a recompute" do
    BeamLisp.AOTCache.reset_keys()

    compiler = BeamLisp.AOTCache.compiler_key()
    build = BeamLisp.AOTCache.build_key()

    assert is_binary(compiler) and byte_size(compiler) == 64
    assert is_binary(build) and byte_size(build) == 64
    refute build == compiler

    # Recomputing from the same tree yields the same keys: a key is a function
    # of the bytes, never of time.
    BeamLisp.AOTCache.reset_keys()
    assert BeamLisp.AOTCache.compiler_key() == compiler
    assert BeamLisp.AOTCache.build_key() == build
  end

  test "a namespace's stamp key is its tier's key" do
    compiler = BeamLisp.AOTCache.compiler_key()
    build = BeamLisp.AOTCache.build_key()

    assert BeamLisp.AOTCache.key_for_ns("compiler") == compiler
    assert BeamLisp.AOTCache.key_for_ns("reader-node") == compiler
    assert BeamLisp.AOTCache.key_for_ns("core") == compiler

    assert BeamLisp.AOTCache.key_for_ns("build") == build
    assert BeamLisp.AOTCache.key_for_ns("build-plan") == build
    assert BeamLisp.AOTCache.key_for_ns("source-graph") == build
    assert BeamLisp.AOTCache.key_for_ns("ns-interface") == build

    # An ordinary namespace is stamped with the codegen key, as before.
    assert BeamLisp.AOTCache.key_for_ns("datom") == compiler
  end

  test "a source's stamp key is the tier of its file" do
    compiler = BeamLisp.AOTCache.compiler_key()
    build = BeamLisp.AOTCache.build_key()

    assert BeamLisp.AOTCache.key_for_source("priv/boot/compiler.bl") == compiler
    assert BeamLisp.AOTCache.key_for_source("priv/std/errors.bl") == compiler
    assert BeamLisp.AOTCache.key_for_source("priv/lib/datom.bl") == compiler
    assert BeamLisp.AOTCache.key_for_source("priv/build/build.bl") == build
    assert BeamLisp.AOTCache.key_for_source("priv/build/build-plan.bl") == build
  end

  test "the build tier is exactly the set the gate cannot closure-hash" do
    # `ns_closure_hash/1` answers through `build-plan` → `source-graph`, so a
    # build-tier namespace asked for its own closure would recurse into the load
    # the gate is vetting. That is WHY the tier is keyed by a hash of its own
    # directory instead of by an interface closure. If a driver namespace ever
    # moves out of `priv/build/`, the gate would have no sound key for it — this
    # test fails first.
    for ns <- ~w(build build-plan source-graph ns-interface) do
      assert BeamLisp.Tiers.tier_of_ns(ns) == :build
    end

    # `reader-node` is the fourth namespace the gate runs on, and it is codegen.
    assert BeamLisp.Tiers.tier_of_ns("reader-node") == :boot
  end

  test "the app release version is NOT an input to the toolchain keys" do
    # The compiler_key is the TOOLCHAIN GENERATION, not the release. A release
    # build stamps env.bl `:vsn` (0.1.0 -> 2026.4.0) with no source change, and
    # that stamp must not manufacture a new generation: the committed bootstrap
    # floor is seeded once at a fixed version, and a version-rotated key made the
    # floor foreign to every stamped release, so the launcher rebuilt the boot
    # tier from a mismatched floor and died `undefined var: compiler/special-forms`.
    # Keys are a function of codegen + toolchain sources + Elixir/OTP/backend,
    # never of the release label.
    #
    # There is no public API to mutate a loaded app's :vsn, so this asserts the
    # invariant at the source: `compute_compiler_key/0` reads neither
    # `:application.get_key(_, :vsn)` nor `env.bl`'s version. A future edit that
    # reintroduces the version into the toolchain key fails here.
    source = File.read!("lib/beam_lisp/aot_cache.ex")
    [_, key_body] = String.split(source, "defp compute_compiler_key do", parts: 2)
    [key_body | _] = String.split(key_body, "\n  defp ", parts: 2)

    refute key_body =~ "get_key(:beam_lisp, :vsn)",
           "compute_compiler_key must not read the app version into the toolchain key"
    refute key_body =~ "beam_lisp:#",
           "compute_compiler_key must not hash the app version string into the key"

    # And the keys are a pure function of the bytes: recomputing yields the same
    # value, so nothing time- or run-varying (which a version bump would be)
    # leaked in.
    BeamLisp.AOTCache.reset_keys()
    compiler = BeamLisp.AOTCache.compiler_key()
    build = BeamLisp.AOTCache.build_key()
    BeamLisp.AOTCache.reset_keys()
    assert BeamLisp.AOTCache.compiler_key() == compiler
    assert BeamLisp.AOTCache.build_key() == build
  end
end
