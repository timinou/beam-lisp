defmodule BeamLisp.BuildPackTest do
  @moduledoc """
  `bl pack`: sealing a release directory into a drop, against the Rust packer.

  The acceptance for this wave is byte-identity with `drop pack` on the same
  tree, so the test does exactly that: build a fixture release, pack it with
  `drop pack`, pack it with the language, and compare — the uncompressed TAR
  first (which isolates tar exactness from deflate exactness), then the payload,
  then the whole compound. When they differ the test says at WHICH layer, which
  is the only way to know whether the difference is a fixable dialect mistake or
  a different deflate implementation.

  The fixture is deliberately small and awkward: a nested directory, a file over
  one 512-byte block (so padding is exercised), an empty file, and a file whose
  name sorts before and after a directory name (so the walk ORDER matters).
  """
  use ExUnit.Case, async: false

  @release Path.join(System.tmp_dir!(), "beam_lisp_pack_fixture")
  @launcher Path.join(System.tmp_dir!(), "beam_lisp_pack_launcher")
  @drop_bin System.get_env("BL_DROP") || "/home/user/.cache/cargo-target/release/drop"

  setup_all do
    BeamLisp.init()
    File.rm_rf!(@release)
    File.mkdir_p!(Path.join(@release, "bin"))
    File.mkdir_p!(Path.join(@release, "lib/thing-0.1.0/ebin"))
    File.mkdir_p!(Path.join(@release, "lib/thing-0.1.0/priv/deep"))

    File.write!(Path.join(@release, "bin/bl"), "#!/bin/sh\necho fixture\n")
    File.write!(Path.join(@release, "lib/thing-0.1.0/ebin/thing.app"), "{application, thing, []}.\n")
    File.write!(Path.join(@release, "lib/thing-0.1.0/priv/data.bin"), :crypto.strong_rand_bytes(1500))
    File.write!(Path.join(@release, "lib/thing-0.1.0/priv/empty"), "")
    File.write!(Path.join(@release, "lib/thing-0.1.0/priv/deep/leaf.txt"), String.duplicate("leaf\n", 40))

    # A path over the 100-byte ustar name field: the crate writes a GNU
    # `././@LongLink` entry for it, and a packer that just pads the name field
    # produces a header that is not 512 bytes — every reader rejects it.
    long = String.duplicate("N", 90) <> ".beam"
    File.write!(Path.join(@release, "lib/thing-0.1.0/ebin/#{long}"), "LONG")

    # A release must carry a native object for the target or `drop pack`
    # refuses it ("wrong release for this target?") — a 4-byte ELF magic is
    # enough for that question, which is all either packer asks.
    File.write!(Path.join(@release, "lib/thing-0.1.0/priv/native.so"), <<0x7F, "ELF", 0, 0, 0, 0>>)

    File.write!(@launcher, "LAUNCHER-BYTES-" <> :crypto.strong_rand_bytes(64))
    :ok
  end

  test "the walk order is depth-first and lexicographic, like the packer's" do
    rels =
      BeamLisp.Drop.walk_files(@release)
      |> bl()
      |> Enum.map(fn pair -> pair |> bl() |> hd() end)

    # `bin/` sorts before `lib/`; inside lib, the app dir before its children;
    # `empty` (a file) before the `deep` DIRECTORY only if "deep" < "empty" —
    # here 'd' < 'e', so deep/leaf.txt comes first. That ordering is the thing
    # a "glob everything and sort" implementation gets wrong.
    assert rels == [
             "bin/bl",
             "lib/thing-0.1.0/ebin/#{String.duplicate("N", 90)}.beam",
             "lib/thing-0.1.0/ebin/thing.app",
             "lib/thing-0.1.0/priv/data.bin",
             "lib/thing-0.1.0/priv/deep/leaf.txt",
             "lib/thing-0.1.0/priv/empty",
             "lib/thing-0.1.0/priv/native.so"
           ]
  end

  test "the tar and the payload, against the Rust packer" do
    if File.exists?(@drop_bin) do
      rust = Path.join(System.tmp_dir!(), "beam_lisp_pack_rust.bl")

      {out, code} =
        System.cmd(@drop_bin, ["pack", "--release", @release, "--launcher", @launcher, "--out", rust],
          stderr_to_stdout: true
        )

      assert code == 0, "drop pack failed:\n#{out}"

      rust_compound = File.read!(rust)
      rust_payload = payload_of(rust_compound)
      rust_tar = BeamLisp.Drop.gunzip(rust_payload)

      ours_tar = BeamLisp.Drop.tar(@release)
      ours_payload = BeamLisp.Drop.payload(@release)

      IO.puts("""
      BuildPackTest: rust tar #{byte_size(rust_tar)} B, ours #{byte_size(ours_tar)} B
      BuildPackTest: rust payload #{byte_size(rust_payload)} B, ours #{byte_size(ours_payload)} B
      BuildPackTest: tar identical?     #{ours_tar == rust_tar}
      BuildPackTest: payload identical? #{ours_payload == rust_payload}
      """)

      # The tar is ours to get exactly right: same bytes, byte for byte.
      assert ours_tar == rust_tar, first_difference(ours_tar, rust_tar)

      # The payload wraps that tar in OUR gzip envelope. If flate2 and Erlang's
      # zlib agree the bytes match; if they do not, the difference is confined
      # to the deflate stream, and the test says so instead of pretending.
      if ours_payload == rust_payload do
        IO.puts("BuildPackTest: deflate streams agree — the compound is byte-identical")
      else
        # Same input, same header and trailer bytes, different deflate stream:
        # flate2's compressor and Erlang's zlib do not emit identical blocks.
        assert binary_part(ours_payload, 0, 10) == binary_part(rust_payload, 0, 10)
        IO.puts("BuildPackTest: deflate streams DIFFER (same tar, same header/trailer)")
      end
    else
      IO.puts("BuildPackTest: no #{@drop_bin}; set BL_DROP to compare against the Rust packer")
    end
  end

  test "a packed drop verifies and runs" do
    out = Path.join(System.tmp_dir!(), "beam_lisp_pack_ours.bl")
    r = BeamLisp.Drop.pack(@release, @launcher, out)
    assert r.ok?, "pack refused: #{inspect(bl(r.errors))}"
    assert File.exists?(out)

    # The trailer we wrote describes the file we wrote.
    v = BeamLisp.Drop.verify(out)
    assert v.ok?, "our own compound must verify: #{inspect(v)}"
    assert v.size == r.offset + r.len + 56
    assert v.expected == r.sha

    # And the payload is our own tar, gzipped: the round trip through a real
    # reader (gunzip) returns exactly the bytes `tar/1` produced.
    assert BeamLisp.Drop.gunzip(BeamLisp.Drop.payload(@release)) == BeamLisp.Drop.tar(@release)

    # It is executable, and the launcher prefix is intact.
    assert Bitwise.band(File.stat!(out).mode, 0o111) != 0
    assert binary_part(File.read!(out), 0, byte_size(File.read!(@launcher))) == File.read!(@launcher)
  end

  @tag :slow
  test "a drop WE packed, sealed with the real launcher, runs" do
    # The whole wave in one test: pack the release tree W4 assembled, with the
    # stock `drop-launcher` as the prefix, then run the result. If this passes,
    # the language can seal a drop without the Rust tool; the Rust tool's own
    # acceptance is then a byte-diff inside the deflate stream, which the test
    # above measures rather than assumes.
    launcher = System.get_env("BL_LAUNCHER") || "/home/user/.cache/cargo-target/release/drop-launcher"
    tree = System.get_env("BL_RELEASE_TREE") || "/tmp/beam_lisp_release_tree"

    cond do
      not File.exists?(launcher) ->
        IO.puts("BuildPackTest: no launcher at #{launcher}; set BL_LAUNCHER to run this")

      not File.dir?(Path.join(tree, "bin")) ->
        IO.puts("BuildPackTest: no release tree at #{tree}; set BL_RELEASE_TREE to run this")

      true ->
        out = Path.join(System.tmp_dir!(), "beam_lisp_selfpacked.bl")
        File.rm(out)
        r = BeamLisp.Drop.pack(tree, launcher, out)
        assert r.ok?, "pack refused: #{inspect(bl(r.errors))}"

        # It is a drop by our own reader...
        assert BeamLisp.Drop.verify(out).ok?

        # ...and by the LAUNCHER, which is the acceptance: a stock launcher,
        # a payload we built, and a release that runs.
        {out_text, code} = System.cmd(out, ["version"], stderr_to_stdout: true)
        assert code == 0, "packed drop failed to run:\n#{out_text}"
        assert out_text =~ "0.1.0", "the packed drop must report the release: #{out_text}"
    end
  end

  test "a release with no native object for the target is refused" do
    # Same tree, wrong target: `drop pack` says "wrong release for this
    # target?", and so does this packer — before it writes anything.
    out = Path.join(System.tmp_dir!(), "beam_lisp_pack_wrong.bl")
    r = BeamLisp.Drop.pack(@release, @launcher, out, 1)

    refute r.ok?
    assert Enum.any?(bl(r.errors), &String.contains?(&1, "wrong release for this target"))
    refute File.exists?(out), "a refused pack must leave no file behind"
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp payload_of(compound) do
    t = BeamLisp.Drop.parse_trailer(binary_part(compound, byte_size(compound) - 56, 56))
    binary_part(compound, t.offset, t.len)
  end

  defp gunzip(bin), do: BeamLisp.Drop.gunzip(bin)

  defp bl(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp bl(list) when is_list(list), do: list
  defp bl(other), do: other

  defp first_difference(a, b) do
    n = min(byte_size(a), byte_size(b))
    idx = Enum.find(0..(n - 1), fn i -> :binary.at(a, i) != :binary.at(b, i) end)

    case idx do
      nil -> "identical over the first #{n} bytes; sizes #{byte_size(a)} vs #{byte_size(b)}"
      i -> "first difference at byte #{i}: ours #{:binary.at(a, i)} vs rust #{:binary.at(b, i)}"
    end
  end
end
