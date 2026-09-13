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
end
