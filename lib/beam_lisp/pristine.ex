defmodule BeamLisp.Pristine do
  @moduledoc """
  The PRISTINE comparison, delegated to the language: `priv/build/pristine.bl`.

  The fixpoint gate (PLAN-108 W6) is only as strong as the comparison behind it,
  and the comparison has one measured trap: two packs of ONE tree produce
  different compounds, because flate2 and Erlang's `:zlib` are different
  compressors. So this module compares in layers, and `same?` means every layer
  agreed:

    1. `trees/2` — every file's path → (size, sha256), compared as SETS (an
       extra or missing path is reported as such, not smoothed over), plus the
       tar bytes, byte for byte.
    2. `drops/2` — the trailer's fields, `offset + len + 56 == size`, the stored
       against the recomputed payload digest, and the digest of the payload
       DECOMPRESSED.

  `report/1` renders EVERY difference, never just the first. The file bytes of
  two compounds are reported but deliberately not part of `same?`: two
  compressors can never promise identity there, and a gate that demanded it
  would be demanding something nobody intends to fix.

  Like `BeamLisp.Drop` and `BeamLisp.Release`, this is the Elixir call surface;
  the logic is in `priv/build/pristine.bl`.
  """

  @ns "pristine"

  @doc "`%{rel_path => %{size: n, sha: hex}}` for every file under `root`."
  @spec index(binary) :: map
  def index(root) when is_binary(root), do: call("index", [root])

  @doc """
  Layers 1 and 2 for two release roots: the set difference and the tar bytes.

  Returns `%{"trees" => …, "tar" => …, "same?" => boolean}`. The `trees` map
  carries `removed` / `added` / `changed` as sorted path lists.
  """
  @spec trees(binary, binary) :: map
  def trees(a, b) when is_binary(a) and is_binary(b), do: call("trees", [a, b])

  @doc """
  Layers 3 and 4 for two compounds: trailer fields, arithmetic, payload digest,
  decompressed payload digest — and, separately, whether the files themselves
  are the same length.
  """
  @spec drops(binary, binary) :: map
  def drops(a, b) when is_binary(a) and is_binary(b), do: call("drops", [a, b])

  @doc "Every difference, one line each. `\"identical\"` when there are none."
  @spec report(map) :: binary
  def report(diff) when is_map(diff), do: call("report", [diff])

  @doc """
  Whether two compounds are byte-identical — the fixpoint ONE producer can
  demand of itself (our packer is deterministic). Deliberately separate from
  `drops/2`, whose `same?` has to hold across two different compressors.
  """
  @spec compounds_identical?(binary, binary) :: boolean
  def compounds_identical?(a, b) when is_binary(a) and is_binary(b),
    do: call("compounds-identical?", [a, b])

  defp call(name, args) do
    BeamLisp.Loader.ensure_loaded(@ns)
    BeamLisp.RT.invoke(BeamLisp.Env.fetch!(@ns, name), args)
  end
end
