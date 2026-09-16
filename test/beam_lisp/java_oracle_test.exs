defmodule BeamLisp.JavaOracleTest do
  @moduledoc """
  The interop manifest against the JVM it stands in for.

  Each row is a Clojure expression using `java.math`/`java.util` interop the
  way an unmodified library writes it — `(.setScale x 2 RoundingMode/HALF_EVEN)`,
  `(BigDecimal. "1.5")`, `(catch NumberFormatException _ …)`, `Long/MAX_VALUE`
  — with the answer CAPTURED FROM THE JVM (`clojure -M` with the same
  `:import`s). beam-lisp compiles the identical text through
  `priv/lib/java/manifest.bl` and must print the same value.

  Compared modulo the top-level string quoting difference of `pr-str` (FUP-032).
  """
  use ExUnit.Case, async: false

  @rows [
    {"(.toPlainString (.add 1.10M 2.20M))", "3.30"},
    {"(.toPlainString (.setScale 2.345M 2 RoundingMode/HALF_EVEN))", "2.34"},
    {"(.toPlainString (.setScale 2.345M 2 RoundingMode/HALF_UP))", "2.35"},
    {"(.toPlainString (.divide 10M 3M 4 RoundingMode/DOWN))", "3.3333"},
    {"(.toPlainString (.multiply (BigDecimal. \"1.5\") (BigDecimal/valueOf 4)))", "6.0"},
    {"(.toPlainString (.negate BigDecimal/ONE))", "-1"},
    {"(.toPlainString (.abs -2.5M))", "2.5"},
    {"(.signum -3M)", "-1"},
    {"(.compareTo 1.0M 1.00M)", "0"},
    {"(.equals 1.0M 1.00M)", "false"},
    {"(.scale 1.230M)", "3"},
    {"(.precision 1.230M)", "4"},
    {"(.longValue 3.99M)", "3"},
    {"(.toPlainString (.stripTrailingZeros 1.500M))", "1.5"},
    {"(.toPlainString (.movePointLeft 15M 2))", "0.15"},
    {"(.toPlainString (.movePointRight 1.5M 3))", "1500"},
    {"(.toUpperCase \"abc\")", "ABC"},
    {"(.startsWith \"hello\" \"he\")", "true"},
    {"(.substring \"hello\" 1 3)", "el"},
    {"(.lastIndexOf \"a.b.c\" \".\")", "3"},
    {"(.toString 1.50M)", "1.50"},
    {"(str (.getTime (Date/from (java.time.Instant/ofEpochMilli 1000))))", "1000"},
    {"(.before (Date/from (java.time.Instant/ofEpochMilli 1)) (Date/from (java.time.Instant/ofEpochMilli 2)))", "true"},
    {"(instance? BigDecimal 1M)", "true"},
    {"(instance? BigDecimal 1)", "false"},
    {"(try (BigDecimal. \"x\") (catch NumberFormatException _ \"NFE\"))", "NFE"},
    {"(try (.divide 1M 3M) (catch ArithmeticException _ \"ARITH\"))", "ARITH"},
    {"(try (throw (ex-info \"b\" {})) (catch Exception _ \"EXC\"))", "EXC"},
    {"(try (throw (ex-info \"b\" {})) (catch Throwable _ \"THR\"))", "THR"},
    {"(str (UUID/fromString \"123E4567-E89B-12D3-A456-426614174000\"))", "123e4567-e89b-12d3-a456-426614174000"},
    {"(let [c (AtomicLong.)] (.incrementAndGet c) (.incrementAndGet c))", "2"},
    {"Long/MAX_VALUE", "9223372036854775807"},
    {"(Math/abs -3)", "3"},
    {"(Character/isDigit \\7)", "true"},
  ]

  setup_all do
    BeamLisp.AOT.boot()
    :ok
  end

  test "java interop through the manifest matches the JVM" do
    BeamLisp.Compiler.eval_string("""
    (ns java.oracle (:import [java.math BigDecimal RoundingMode] [java.util Date UUID]
                             [java.util.concurrent.atomic AtomicLong]))
    """)
    env = BeamLisp.Compiler.new_env("java.oracle")

    failures =
      for {{src, expected}, i} <- Enum.with_index(@rows),
          got = run(src, env),
          got != expected,
          do: "row #{i}: #{src}\n    JVM: #{inspect(expected)}\n    bl:  #{inspect(got)}"

    assert failures == [], "#{length(failures)} of #{length(@rows)} rows diverge:\n\n" <> Enum.join(failures, "\n\n")
  end

  test "an unlisted method, static, class or catch is a compile-time refusal with the list" do
    BeamLisp.Compiler.eval_string("(ns java.oracle2 (:import [java.math BigDecimal RoundingMode]))")
    env = BeamLisp.Compiler.new_env("java.oracle2")

    assert_raise BeamLisp.CompileError, ~r/no Java method \.frobnicate .* known methods: .*\.add/, fn ->
      BeamLisp.Compiler.eval_string("(.frobnicate 1M 2M)", env)
    end

    assert_raise BeamLisp.CompileError, ~r/no static java.math.RoundingMode\/SIDEWAYS .* this class has: .*HALF_EVEN/, fn ->
      BeamLisp.Compiler.eval_string("RoundingMode/SIDEWAYS", env)
    end

    assert_raise BeamLisp.CompileError, ~r/catch java.io.IOException: not in the interop manifest/, fn ->
      BeamLisp.Compiler.eval_string("(try 1 (catch java.io.IOException e 2))", env)
    end

    # a one-arg `.x` that the manifest does not know is still a deftype field read
    assert 42 == BeamLisp.Compiler.eval_string("(do (deftype P [x]) (.x (->P 42)))", env)
  end

  defp run(src, env) do
    v = BeamLisp.Compiler.eval_string(src, env)
    BeamLisp.RT.print_str(v) |> String.trim("\"")
  rescue
    _ -> "ERROR"
  catch
    _, _ -> "ERROR"
  end
end
