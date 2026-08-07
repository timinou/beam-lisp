defmodule BeamLisp.Wave14ReaderTest do
  # Gap #2 from docs/jank-compat.md: `#()` fn literals with `%` args,
  # plus the `#_` discard and char literals that the same reader-level
  # gap list names. The desugaring happens entirely in the reader, which
  # is how Clojure does it (a reader macro), so the compiler never sees
  # `#` — it only ever gets the `(fn [params] body)` form.
  # NOT async: the evaluation tests below compile forms, which rebuilds
  # the shared namespace modules — concurrent Module.create on the same
  # module fails outright, so this file must run alone.
  use ExUnit.Case, async: false

  alias BeamLisp.Reader
  alias BeamLisp.Reader.SyntaxError

  # The sharpest read-form check: `#(...)` must desugar to exactly the
  # hand-written `(fn [params] body)` — this pins both the generated
  # parameter names and the body rewrite at once.
  defp reads_as(short, long) do
    assert Reader.read_one(short) == Reader.read_one(long)
  end

  describe "#() fn literals — read form" do
    test "% is the first positional" do
      reads_as("#(+ % 1)", "(fn [p1__] (+ p1__ 1))")
      reads_as("#(inc %)", "(fn [p1__] (inc p1__))")
    end

    test "%1 %2 … are positional, arity is the highest used" do
      reads_as("#(+ %1 %2)", "(fn [p1__ p2__] (+ p1__ p2__))")
      reads_as("#(vector %2 %1)", "(fn [p1__ p2__] (vector p2__ p1__))")
    end

    test "%& is the rest arg" do
      reads_as("#(apply + %&)", "(fn [& rest__] (apply + rest__))")
    end

    test "no % gives a zero-arg fn" do
      reads_as("#(do)", "(fn [] (do))")
      reads_as("#(println :hi)", "(fn [] (println :hi))")
    end

    test "nested #() is an error, not silent misbehaviour" do
      assert_raise SyntaxError, ~r/nested/, fn -> Reader.read_one("#(#(+ % 1) 2)") end
    end

    test "% inside a nested plain (fn …) still belongs to the literal" do
      reads_as("#(fn [x] (+ x %))", "(fn [p1__] (fn [x] (+ x p1__)))")
    end

    test "replacement reaches inside vectors and maps" do
      reads_as("#(vector [% %])", "(fn [p1__] (vector [p1__ p1__]))")
      reads_as("#(assoc {% 1} % 2)", "(fn [p1__] (assoc {p1__ 1} p1__ 2))")
    end

    test "a symbol merely starting with % is left alone (not an arg)" do
      # `%foo` is not `%`/`%N`/`%&`, so it stays a literal symbol and is
      # not counted toward arity — this fn takes zero args.
      reads_as("#(+ %foo 1)", "(fn [] (+ %foo 1))")
    end
  end

  describe "#() fn literals — evaluation" do
    setup do
      BeamLisp.init()
      %{env: BeamLisp.Compiler.new_env("core")}
    end

    test "map with %", %{env: env} do
      assert BeamLisp.Compiler.eval_string("(map #(* % 2) [1 2 3])", env) == [2, 4, 6]
    end

    test "filter with %", %{env: env} do
      assert BeamLisp.Compiler.eval_string("(filter #(> % 2) [1 2 3 4])", env) == [3, 4]
    end

    test "%1 %2 through reduce", %{env: env} do
      assert BeamLisp.Compiler.eval_string("(reduce #(+ %1 %2) 0 [1 2 3 4])", env) == 10
    end

    test "%& collects the rest args", %{env: env} do
      assert BeamLisp.Compiler.eval_string("(#(apply + %&) 1 2 3)", env) == 6
    end

    test "positional call", %{env: env} do
      assert BeamLisp.Compiler.eval_string("(#(+ %1 %2) 10 20)", env) == 30
    end

    test "% inside a nested plain fn evaluates correctly", %{env: env} do
      # `(fn [x] (+ x p1__))` — the literal's arg reaches the inner fn.
      assert BeamLisp.Compiler.eval_string("((#(fn [x] (+ x %)) 10) 5)", env) == 15
    end
  end

  describe "char literals — integer codepoints (BEAM's native char)" do
    test "named and escaped chars" do
      assert Reader.read_one("\\a") == 97
      assert Reader.read_one("\\newline") == 10
      assert Reader.read_one("\\space") == 32
      assert Reader.read_one("\\tab") == 9
      assert Reader.read_one("\\return") == 13
      assert Reader.read_one("\\\\") == 92
    end

    test "unicode \\uNNNN" do
      assert Reader.read_one("\\u0041") == 65
      assert Reader.read_one("\\u00e9") == 233
    end

    test "invalid char literals raise" do
      assert_raise SyntaxError, ~r/invalid character/, fn -> Reader.read_one("\\ab") end
      assert_raise SyntaxError, ~r/invalid character/, fn -> Reader.read_one("\\u12") end
      assert_raise SyntaxError, ~r/invalid character/, fn -> Reader.read_one("\\") end
    end
  end

  describe "#_ discard" do
    test "skips the next form" do
      assert Reader.read_one("(+ 1 #_2 3)") == Reader.read_one("(+ 1 3)")
      assert Reader.read_one("[1 #_2 3]") == Reader.read_one("[1 3]")
      assert Reader.read_all("(def x #_ignored 5)") == Reader.read_all("(def x 5)")
    end

    test "a trailing #_ with nothing to discard is an error" do
      assert_raise SyntaxError, fn -> Reader.read_one("(+ 1 #_)") end
    end
  end
end
