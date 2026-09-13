defmodule BeamLisp.Drop do
  @moduledoc """
  The drop COMPOUND codec, delegated to the language: `priv/build/drop.bl`.

  A drop is `launcher ⊕ payload ⊕ trailer`, and the trailer is what makes it
  self-describing: 56 bytes at EOF holding the payload's offset, length,
  sha256, OS/arch tags, a format version and the magic `DRP1`. Reading a
  100 MB compound therefore costs a seek and 56 bytes; verifying it streams the
  payload through `:crypto.hash_update/2` in 1 MB chunks.

  The format contract is `tooling/drop/src/common.rs` (the Rust packer). This
  module exists so the drop can check, seal and re-pack itself without the Rust
  tool in the loop, and the suite pins it against bytes the Rust tool produced.

  Like `BeamLisp.BuildPlan` and `BeamLisp.BuildLog`, this is the Elixir call
  surface; the logic is in `priv/build/drop.bl`.
  """

  @ns "drop"

  @doc "The 56-byte trailer in `bin`'s tail as a map, or nil when not a v1 drop."
  @spec parse_trailer(binary) :: map | nil
  def parse_trailer(bin), do: call("parse-trailer", [bin])

  @doc "The 56 trailer bytes for a map `%{offset:, len:, sha:, os:, arch:}`."
  @spec encode_trailer(map) :: binary
  def encode_trailer(m), do: call("encode-trailer", [m])

  @doc """
  `%{path:, size:, launcher: %{offset:, len:}, payload: %{…}, trailer: %{…}}`
  for a drop, or nil when `path` is not one.
  """
  @spec compound(binary) :: map | nil
  def compound(path) when is_binary(path), do: call("compound", [path])

  @doc """
  Check a drop against its own trailer: the payload digest AND the arithmetic
  (`offset + len + 56` is the file size). Returns `%{ok?: bool, size:,
  expected:, actual:, arithmetic:, target:, reason:}`; the two failures are
  reported apart, because a truncated download and a corrupted payload are
  different problems.
  """
  @spec verify(binary) :: map
  def verify(path) when is_binary(path), do: call("verify", [path])

  @doc "The trailer's `{os, arch}` tags as a string such as `linux/x86_64`."
  @spec target(map) :: binary
  def target(trailer), do: call("target", [trailer])

  @doc "Lowercase hex sha256 of `len` bytes at `start` in `path` (streamed)."
  @spec sha256_hex_of(binary, non_neg_integer, non_neg_integer) :: binary | nil
  def sha256_hex_of(path, start, len), do: call("sha256-hex-of", [path, start, len])

  @doc "The last `n` bytes of `path` (nil when the file is smaller)."
  @spec tail(binary, non_neg_integer) :: binary | nil
  def tail(path, n), do: call("tail", [path, n])

  @doc "Every file under `root` as `[relative, absolute]`, in `drop pack`'s walk order."
  @spec walk_files(binary) :: [list]
  def walk_files(root), do: call("walk-files", [root])

  @doc "The tar stream `drop pack` would write for a release directory."
  @spec tar(binary) :: binary
  def tar(root), do: call("tar", [root])

  @doc "The gzip payload `drop pack` would write for a release directory."
  @spec payload(binary) :: binary
  def payload(root), do: call("payload", [root])

  @doc "The gzip envelope (fixed header, raw deflate, crc32, isize) for `data`."
  @spec gzip(binary) :: binary
  def gzip(data), do: call("gzip", [data])

  @doc "gunzip."
  @spec gunzip(binary) :: binary
  def gunzip(data), do: call("gunzip", [data])

  @doc """
  Seal `release` into a drop at `out`, using `launcher` as the prefix, for
  target `os` (the trailer's tag: 0 linux, 1 macos, 2 windows).

  Returns `%{ok?: true, out:, offset:, len:, sha:, errors: []}`, or
  `%{ok?: false, errors: [reason]}` when the release carries no native object
  for that target — the same refusal `drop pack` makes, for the same reason.
  """
  @spec pack(binary, binary, binary, integer) :: map
  def pack(release, launcher, out, os \\ 0), do: call("pack", [release, launcher, out, os])

  defp call(name, args) do
    BeamLisp.Loader.ensure_loaded(@ns)
    BeamLisp.RT.invoke(BeamLisp.Env.fetch!(@ns, name), args)
  end
end
