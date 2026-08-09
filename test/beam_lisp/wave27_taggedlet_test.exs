defmodule BeamLisp.Wave27TaggedLetTest do
  # Wave 27: `^Tag` metadata on binding targets is a no-op.
  #
  # The Specter re-measurement landed on `(let [^com.rpl.specter.RichNavigator g v] ...)`
  # failing with "unsupported binding pattern" — a compile-time error. In Clojure a
  # type hint on a binding is an *optimization hint*: semantically inert, and
  # ignoring it is completely faithful. Wave 25 taught the reader to parse `^Tag`,
  # `^:kw` and `^{:map …}` in all three shorthands; this file pins the compiler's
  # side — every binding position accepts a tagged symbol and binds the bare name,
  # with the metadata never leaking into the runtime value.
  #
  # Binding positions covered: `let`/`let*`, `loop`, `fn`/`defn` params, `for`
  # (which routes through `let`), and — by deliberate decision — tagged symbols
  # INSIDE a destructuring pattern (`[^long a b]`, `{:keys [^long a]}`), because
  # the leading peel clause recurses over nested patterns and Clojure likewise
  # ignores the hint there.
  #
  # Wave-20 source-position contract: these are separate from
  # wave20_reader_pos_test.exs, which must stay green untouched.
  # NOT async: these drive the compiler, which rebuilds the shared
  # BeamLisp.Ns.* modules and writes the global var table.
  use ExUnit.Case, async: false

  alias BeamLisp.Compiler

  defp eval(src) do
    BeamLisp.init()
    Compiler.eval_string("(ns w27t)\n" <> src, Compiler.new_env("w27t"))
  end

  # beam-lisp vectors/lazy-seqs are their own structs; normalize to an
  # Elixir list so the assertions below read plainly.
  defp to_list(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp to_list(%BeamLisp.LazySeq{} = s), do: Enum.to_list(s)
  defp to_list(l) when is_list(l), do: l

  test "let: tagged symbol binds the bare name" do
    assert eval("(let [^Tag x 5] x)") == 5
  end

  test "let: keyword metadata is equally a no-op" do
    assert eval("(let [^:private y 1] y)") == 1
  end

  test "let: stacked metadata collapses to the bare binding" do
    assert eval("(let [^:foo ^Tag z 2] z)") == 2
  end

  test "let: metadata never leaks into the runtime value" do
    # The value bound is 5 itself, not a meta-wrapped 5.
    assert eval("(let [^Tag x 5] x)") == 5
    assert eval("(let [^Tag m {:a 1}] (get m :a))") == 1
    assert eval("(let [^Tag v [1 2]] (count v))") == 2
  end

  test "let*: tagged binding works" do
    assert eval("(let* [^Tag a 3 ^Tag b 4] (+ a b))") == 7
  end

  test "fn: tagged param binds the bare name" do
    assert eval("((fn [^long x] x) 5)") == 5
  end

  test "defn: tagged param binds the bare name" do
    assert eval("(defn tagged [^long n] (+ n 1)) (tagged 41)") == 42
  end

  test "loop: tagged binding works and recurs" do
    assert eval("(loop [^Tag i 0] (if (< i 3) (recur (inc i)) i))") == 3
  end

  test "for: tagged binding routes through the let destructurer" do
    assert to_list(eval("(for [^Tag y [1 2]] (* y 10))")) == [10, 20]
  end

  test "tagged symbol inside a vector destructuring pattern is accepted" do
    # Deliberate decision: allow, matching Clojure's no-op hint semantics.
    assert to_list(eval("(let [[^long a b] [1 2]] [a b])")) == [1, 2]
  end

  test "tagged symbol inside a :keys destructuring pattern is accepted" do
    assert eval("(let [{:keys [^long k]} {:k 7}] k)") == 7
  end

  test "tagged :as name in a map pattern binds the whole collection" do
    assert to_list(eval("(let [{:keys [a] :as ^Tag m} {:a 9}] [a m])")) == [9, %{a: 9}]
  end

  test "tagged :as name in a vector pattern binds the whole collection" do
    assert to_list(eval("(let [[a b :as ^Tag w] [1 2]] w)")) == [1, 2]
  end

  test "tagged :or default key provides the fallback" do
    assert eval("(let [{:keys [d] :or {^long d 5}} {}] d)") == 5
  end

  test "tagged binding composes with a destructured fn param" do
    assert eval("(let [^Tag f (fn [[^long a b]] (+ a b))] (f [1 2]))") == 3
  end

  test "def/defn NAME metadata path is untouched" do
    # Wave-25 owns ^:private/^{:doc} on names; assert it still compiles
    # and the tagged name still defines a working var.
    assert eval("(defn ^:private tagged2 [x] (* x x)) (tagged2 6)") == 36
  end
end
