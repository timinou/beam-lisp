defmodule BeamLisp.BuildDropTest do
  @moduledoc """
  The drop COMPOUND codec: `launcher ⊕ payload ⊕ trailer`, read and re-emitted
  by the language.

  The oracle is the Rust tool's own output. `@golden_trailer` is the last 56
  bytes of a real `drop pack` compound; the suite pins that we parse those
  fields and that re-encoding them gives the SAME 56 bytes. A golden vector
  copied by hand into the codec's own format would only prove we are
  self-consistent; bytes the packer produced prove we are compatible.

  Everything else here is the failure half: a file that is not a drop, a
  truncated one, and a corrupted payload must be told apart, because a launcher
  has to decide whether to run, re-fetch, or complain.
  """
  use ExUnit.Case, async: false

  # The trailer of a `drop pack` output (payload 1801b898…):
  #   offset 810104, len 103013141, os 0 (linux), arch 0 (x86_64), version 1
  @golden_trailer "785c0c000000000015db230600000000cbe87a0933e34c2a20ad25e83765a0f6964347d9b6d96d7a25ae7a27d0220c870000010044525031"
  @golden_sha "cbe87a0933e34c2a20ad25e83765a0f6964347d9b6d96d7a25ae7a27d0220c87"
  @golden_offset 810_104
  @golden_len 103_013_141

  # Where a real drop lives, when one happens to be on this machine: the repo's
  # root `bl` (gitignored, produced by `drop pack`), or wherever BL_COMPOUND
  # points (a worktree has no `bl` of its own). The suite uses it when it is
  # there and says so when it is not — the golden vectors above need no file.
  @real System.get_env("BL_COMPOUND") || Path.join(File.cwd!(), "bl")

  setup do
    BeamLisp.init()
    File.rm_rf!("/tmp/beam_lisp_drop_fixture")
    File.mkdir_p!("/tmp/beam_lisp_drop_fixture")
    :ok
  end

  test "a real trailer decodes to its fields, and re-encodes to the same bytes" do
    golden = Base.decode16!(@golden_trailer, case: :lower)
    assert byte_size(golden) == 56

    t = BeamLisp.Drop.parse_trailer(golden)
    assert t.offset == @golden_offset
    assert t.len == @golden_len
    assert t.os == 0 and t.arch == 0 and t.version == 1
    assert Base.encode16(t.sha, case: :lower) == @golden_sha
    assert BeamLisp.Drop.target(t) == "linux/x86_64"

    # The acceptance in one line: the bytes we would WRITE for these fields are
    # the bytes the Rust packer wrote.
    assert BeamLisp.Drop.encode_trailer(t) == golden
  end

  test "a file that is not a drop is nil, not an exception" do
    path = Path.join("/tmp/beam_lisp_drop_fixture", "plain")
    File.write!(path, :crypto.strong_rand_bytes(4096))

    assert BeamLisp.Drop.compound(path) == nil
    assert BeamLisp.Drop.verify(path).ok? == false
    assert BeamLisp.Drop.verify(path).reason =~ "not a v1 drop"

    # Too short to hold a trailer at all — the other way to not be a drop.
    short = Path.join("/tmp/beam_lisp_drop_fixture", "short")
    File.write!(short, "too small")
    assert BeamLisp.Drop.compound(short) == nil
  end

  test "verification tells TRUNCATION from CORRUPTION" do
    payload = "hello payload"
    sha = BeamLisp.Drop.sha256_hex_of("/dev/null", 0, 0)
    assert is_binary(sha), "hashing an empty slice must work"

    # A synthesised compound: 3 bytes of launcher, a payload, our own trailer.
    launcher = "LCH"
    digest = beam_lisp_sha(payload)

    good = Path.join("/tmp/beam_lisp_drop_fixture", "good.bl")
    trailer = trailer_for(byte_size(launcher), byte_size(payload), digest)
    File.write!(good, launcher <> payload <> trailer)

    c = BeamLisp.Drop.compound(good)
    assert c.size == byte_size(launcher) + byte_size(payload) + 56
    assert c.launcher.len == byte_size(launcher)
    assert c.payload.offset == byte_size(launcher)

    v = BeamLisp.Drop.verify(good)
    assert v.ok?, "a well-formed compound must verify: #{inspect(v)}"
    assert v.expected == digest and v.actual == digest

    # Truncated: the trailer is gone, so the arithmetic is what fails — and the
    # payload's digest is never even reached.
    cut = Path.join("/tmp/beam_lisp_drop_fixture", "cut.bl")
    File.write!(cut, binary_part(File.read!(good), 0, byte_size(launcher) + 4) <> trailer)
    vcut = BeamLisp.Drop.verify(cut)
    refute vcut.ok?
    assert vcut.arithmetic == false
    assert vcut.reason =~ "does not equal the file size"

    # Corrupted: the length is right, the bytes are not. A verifier that only
    # checked the arithmetic would run this.
    bad = Path.join("/tmp/beam_lisp_drop_fixture", "bad.bl")
    File.write!(bad, launcher <> "HELLO payload" <> trailer)
    vbad = BeamLisp.Drop.verify(bad)
    refute vbad.ok?
    assert vbad.arithmetic == true
    assert vbad.reason =~ "digest does not match"
  end

  test "a real compound on this machine verifies end to end" do
    if File.exists?(@real) do
      c = BeamLisp.Drop.compound(@real)
      assert c != nil, "#{@real} exists but does not read as a drop"
      assert c.size == c.payload.offset + c.payload.len + 56

      # 100 MB of payload, streamed in 1 MB chunks and compared with the digest
      # the packer stored.
      v = BeamLisp.Drop.verify(@real)
      assert v.ok?, "verify failed: #{inspect(v)}"
      assert v.target == "linux/x86_64"
      assert byte_size(File.read!(@real)) == v.size
    else
      IO.puts("BuildDropTest: no real compound at #{@real}; set BL_COMPOUND to check one")
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp beam_lisp_sha(text) do
    BeamLisp.Drop.sha256_hex_of(write_temp(text), 0, byte_size(text))
  end

  defp write_temp(text) do
    p = Path.join("/tmp/beam_lisp_drop_fixture", "slice-#{byte_size(text)}")
    File.write!(p, text)
    p
  end

  defp trailer_for(offset, len, sha_hex) do
    BeamLisp.Drop.encode_trailer(%{
      offset: offset,
      len: len,
      sha: Base.decode16!(sha_hex, case: :lower),
      os: 0,
      arch: 0
    })
  end
end
