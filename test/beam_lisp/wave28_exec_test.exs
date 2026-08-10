defmodule BeamLisp.Wave28ExecTest do
  # The execution layer and the navigators built on it.
  #
  # Three properties carry most of the weight here, and each has a
  # history behind it:
  #
  #   Early termination must actually terminate. Proved by COUNTING
  #   realizations, never by timing — wave 27's rule, learned when a
  #   rebinding of `map` looked fast and was not lazy.
  #
  #   transform must rebuild faithfully. beam-lisp keeps [] and ()
  #   structurally distinct, so a vector coming back a list is a silent
  #   type change, not a cosmetic one.
  #
  #   Map results assert CONTRACTS — roundtrip, agreement with seq —
  #   never a literal iteration order. Erlang term order is not
  #   Clojure's, and a test asserting a literal order is asserting the
  #   VM's implementation.
  use ExUnit.Case, async: false

  setup do
    BeamLisp.init()
    :ok
  end

  defp sp(body) do
    BeamLisp.Compiler.eval_string(
      "(ns w28x.#{:erlang.unique_integer([:positive])} " <>
        "(:require [specter.navs :refer :all] " <>
        "[specter.engine :refer :all] " <>
        "[specter.exec :refer :all]))\n" <> body,
      BeamLisp.Compiler.new_env("user")
    )
  end

  defp v(list), do: BeamLisp.Vector.new(list)

  describe "select" do
    test "navigates a key, a sequence, and a composition of both" do
      assert sp("(select [:a] {:a 1})") == v([1])
      assert sp("(select [ALL] [1 2 3])") == v([1, 2, 3])
      assert sp("(select [ALL :a] [{:a 1} {:a 2}])") == v([1, 2])
      assert sp("(select [:a :b] {:a {:b 7}})") == v([7])
    end

    test "an empty path selects the structure itself" do
      # Navigating nowhere is still navigating.
      assert sp("(select [] 42)") == v([42])
    end

    test "selecting nothing yields an empty vector, not NONE and not an error" do
      # The sentinel is engine-internal; it must never reach a caller who
      # never agreed to know about it.
      assert sp("(select [ALL] [])") == v([])
      assert sp("(select [ALL (pred* odd?)] [2 4])") == v([])
    end

    test "a missing key navigates to nil rather than failing" do
      # keypath's contract: usable against data that has not got there
      # yet. `must` is the navigator for the other intent.
      assert sp("(select [:missing] {:a 1})") == v([nil])
      assert sp("(select [(must* :missing)] {:a 1})") == v([])
      assert sp("(select [(must* :a)] {:a 1})") == v([1])
    end

    test "filters compose after ALL" do
      assert sp("(select [ALL (pred* odd?)] [1 2 3 4 5])") == v([1, 3, 5])
    end

    test "a bare function in a path is a filter" do
      # The implicit-nav coercion: a path may be written in shorthand.
      assert sp("(select [ALL odd?] [1 2 3 4 5])") == v([1, 3, 5])
    end
  end

  describe "select-any and early termination" do
    test "returns the first navigated value" do
      assert sp("(select-any [ALL] [7 8 9])") == 7
    end

    test "stops at the first hit instead of walking the rest" do
      # THE property. Counted, not timed: a navigator that records each
      # element it sees proves how far the traversal actually got.
      assert sp("""
             (let [seen (volatile! 0)
                   count-nav (reify RichNavigator
                               (select* [this vals s nf] (vswap! seen inc) (nf vals s))
                               (transform* [this vals s nf] (nf vals s)))]
               (select-any [ALL count-nav] [1 2 3 4 5 6 7 8 9 10])
               @seen)
             """) == 1
    end

    test "terminates on a lazy sequence it could never finish" do
      # An infinite structure is the honest test of short-circuiting: if
      # the traversal did not stop, this test would not either.
      assert sp("(select-any [ALL] (iterate inc 1))") == 1
    end

    test "realizes only what it needs from a lazy sequence" do
      # Counting realized cells, per the standing rule. `range` of a
      # million with a counting map over it: a non-short-circuiting
      # select would realize all of them.
      assert sp("""
             (let [realized (volatile! 0)
                   xs (map (fn [x] (vswap! realized inc) x) (range 1000000))]
               (select-any [ALL] xs)
               (< @realized 100))
             """) == true
    end

    test "select-first answers nil where nothing was selected" do
      # nil, not the sentinel: the boundary where NONE stops being the
      # caller's problem.
      assert sp("(select-first [ALL] [])") == nil
      assert sp("(select-first [ALL] [5 6])") == 5
      assert sp("(selected-any? [ALL] [])") == false
      assert sp("(selected-any? [ALL] [1])") == true
    end
  end

  describe "transform rebuilds faithfully" do
    test "changes navigated values and nothing else" do
      assert sp("(transform [:a] inc {:a 1 :b 99})") == %{a: 2, b: 99}
      assert sp("(transform [ALL] inc [1 2 3])") == v([2, 3, 4])
    end

    test "preserves vector-ness — [] and () are not the same type here" do
      # A vector coming back a list is a silent type change on this host.
      assert sp("(vector? (transform [ALL] inc [1 2 3]))") == true
      assert sp("(vector? (transform [ALL] inc (list 1 2 3)))") == false
    end

    test "leaves non-matching elements untouched under a filter" do
      # The filter's transform must return the structure unchanged rather
      # than dropping it — otherwise transform becomes filter.
      assert sp("(transform [ALL (pred* odd?)] inc [1 2 3 4])") == v([2, 2, 4, 4])
    end

    test "transforms map values without disturbing the rest" do
      assert sp("(transform [:a :b] inc {:a {:b 1 :c 2} :d 3})") ==
               %{a: %{b: 2, c: 2}, d: 3}
    end

    test "setval replaces without consulting the old value" do
      assert sp("(setval [:a] 9 {:a 1})") == %{a: 9}
      assert sp("(setval [ALL] 0 [1 2 3])") == v([0, 0, 0])
    end

    test "setting a key to NONE removes it" do
      # Upstream's contract, and the reason the engine must recognise its
      # own sentinel coming back out of a user's transform.
      assert sp("(setval [:a] NONE {:a 1 :b 2})") == %{b: 2}
      assert sp("(setval [(must* :a)] NONE {:a 1 :b 2})") == %{b: 2}
    end

    test "a map transform round-trips through select" do
      # A CONTRACT, not a literal order: Erlang term order is not
      # Clojure's, so what is asserted is that the two agree with each
      # other.
      assert sp("""
             (let [m {:a 1 :b 2 :c 3}
                   t (transform [ALL] (fn [kv] [(first kv) (inc (second kv))]) m)]
               [(= (set (keys t)) (set (keys m)))
                (= (set (vals t)) (set [2 3 4]))
                (map? t)])
             """) == v([true, true, true])
    end
  end

  describe "srange" do
    test "transforms a subrange and splices it back" do
      assert sp("(transform [(srange* 1 3)] reverse [1 2 3 4])") == v([1, 3, 2, 4])
    end

    test "preserves vector-ness through the splice" do
      assert sp("(vector? (transform [(srange* 0 1)] reverse [1 2 3]))") == true
    end

    test "selects the subrange as one value" do
      assert sp("(select [(srange* 1 3)] [1 2 3 4])") == v([v([2, 3])])
    end

    test "works on a string" do
      # A string subrange is spliced with str rather than concat — the
      # branch that exists because a string is not a sequence of
      # characters on this host.
      assert sp(~s{(transform [(srange* 0 2)] (fn [s] (string/uppercase s)) "hello")}) ==
               "HEllo"
    end
  end

  describe "doseqres — the NONE-aware reduction" do
    # Two surfaces, deliberately. `doseqres` is a MACRO binding a name
    # over a body, because that is how vendored Specter code writes it
    # (`(doseqres NONE [e structure] (next-fn e))`) and the fixture is
    # not adapted to us. `doseqres-fn` is the same reduction for callers
    # who already hold a function. Both are tested, because a macro that
    # disagrees with the function under it is a trap.

    test "a NONE result leaves the accumulator alone" do
      # Otherwise a branch that selected nothing would clobber a sibling
      # that selected something.
      assert sp("(doseqres NONE [x [1 2 3]] (if (odd? x) x NONE))") == 3
      assert sp("(doseqres-fn NONE [1 2 3] (fn [x] (if (odd? x) x NONE)))") == 3
    end

    test "an all-NONE reduction stays NONE" do
      assert sp("(none? (doseqres NONE [x [2 4]] NONE))") == true
      assert sp("(none? (doseqres-fn NONE [2 4] (fn [x] NONE)))") == true
    end

    test "a reduced result terminates and propagates" do
      assert sp("""
             (let [seen (volatile! 0)]
               (doseqres NONE [x [1 2 3 4 5]]
                 (vswap! seen inc)
                 (if (= x 2) (reduced x) NONE))
               @seen)
             """) == 2
    end

    test "the macro binds its name hygienically" do
      # The binding must not capture a caller's `x`, and the body must
      # see the element rather than the surrounding scope's value.
      assert sp("(let [x :outer] (doseqres NONE [x [1 2 3]] (if (= x 3) x NONE)))") == 3
    end
  end

  describe "the sentinel never leaks to a caller" do
    test "no public entry point returns NONE" do
      # The invariant that makes NONE safe: it is engine-internal. select
      # yields [], select-first yields nil, selected-any? yields false.
      assert sp("""
             [(select [ALL] [])
              (select-first [ALL] [])
              (selected-any? [ALL] [])]
             """) == v([v([]), nil, false])
    end

    test "user data equal in shape to a sentinel survives a roundtrip" do
      # The hazard every sentinel carries. A map whose value IS the
      # engine's NONE keyword must come back out as data.
      assert sp("(select [:k] {:k :specter.engine/NONE})") ==
               v([:"specter.engine/NONE"])
    end
  end
end
