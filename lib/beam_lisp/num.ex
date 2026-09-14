defmodule BeamLisp.Num do
  @moduledoc """
  The numeric tower's seam: every core arithmetic and ordering primitive
  routes its 2-arity through here. Integer/float pairs take the BIF on the
  first clause — the guard is what the BEAM compiles to a type test, so the
  hot path stays a hot path — and anything else is promoted:

    * `BeamLisp.Decimal` with an integer → the integer becomes a decimal
      (scale 0); exact.
    * `BeamLisp.Decimal` with a float → REFUSED (`:decimal/inexact-operand`).
      A binary float is not the number that was written, so mixing it into
      exact arithmetic would launder that error. Convert deliberately with
      `decimal/from-float`.
    * anything else → the ordinary `ArithmeticError`, as before.

  Equality is the one place the tower and the value model part ways, on
  purpose: `=` stays structural (`1.0M` ≠ `1.00M`, exactly like Java
  `equals`) while `==` and the ordering ops are numeric (`1.0M == 1.00M`).
  """

  alias BeamLisp.Decimal

  # ── arithmetic ───────────────────────────────────────────────────────

  def add(a, b) when is_number(a) and is_number(b), do: a + b
  def add(a, b), do: Decimal.add(promote(a, b), promote(b, a))

  def sub(a, b) when is_number(a) and is_number(b), do: a - b
  def sub(a, b), do: Decimal.sub(promote(a, b), promote(b, a))

  def mul(a, b) when is_number(a) and is_number(b), do: a * b
  def mul(a, b), do: Decimal.mul(promote(a, b), promote(b, a))

  @doc """
  `/` on two decimals is EXACT division (`:decimal/non-terminating` when it
  is not), never a float: `(/ 1M 3M)` refusing is the right answer for money,
  and `(decimal/div a b scale mode)` is the spelling for a rounded quotient.
  """
  def div(a, b) when is_number(a) and is_number(b), do: a / b
  def div(a, b), do: Decimal.div(promote(a, b), promote(b, a))

  def neg(a) when is_number(a), do: -a
  def neg(%Decimal{} = d), do: Decimal.neg(d)

  # ── ordering ─────────────────────────────────────────────────────────

  def lt(a, b) when is_number(a) and is_number(b), do: a < b
  def lt(a, b), do: cmp(a, b) < 0
  def gt(a, b) when is_number(a) and is_number(b), do: a > b
  def gt(a, b), do: cmp(a, b) > 0
  def le(a, b) when is_number(a) and is_number(b), do: a <= b
  def le(a, b), do: cmp(a, b) <= 0
  def ge(a, b) when is_number(a) and is_number(b), do: a >= b
  def ge(a, b), do: cmp(a, b) >= 0

  @doc "Numeric equality: `(== 1 1.0)` and `(== 1.0M 1.00M)` are true."
  def num_eq(a, b) when is_number(a) and is_number(b), do: a == b
  def num_eq(a, b), do: cmp(a, b) == 0

  @doc "Three-way numeric comparison for the tower's members."
  def cmp(a, b) when is_number(a) and is_number(b) do
    cond do
      a < b -> -1
      a > b -> 1
      true -> 0
    end
  end

  def cmp(a, b), do: Decimal.compare(promote(a, b), promote(b, a))

  # Total, and for a non-number exactly the Erlang term comparison it was
  # before — so the `:when (pos? x)` guard (compiler.bl guard-special, which
  # cannot call into the tower) and the function form keep agreeing.
  def zero?(x) when is_number(x), do: x == 0
  def zero?(%Decimal{} = d), do: Decimal.signum(d) == 0
  def zero?(x), do: :erlang.==(x, 0)
  def pos?(x) when is_number(x), do: x > 0
  def pos?(%Decimal{} = d), do: Decimal.signum(d) > 0
  def pos?(x), do: :erlang.>(x, 0)
  def neg?(x) when is_number(x), do: x < 0
  def neg?(%Decimal{} = d), do: Decimal.signum(d) < 0
  def neg?(x), do: :erlang.<(x, 0)

  @doc "A member of the numeric tower, of any representation."
  def number?(x) when is_number(x), do: true
  def number?(%Decimal{}), do: true
  def number?(_), do: false

  # ── promotion ────────────────────────────────────────────────────────

  # `promote(x, other)`: x as the representation the pair computes in. An
  # integer beside a decimal lifts; a float beside a decimal is refused; two
  # non-decimals fall through to the BIF's own ArithmeticError so the error
  # text a plain `(+ 1 :a)` raises is unchanged.
  defp promote(%Decimal{} = d, _other), do: d
  defp promote(i, %Decimal{}) when is_integer(i), do: Decimal.new(i)

  defp promote(f, %Decimal{}) when is_float(f) do
    raise BeamLisp.ExInfo,
      message:
        "a float cannot enter decimal arithmetic: #{inspect(f)} (use decimal/from-float to approximate on purpose)",
      data: %{type: :"decimal/inexact-operand", value: f}
  end

  # Let the BIF raise its own ArithmeticError — the message and, above all,
  # the STACK are then the ones every caller and location test already expect
  # (`:erlang.+/2` on top, the user's frame right under it).
  defp promote(x, other), do: :erlang.error(:badarith, [x, other])
end
