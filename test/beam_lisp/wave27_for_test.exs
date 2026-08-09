defmodule BeamLisp.Wave27ForTest do
  # wave 27: `for` (the list comprehension) now ships in the prelude,
  # and `vary-meta` is variadic. `for` is the single most-reached-for
  # macro in Clojure and was, before this wave, the prelude's most
  # glaring hole — jank's fidelity slice 44 always PASSED because it
  # vendors upstream's own `for` into its test namespace, measuring
  # that beam-lisp can *host* `for`, never that the language shipped
  # one. This file asserts the prelude `for` behaves: laziness (proven
  # by a realization COUNT, not a stopwatch), nesting, :let/:when/:while
  # modifiers, destructuring, and gensym hygiene. The behavioural edges
  # live in test/bl/prelude_test.bl; here are the Elixir-side shapes.
  import BeamLisp.Test, only: [realize: 1]

  use ExUnit.Case, async: false

  defp eval(source), do: BeamLisp.eval(source)

  test "for comprehends over a vector, lazily" do
    assert realize(eval("(for [x [1 2 3]] (* x 2))")) == [2, 4, 6]
    # empty collection → empty seq, no raise
    assert realize(eval("(for [x []] x)")) == []
    # an all-rejecting :when terminates with an empty seq
    assert realize(eval("(for [x [1 2 3] :when false] x)")) == []
  end

  test "for nests rightmost-fastest and later bindings see earlier ones" do
    assert realize(eval("(for [x [1 2] y (range x)] [x y])")) == [
             BeamLisp.Vector.new([1, 0]),
             BeamLisp.Vector.new([2, 0]),
             BeamLisp.Vector.new([2, 1])
           ]
  end

  test "for supports :let :when and :while modifiers" do
    assert realize(eval("(for [x [1 2 3] :let [y (* x 10)]] [x y])")) == [
             BeamLisp.Vector.new([1, 10]),
             BeamLisp.Vector.new([2, 20]),
             BeamLisp.Vector.new([3, 30])
           ]
    assert realize(eval("(for [x (range 10) :when (even? x)] x)")) == [0, 2, 4, 6, 8]
    # :while must terminate over an INFINITE source
    assert realize(eval("(for [x (range) :while (< x 5)] x)")) == [0, 1, 2, 3, 4]
  end

  test "for destructures the binding form" do
    assert realize(eval("(for [[a b] [[1 2] [3 4]]] (+ a b))")) == [3, 7]
    assert realize(eval("(for [[k v] {:a 1 :b 2}] [k v])")) == [
             BeamLisp.Vector.new([:b, 2]),
             BeamLisp.Vector.new([:a, 1])
           ]
  end

  test "for is lazy: a bounded take realizes a bounded prefix" do
    # The source has a million elements; taking 5 must run the body only
    # ~5 times. A counter proves laziness where a stopwatch proves only
    # speed — the whole point of `for` being lazy.
    assert eval("""
      (let [c (atom 0)
            res (doall (take 5 (for [x (range 1000000)]
                                     (do (swap! c inc) (* x 2)))))]
        (and (= (deref c) 5) (= res '(0 2 4 6 8))))
    """) == true

    # :when over a huge range is lazy the same way
    assert eval("""
      (let [c (atom 0)
            res (doall (take 5 (for [x (range 1000000) :when (even? x)]
                                     (do (swap! c inc) x))))]
        (and (= (deref c) 5) (= res '(0 2 4 6 8))))
    """) == true
  end

  test "for does not capture user bindings named like its temporaries" do
    assert realize(eval("(let [iter 5] (for [x [1]] iter))")) == [5]
    assert realize(eval("(let [s 7] (for [x [1]] s))")) == [7]
    assert realize(eval("(let [x 9] (for [y [1]] x))")) == [9]
  end

  test "vary-meta is variadic: (vary-meta obj f & args) applies (f (meta obj) args)" do
    # 2-arity behaviour is unchanged
    assert eval("(meta (vary-meta [1] (fn [m] {:a 1})))") == %{a: 1}
    # the common variadic spelling Specter uses
    assert eval("(meta (vary-meta [1] assoc :k 1))") == %{k: 1}
    assert eval("(meta (vary-meta [1] assoc :k 1 :j 2))") == %{k: 1, j: 2}
    # nil meta flows through as nil, as Clojure does
    assert eval("(meta (vary-meta [1] (fn [m] (if (nil? m) {:from-nil true} m))))") ==
             %{"from-nil": true}
  end
end
