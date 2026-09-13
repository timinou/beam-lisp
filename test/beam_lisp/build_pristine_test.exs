defmodule BeamLisp.BuildPristineTest do
  @moduledoc """
  The PRISTINE comparison — the machinery PLAN-108's W6 fixpoint gate rests on.

  A comparison that always answers "identical" is not a gate, so the negative
  half IS the point of this suite: three mutations applied at once must produce
  three named differences (an extra path, a missing path, a changed byte) and
  the report must name ALL THREE, not the first. A gate that reports one
  mismatch at a time turns a fixpoint into a guessing game.

  The positive half pins the one measured trap in the artifact layer: the Rust
  packer's output and the language's, for ONE tree, agree on the trailer fields,
  the payload digest and the DECOMPRESSED payload — while their file bytes
  differ, because flate2 and Erlang's `:zlib` are different compressors. The
  comparison reports that as `:sizes` and deliberately does not fail `same?` on
  it; that grain is the fixpoint's.

  The real release tree is compared with itself when one is on this machine
  (tagged `:slow`: it hashes ~300 MB twice). That is the anchor saying the
  machinery works on the thing it will be pointed at, not only on fixtures.

  Interop, observed rather than assumed: bl maps cross to Elixir with ATOM keys
  when the keyword has no hyphen (`same?`, `fields`, `sizes`); a keyword WITH a
  hyphen would arrive as a binary key, which is why `pristine.bl` names none
  that way. bl vectors (the path lists) arrive as `%BeamLisp.Vector{}`, so
  `bl/1` normalises them.
  """
  use ExUnit.Case, async: false

  @base "/tmp/beam_lisp_pristine_base"
  @mutated "/tmp/beam_lisp_pristine_mutated"
  @release_tree "/tmp/beam_lisp_release_tree"

  defp bl(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp bl(v), do: v

  defp tree!(root) do
    File.rm_rf!(root)

    for dir <- ["bin", "lib/thing-0.1.0/ebin", "lib/thing-0.1.0/priv"],
        do: File.mkdir_p!(Path.join(root, dir))

    File.write!(Path.join(root, "bin/bl"), "#!/bin/sh\nexec node\n")
    File.write!(Path.join(root, "lib/thing-0.1.0/ebin/Elixir.Thing.beam"), :crypto.strong_rand_bytes(1024))
    File.write!(Path.join(root, "lib/thing-0.1.0/priv/data.txt"), "")
    File.write!(Path.join(root, "lib/thing-0.1.0/priv/big.txt"), String.duplicate("x", 2000))
    root
  end

  defp copy_of_base! do
    File.rm_rf!(@mutated)
    File.cp_r!(@base, @mutated)
    @mutated
  end

  setup do
    BeamLisp.init()
    tree!(@base)
    :ok
  end

  test "an identical tree is identical, and the report is one word" do
    copy_of_base!()
    diff = BeamLisp.Pristine.trees(@base, @mutated)

    assert diff[:same?]
    assert diff[:trees][:same?]
    assert bl(diff[:trees][:added]) == []
    assert bl(diff[:trees][:removed]) == []
    assert bl(diff[:trees][:changed]) == []
    assert diff[:trees][:files] == %{a: 4, b: 4}
    assert diff[:trees][:bytes][:a] == diff[:trees][:bytes][:b]
    assert diff[:tar][:same?]
    assert diff[:tar][:sizes][:a] == diff[:tar][:sizes][:b]
    assert BeamLisp.Pristine.report(diff) == "identical"
  end

  test "an extra path, a missing path and a changed byte are THREE findings, all reported" do
    copy_of_base!()
    File.write!(Path.join(@mutated, "lib/thing-0.1.0/priv/extra.txt"), "new\n")
    File.rm!(Path.join(@mutated, "lib/thing-0.1.0/priv/data.txt"))
    File.write!(Path.join(@mutated, "bin/bl"), "#!/bin/sh\nexec node --changed\n")

    diff = BeamLisp.Pristine.trees(@base, @mutated)
    refute diff[:same?]
    assert bl(diff[:trees][:added]) == ["lib/thing-0.1.0/priv/extra.txt"]
    assert bl(diff[:trees][:removed]) == ["lib/thing-0.1.0/priv/data.txt"]
    assert bl(diff[:trees][:changed]) == ["bin/bl"]

    # one file added, one removed: the counts stay equal while the byte totals
    # do not — the added file is 4 bytes, and `bin/bl` is 10 bytes longer.
    assert diff[:trees][:files] == %{a: 4, b: 4}
    assert diff[:trees][:bytes][:b] - diff[:trees][:bytes][:a] == 14

    # EVERY difference, not the first: a gate that names one mismatch at a time
    # makes a fixpoint a guessing game.
    report = BeamLisp.Pristine.report(diff)
    assert report =~ "extra.txt"
    assert report =~ "data.txt"
    assert report =~ "bin/bl"
    assert length(String.split(report, "\n")) == 3
  end

  test "the tar layer has teeth: content changes even when the size does not" do
    copy_of_base!()
    File.write!(Path.join(@mutated, "bin/bl"), "#!/bin/sh\nexec node\nX")

    diff = BeamLisp.Pristine.trees(@base, @mutated)
    assert bl(diff[:trees][:changed]) == ["bin/bl"]
    refute diff[:tar][:same?]

    # tar is block-granular (512 B), so ONE added byte does not move the total:
    # the CONTENT changed, which is what `same?` reads. A comparison that only
    # looked at sizes would miss this edit entirely.
    assert diff[:tar][:sizes][:a] == diff[:tar][:sizes][:b]

    # and a change large enough to cross a block does move the size
    File.write!(Path.join(@mutated, "bin/bl"), String.duplicate("y", 600))
    bigger = BeamLisp.Pristine.trees(@base, @mutated)
    refute bigger[:tar][:same?]
    assert bigger[:tar][:sizes][:b] > bigger[:tar][:sizes][:a]
  end

  test "a file that is not a drop is refused, by name" do
    plain = Path.join(@base, "bin/not-a-drop")
    File.write!(plain, :crypto.strong_rand_bytes(4096))

    d = BeamLisp.Pristine.drops(plain, plain)
    refute d[:same?]
    refute d[:a][:drop?]
    assert BeamLisp.Pristine.report(d) =~ "not a v1 drop"
  end

  test "two producers of one tree: same trailer, same payload, same bytes once decompressed" do
    rust = "/tmp/beam_lisp_pack_rust.bl"
    ours = "/tmp/beam_lisp_pack_ours.bl"

    if File.exists?(rust) and File.exists?(ours) do
      d = BeamLisp.Pristine.drops(rust, ours)

      assert d[:fields][:same?]
      assert d[:arithmetic][:same?]
      assert d[:stored][:same?]
      # the layer that makes the comparison trustworthy at all: whatever the
      # compressor did, the bytes that come back are the same bytes.
      assert d[:decompressed][:same?]
      assert d[:same?]

      # and the measured trap, ASSERTED rather than hidden: two compressors make
      # different COMPRESSED payloads and different file sizes for identical
      # bytes (measured: len 1973 vs 1998 on one fixture tree). Those two
      # sections are reported without failing `same?`.
      refute d[:compressed][:same?]
      refute d[:sizes][:same?]
      assert d[:compressed][:a][:len] != d[:compressed][:b][:len]
      assert BeamLisp.Pristine.report(d) =~ "compressed"
      assert BeamLisp.Pristine.report(d) =~ "sizes"
    else
      # Those fixtures belong to BuildPackTest, which packs one tree with both
      # producers. Failing here would be a false alarm; passing silently would
      # be a lie, so the suite says which it is.
      IO.puts("BuildPristineTest: skipped the two-producer case — #{rust} / #{ours} not present")
      assert true
    end
  end

  @tag :slow
  test "ONE producer's two packs of one tree are byte-identical end to end" do
    tree = @release_tree
    launcher = System.get_env("BL_LAUNCHER") || "/home/user/.cache/cargo-target/release/drop-launcher"

    if File.dir?(tree) and File.exists?(launcher) do
      # Self-contained on purpose: two packs made HERE, from the tree as it is
      # now. Comparing two stored files instead was wrong once already — one of
      # them turned out to be a pack of a tree from before the priv fix, and the
      # mismatch looked like nondeterminism when it was a stale fixture.
      a = BeamLisp.Drop.pack(tree, launcher, "/tmp/beam_lisp_pristine_pack_a.bl")
      b = BeamLisp.Drop.pack(tree, launcher, "/tmp/beam_lisp_pristine_pack_b.bl")
      assert a[:ok?] and b[:ok?]

      # The fixpoint ONE producer can demand of itself: not merely the same
      # payload once decompressed, but the same FILE. `pack`'s result carries
      # `:out`, not `:path` — asking for the latter raises, which is how the
      # first version of this test spent a run looking like nondeterminism.
      assert BeamLisp.Pristine.compounds_identical?(a[:out], b[:out])

      d = BeamLisp.Pristine.drops(a[:out], b[:out])
      assert d[:same?]
      assert d[:compressed][:same?]
      assert d[:sizes][:same?]
      assert BeamLisp.Pristine.report(d) == "identical"
    else
      IO.puts("BuildPristineTest: skipped the single-producer fixpoint — #{tree} / #{launcher} missing")
      assert true
    end
  end

  @tag :slow
  test "the real release tree compared with itself is identical" do
    if File.dir?(@release_tree) do
      diff = BeamLisp.Pristine.trees(@release_tree, @release_tree)
      assert diff[:same?]
      assert diff[:trees][:files][:a] > 200
      assert diff[:trees][:bytes][:a] > 10_000_000
      assert BeamLisp.Pristine.report(diff) == "identical"
    else
      IO.puts("BuildPristineTest: skipped the real-tree anchor — #{@release_tree} not present")
      assert true
    end
  end
end
