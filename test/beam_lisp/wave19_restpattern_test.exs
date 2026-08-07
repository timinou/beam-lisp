defmodule BeamLisp.Wave19RestPatternTest do
  # The last real compiler gap: a rest argument that is itself a
  # destructuring pattern. Clojure lets `&` hold any binding form, not
  # just a bare symbol — jank's `for` relies on exactly this
  # (`& [[_ next-expr] :as next-groups]`). The machinery is the same
  # `destructure_steps/3` that fixed params use; the rest is bound to a
  # temp var and destructured against it.
  #
  # Load-bearing edge: an EXHAUSTED rest binds nil, not `()`. jank code
  # recurses on `(when (seq more) …)`, and `()` is truthy, so binding
  # `[]` would loop forever at the base case instead of terminating.
  # A rest PATTERN therefore destructures nil leniently (every name nil)
  # — never an error, exactly like destructuring a too-short collection.
  use ExUnit.Case, async: false

  @moduletag :wave19

  defp eval(ns, source) do
    BeamLisp.init()
    BeamLisp.Compiler.eval_string(source, BeamLisp.Compiler.new_env(ns))
  end

  test "bare-symbol rest still works and keeps () for empty (wave2 regression)" do
    assert eval("w19bare", "(defn f [& rest] rest) (list (f) (f 1 2))") == [[], [1, 2]]
  end

  test "fixed params before a pattern rest still bind normally" do
    assert eval("w19fixed", "(defn f [a & [b c]] (list a b c)) (list (f 1) (f 1 2) (f 1 2 3) (f 1 2 3 4))") ==
             [[1, nil, nil], [1, 2, nil], [1, 2, 3], [1, 2, 3]]
  end

  test "vector pattern in rest position destructures the trailing args" do
    assert eval("w19vec", "(defn f [& [a b]] (list a b)) (list (f) (f 9) (f 9 8) (f 9 8 7))") ==
             [[nil, nil], [9, nil], [9, 8], [9, 8]]
  end

  test "empty rest binds nil for every name, not ()" do
    assert eval("w19empty", "(defn f [& [a b]] (list a b)) (f)") == [nil, nil]
    assert eval("w19empty2", "(defn f [& [a b]] (list (nil? a) (nil? b))) (f)") == [true, true]
  end

  test "one-shorter-than-pattern rest binds trailing names nil" do
    assert eval("w19short", "(defn f [& [a b c]] (list a b c)) (list (f 1) (f 1 2))") ==
             [[1, nil, nil], [1, 2, nil]]
  end

  test ":as in the rest pattern binds the whole rest" do
    assert eval("w19as", "(defn f [& [a b :as all]] (list a b all)) (list (f 1 2 3) (f) (f 7))") ==
             [[1, 2, [1, 2, 3]], [nil, nil, nil], [7, nil, [7]]]
  end

  test ":as in the rest pattern binds nil when the rest is exhausted" do
    assert eval("w19asnil", "(defn f [& [a :as all]] (list (nil? all) all)) (f)") == [true, nil]
  end

  test "nested vector pattern in rest, two deep" do
    assert eval("w19nested", "(defn f [& [[a b] c]] (list a b c)) (list (f [1 2] 3) (f) (f [1 2]))") ==
             [[1, 2, 3], [nil, nil, nil], [1, 2, nil]]
  end

  test "rest pattern with its own inner & rest (recursion shape)" do
    assert eval("w19inner", "(defn f [& [a b & more]] (list a b more)) (list (f 1 2 3 4) (f 1 2))") ==
             [[1, 2, [3, 4]], [1, 2, nil]]
  end

  test "the jank for emit-bind signature: nested rest with :as, empty base case" do
    # `emit-bind` receives [[bind expr & mod-pairs] & [[_ next-expr] :as next-groups]].
    # With a single group the rest is exhausted: next-expr and next-groups must
    # both bind nil (jank's recursion terminates on exactly this). The non-empty
    # case binds the leading next-group and the whole tail.
    assert eval("w19for", """
    (defn emit-bind [[[bind expr & mod-pairs] & [[_ next-expr] :as next-groups]]]
      (list bind expr mod-pairs next-expr next-groups))
    (list (emit-bind [[1 2 3 4]])
          (emit-bind [[1 2] [5 6] [7 8]]))
    """) ==
             [[1, 2, [3, 4], nil, nil],
              [1, 2, nil, 6, [%BeamLisp.Vector{items: {5, 6}}, %BeamLisp.Vector{items: {7, 8}}]]]
  end

  test "fn and let paths use the same rest-pattern machinery" do
    assert eval("w19fn", "(let [f (fn [& [a b]] (list a b))] (list (f 1 2) (f)))") == [[1, 2], [nil, nil]]
    assert eval("w19let", "(let [[x & [y z]] [1 2 3]] (list x y z))") == [1, 2, 3]
    assert eval("w19let2", "(let [[x & [y z]] [1]] (list x y z))") == [1, nil, nil]
    assert eval("w19let3", "(let [[x & [[a b]]] [1 [2 3]]] (list x a b))") == [1, 2, 3]
  end

  test "a map pattern in rest position raises a clear message, not a mis-bind" do
    # The rest is always a positional seq; a map pattern there would silently
    # bind every key to nil (a seq is not a map), which is a footgun. Refuse.
    assert_raise RuntimeError, ~r/rest pattern cannot be a map/, fn ->
      eval("w19map", "(defn f [& {:keys [x]}] x)")
    end
  end

  test "& must still be followed by exactly one parameter" do
    assert_raise RuntimeError, ~r/followed by exactly one parameter/, fn ->
      eval("w19arity", "(defn f [& a b] a)")
    end
  end
end
