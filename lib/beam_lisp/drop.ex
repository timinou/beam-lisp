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

  defp call(name, args) do
    BeamLisp.Loader.ensure_loaded(@ns)
    BeamLisp.RT.invoke(BeamLisp.Env.fetch!(@ns, name), args)
  end
end
