defmodule BeamLisp.DecimalCodecTest do
  @moduledoc """
  The order-preserving index key for `:db.type/decimal` (PLAN-115 B1).

  The contract, from the AVET index's point of view: the BYTE order of a
  decimal's key equals its NUMERIC order, across decimals AND against the ints
  and floats that share the number tag — and two decimals of equal numeric
  value (`1.0M`, `1.00M`) produce the SAME key, as Datomic/datahike AVET does.

  These assert that contract directly on `BeamLisp.Decimal.codec_key_parts/1`
  reassembled into the full `TAG-NUM || F(q) || rel || suffix` key the codec
  emits, so a regression in the delicate side/exact math fails here, loudly,
  rather than as a silently wrong range scan deep in a query.
  """
  use ExUnit.Case, async: true
  import Bitwise
  alias BeamLisp.Decimal, as: D

  # Rebuild the exact key codec.bl produces for a decimal: the shared TAG-NUM
  # float prefix (same IEEE transform as codec.bl encode-float) + rel + suffix.
  defp dec_key(%D{} = d) do
    {q, rel, suffix} = D.codec_key_parts(d)
    <<bits::64>> = <<q::float>>
    u = if q >= 0.0, do: bor(bits, 0x8000000000000000), else: bxor(bits, 0xFFFFFFFFFFFFFFFF)
    <<48>> <> <<u::64>> <> <<rel>> <> suffix
  end

  # The key codec.bl produces for a plain integer/float ≤ 2^53: TAG-NUM || F(v) || 1.
  defp num_key(v) when is_number(v) do
    f = v * 1.0
    <<bits::64>> = <<f::float>>
    u = if f >= 0.0, do: bor(bits, 0x8000000000000000), else: bxor(bits, 0xFFFFFFFFFFFFFFFF)
    <<48>> <> <<u::64>> <> <<1>>
  end

  test "byte order of decimal keys equals numeric order" do
    decs =
      ~w(-1000.5 -3.20 -3.2 -0.01 0 0.01 1.0 1.00 1.5 2 2.0 3.14159 99.99 100.05 100.50 1000000.01)
      |> Enum.map(&D.parse!/1)

    by_key = Enum.sort_by(decs, &dec_key/1, fn a,b -> a <= b end) |> Enum.map(&D.to_plain_string/1)
    by_num = Enum.sort(decs, &(D.compare(&1, &2) <= 0)) |> Enum.map(&D.to_plain_string/1)

    assert by_key == by_num
  end

  test "scale variants of one value produce one key (AVET collision, like Datomic)" do
    assert dec_key(D.parse!("1.0")) == dec_key(D.parse!("1.00"))
    assert dec_key(D.parse!("1.0")) == dec_key(D.parse!("1.000000"))
    assert dec_key(D.parse!("-3.2")) == dec_key(D.parse!("-3.20"))
    assert dec_key(D.parse!("0")) == dec_key(D.parse!("0.00"))
  end

  test "an integral decimal collides with the equal integer's key" do
    # 2M and 2 are the same number; AVET indexes by value, so same key.
    assert dec_key(D.parse!("2")) == num_key(2)
    assert dec_key(D.parse!("-5")) == num_key(-5)
    assert dec_key(D.parse!("0")) == num_key(0)
  end

  test "decimals interleave with ints and floats by magnitude" do
    # a mixed column: the decimal 1.5M must sort between int 1 and int 2,
    # and 3.14159M just above float 3.14.
    keyed = [
      {num_key(1), "1"},
      {dec_key(D.parse!("1.5")), "1.5M"},
      {num_key(2), "2"},
      {num_key(3.14), "3.14"},
      {dec_key(D.parse!("3.14159")), "3.14159M"},
      {num_key(4), "4"}
    ]

    order = keyed |> Enum.sort_by(&elem(&1, 0), fn a,b -> a <= b end) |> Enum.map(&elem(&1, 1))
    assert order == ["1", "1.5M", "2", "3.14", "3.14159M", "4"]
  end

  test "distinct decimals that share a float prefix still order by true value" do
    # Two decimals whose to_float collapses to the same double must be separated
    # by the exact suffix. Construct a pair 2^53-scale apart.
    # 9007199254740993 rounds to 9007199254740992.0; 9007199254740991 also rounds
    # near it. Use two values that share one double: ...993 and ...992 both → ...992.0.
    a = D.of(9_007_199_254_740_992, 0)
    b = D.of(9_007_199_254_740_993, 0)
    assert D.to_float(a) == D.to_float(b), "precondition: same rounded float"
    assert dec_key(a) < dec_key(b), "exact suffix must break the float tie by true value"
  end
end
