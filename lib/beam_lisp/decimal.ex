defmodule BeamLisp.Decimal do
  @moduledoc """
  An exact decimal: an unbounded integer `unscaled` and a non-negative integer
  `scale`, denoting `unscaled × 10⁻ˢᶜᵃˡᵉ`. `1.50M` is `{150, 2}`; `1.5M` is
  `{15, 1}`. The two are NUMERICALLY equal and NOT `=`-equal — exactly
  `java.math.BigDecimal`, and exactly what an accounting kernel wants: the
  scale IS information (cents vs. tenths), so it is never silently dropped.

  Why this shape and not the hex `Decimal` library that is already in `deps/`:
  that library carries a process-global `Decimal.Context` (precision + rounding
  mode) that every operation consults. A result then depends on ambient state
  set somewhere else — the exact wart a port from the JVM must not inherit.
  Here every operation that can round takes its scale and rounding mode as
  arguments, and everything else is exact.

  Reads as a literal (`123.45M`), prints back as one, and is a plain struct —
  so it is AOT-literal-safe, `=`-comparable by value, and dispatches through
  `BeamLisp.Multi.type_of/1` as its own type for protocols.

  Rounding modes are keywords, the same seven Clojure code spells as
  `RoundingMode/…` (the interop manifest maps the static to the keyword at
  compile time): `:"half-even" :"half-up" :"half-down" :ceiling :floor :down :up`,
  plus `:unnecessary` which raises when rounding would lose information.
  """

  defstruct unscaled: 0, scale: 0

  @type t :: %__MODULE__{unscaled: integer, scale: non_neg_integer}

  @modes [:"half-even", :"half-up", :"half-down", :ceiling, :floor, :down, :up, :unnecessary]

  defguard is_decimal(x) when is_struct(x, __MODULE__)

  # ── construction ─────────────────────────────────────────────────────

  @doc """
  A decimal from an integer (scale 0), a string (`"123.45"`, `"-1e3"`,
  `"1.5E-2"`), or a decimal (identity). A FLOAT IS REFUSED: a binary float is
  not the number a programmer wrote (`0.1` is not one tenth), so coercing it
  silently would launder that error into "exact" arithmetic. Convert a float
  deliberately with `from_float/1` when approximation is what you mean.
  """
  def new(%__MODULE__{} = d), do: d
  def new(i) when is_integer(i), do: %__MODULE__{unscaled: i, scale: 0}
  def new(s) when is_binary(s), do: parse!(s)

  def new(f) when is_float(f) do
    raise BeamLisp.ExInfo,
      message: "a float is not an exact decimal: #{inspect(f)} (use decimal/from-float to approximate on purpose)",
      data: %{type: :"decimal/inexact-operand", value: f}
  end

  def new(x) do
    raise BeamLisp.ExInfo,
      message: "cannot make a decimal from #{BeamLisp.RT.print_str(x)}",
      data: %{type: :"decimal/coerce", value: x}
  end

  @doc "A decimal from an unscaled integer and a scale — the raw constructor."
  def of(unscaled, scale) when is_integer(unscaled) and is_integer(scale) and scale >= 0,
    do: %__MODULE__{unscaled: unscaled, scale: scale}

  @doc "A decimal from a float via its shortest round-tripping decimal expansion."
  def from_float(f) when is_float(f), do: parse!(Float.to_string(f))

  @doc "Parse `\"[+-]digits[.digits][e[+-]digits]\"`; `{:ok, d}` or `:error`."
  def parse(s) when is_binary(s) do
    # `Regex.run` omits TRAILING unmatched groups, so pad to the four captures.
    case Regex.run(~r/\A\s*([+-])?(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?\s*\z/, s) do
      [_ | caps] ->
        [sign, int, frac, exp] = caps ++ List.duplicate("", 4 - length(caps))

        if int == "" and frac == "" do
          :error
        else
          exp = if exp == "", do: 0, else: String.to_integer(exp)
          digits = String.to_integer(int <> frac)
          digits = if sign == "-", do: -digits, else: digits
          {:ok, normalize_exponent(digits, byte_size(frac) - exp)}
        end

      nil ->
        :error
    end
  end

  def parse!(s) do
    case parse(s) do
      {:ok, d} ->
        d

      :error ->
        raise BeamLisp.ExInfo,
          message: "not a decimal: #{inspect(s)}",
          data: %{type: :"decimal/parse", value: s}
    end
  end

  # A negative scale (from an exponent) is folded into the unscaled value:
  # `1e3` is `{1000, 0}` — the scale never goes below zero here.
  defp normalize_exponent(digits, scale) when scale >= 0, do: of(digits, scale)
  defp normalize_exponent(digits, scale), do: of(digits * pow10(-scale), 0)

  def zero, do: of(0, 0)
  def one, do: of(1, 0)
  def ten, do: of(10, 0)

  # ── exact arithmetic ─────────────────────────────────────────────────

  def add(a, b) do
    {ua, ub, s} = align(a, b)
    of(ua + ub, s)
  end

  def sub(a, b) do
    {ua, ub, s} = align(a, b)
    of(ua - ub, s)
  end

  @doc "Exact product: the scale is the SUM of the operands' scales."
  def mul(%__MODULE__{} = a, %__MODULE__{} = b),
    do: of(a.unscaled * b.unscaled, a.scale + b.scale)

  def neg(%__MODULE__{} = d), do: %{d | unscaled: -d.unscaled}
  def abs(%__MODULE__{} = d), do: %{d | unscaled: Kernel.abs(d.unscaled)}

  @doc "-1, 0 or 1 — the sign, scale-insensitive."
  def signum(%__MODULE__{unscaled: u}) when u > 0, do: 1
  def signum(%__MODULE__{unscaled: u}) when u < 0, do: -1
  def signum(%__MODULE__{}), do: 0

  # ── rounding ─────────────────────────────────────────────────────────

  @doc """
  Divide `a` by `b` to exactly `scale` fractional digits using `mode` — the
  one division that rounds, `BigDecimal.divide(b, scale, mode)`. Division by
  zero raises `:decimal/divide-by-zero`.
  """
  def div(%__MODULE__{} = a, %__MODULE__{} = b, scale, mode)
      when is_integer(scale) and scale >= 0 and mode in @modes do
    if b.unscaled == 0 do
      raise BeamLisp.ExInfo,
        message: "decimal division by zero",
        data: %{type: :"decimal/divide-by-zero", dividend: a}
    end

    # a/b at `scale` digits = (ua · 10^(scale + sb − sa)) / ub, rounded.
    shift = scale + b.scale - a.scale

    {num, den} =
      if shift >= 0,
        do: {a.unscaled * pow10(shift), b.unscaled},
        else: {a.unscaled, b.unscaled * pow10(-shift)}

    of(round_div(num, den, mode), scale)
  end

  @doc """
  Exact division, `BigDecimal.divide(b)`: the quotient must terminate, else
  `:decimal/non-terminating` — the JVM's `ArithmeticException`. The result
  carries the smallest scale that represents it exactly (at least `sa − sb`).
  """
  def div(%__MODULE__{} = a, %__MODULE__{} = b) do
    if b.unscaled == 0 do
      raise BeamLisp.ExInfo,
        message: "decimal division by zero",
        data: %{type: :"decimal/divide-by-zero", dividend: a}
    end

    # ua/ub terminates iff, after cancelling the gcd, the denominator has no
    # prime factor besides 2 and 5; the digits needed is max(#2s, #5s). So the
    # exact scale is decidable up front — no searching, no guessed bound.
    g = Integer.gcd(a.unscaled, b.unscaled)
    den = Kernel.abs(Kernel.div(b.unscaled, g))
    {twos, den} = strip_factor(den, 2, 0)
    {fives, den} = strip_factor(den, 5, 0)

    if den != 1 do
      raise BeamLisp.ExInfo,
        message: "non-terminating decimal expansion; no exact representable decimal result",
        data: %{type: :"decimal/non-terminating", dividend: a, divisor: b}
    end

    # exact at (sa − sb) + max(twos, fives) fractional digits; never below the
    # preferred scale sa − sb (clamped at 0 — the scale is never negative here).
    preferred = a.scale - b.scale
    div(a, b, max(preferred + max(twos, fives), 0), :unnecessary)
  end

  @doc "`BigDecimal.setScale(scale, mode)`: the same number at another scale."
  def rescale(%__MODULE__{} = d, scale, mode) when is_integer(scale) and scale >= 0 and mode in @modes do
    cond do
      scale == d.scale -> d
      scale > d.scale -> of(d.unscaled * pow10(scale - d.scale), scale)
      true -> of(round_div(d.unscaled, pow10(d.scale - scale), mode), scale)
    end
  end

  def rescale(%__MODULE__{} = d, scale) when is_integer(scale), do: rescale(d, scale, :unnecessary)

  @doc "`stripTrailingZeros`: the smallest scale representing the same number."
  def strip_zeros(%__MODULE__{unscaled: 0}), do: zero()

  def strip_zeros(%__MODULE__{} = d) do
    if d.scale > 0 and rem(d.unscaled, 10) == 0,
      do: strip_zeros(of(Kernel.div(d.unscaled, 10), d.scale - 1)),
      else: d
  end

  @doc "`movePointLeft(n)`: divide by 10ⁿ exactly (the scale grows by n)."
  def move_point_left(%__MODULE__{} = d, n) when is_integer(n) and n >= 0, do: of(d.unscaled, d.scale + n)
  def move_point_left(d, n) when is_integer(n), do: move_point_right(d, -n)

  def move_point_right(%__MODULE__{} = d, n) when is_integer(n) and n >= 0 do
    if n <= d.scale,
      do: of(d.unscaled, d.scale - n),
      else: of(d.unscaled * pow10(n - d.scale), 0)
  end

  def move_point_right(d, n) when is_integer(n), do: move_point_left(d, -n)

  # Integer division of num by den under a rounding mode. Written once over
  # `div`/`rem` so every mode is one table, not seven near-copies.
  defp round_div(num, den, mode) do
    q = Kernel.div(num, den)
    r = Kernel.rem(num, den)

    if r == 0 do
      q
    else
      negative? = (num < 0) != (den < 0)
      # twice the remainder against the divisor decides the half cases
      half = Kernel.abs(r) * 2
      cmp = Kernel.abs(den)

      away = if negative?, do: q - 1, else: q + 1
      toward_zero = q

      case mode do
        :unnecessary ->
          raise BeamLisp.ExInfo,
            message: "rounding necessary",
            data: %{type: :"decimal/rounding-necessary"}

        :down -> toward_zero
        :up -> away
        :floor -> if negative?, do: away, else: toward_zero
        :ceiling -> if negative?, do: toward_zero, else: away
        :"half-up" -> if half >= cmp, do: away, else: toward_zero
        :"half-down" -> if half > cmp, do: away, else: toward_zero
        :"half-even" ->
          cond do
            half > cmp -> away
            half < cmp -> toward_zero
            rem(q, 2) == 0 -> toward_zero
            true -> away
          end
      end
    end
  end

  # ── comparison ───────────────────────────────────────────────────────

  @doc "Numeric comparison (scale-insensitive): -1, 0, 1. Accepts an integer on either side."
  def compare(a, b) do
    {ua, ub, _} = align(new(a), new(b))

    cond do
      ua < ub -> -1
      ua > ub -> 1
      true -> 0
    end
  end

  @doc "Numerically equal? `1.0M == 1.00M`, unlike `=`."
  def eq?(a, b), do: compare(a, b) == 0

  # ── conversion ───────────────────────────────────────────────────────

  def scale(%__MODULE__{scale: s}), do: s
  def unscaled(%__MODULE__{unscaled: u}), do: u

  @doc "Number of significant digits (`precision()`); 1 for zero."
  def precision(%__MODULE__{unscaled: 0}), do: 1
  def precision(%__MODULE__{unscaled: u}), do: u |> Kernel.abs() |> Integer.digits() |> length()

  @doc "`longValue`/`intValue`: the integer part, truncated toward zero."
  def to_integer(%__MODULE__{} = d), do: rescale(d, 0, :down).unscaled

  @doc "`doubleValue`: the nearest float — lossy by definition."
  def to_float(%__MODULE__{} = d) do
    {f, ""} = Float.parse(to_plain_string(d))
    f
  end

  @doc "`toPlainString`: no exponent ever, exactly `scale` fractional digits."
  def to_plain_string(%__MODULE__{unscaled: u, scale: 0}), do: Integer.to_string(u)

  def to_plain_string(%__MODULE__{unscaled: u, scale: s}) do
    digits = u |> Kernel.abs() |> Integer.to_string() |> String.pad_leading(s + 1, "0")
    {int, frac} = String.split_at(digits, -s)
    if(u < 0, do: "-", else: "") <> int <> "." <> frac
  end

  @doc "The reader literal form: `to_plain_string` with the `M` suffix."
  def to_literal(%__MODULE__{} = d), do: to_plain_string(d) <> "M"

  # ── helpers ──────────────────────────────────────────────────────────

  # Both unscaled values at the larger scale.
  defp align(%__MODULE__{} = a, %__MODULE__{} = b) do
    s = max(a.scale, b.scale)
    {a.unscaled * pow10(s - a.scale), b.unscaled * pow10(s - b.scale), s}
  end

  defp strip_factor(n, p, k) when rem(n, p) == 0, do: strip_factor(Kernel.div(n, p), p, k + 1)
  defp strip_factor(n, _p, k), do: {k, n}

  defp pow10(0), do: 1
  defp pow10(n) when n > 0, do: Integer.pow(10, n)

  @doc false
  def modes, do: @modes

  defimpl Inspect do
    def inspect(d, _opts), do: BeamLisp.Decimal.to_literal(d)
  end
end
