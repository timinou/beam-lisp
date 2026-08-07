defmodule BeamLisp.Wave14SeqTest do
  # Wave 14: the recursive-seq machinery core.jank leans on — `next`
  # (nil-vs-empty), `list*`, variadic `apply`, and the predicate/utility
  # prims from docs/jank-compat.md's ranked gap list. Each is verified
  # Clojure-correct (not approximately), then the jank slices they unlock
  # (some, not-any?, comp, partial, trampoline) are loaded verbatim and
  # called to prove the load-and-behave count rises.
  use ExUnit.Case, async: false

  alias BeamLisp.Vector

  setup do
    BeamLisp.init()
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  # --- jank slice loading, mirroring the compat harness ---

  defp fixture_code(fixture) do
    Path.join(["test", "fixtures", "jank", fixture])
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, ";"))
    |> Enum.join("\n")
  end

  defp load_slice(fixture, ns) do
    source = "(ns #{ns})\n" <> fixture_code(fixture)
    BeamLisp.Compiler.eval_string(source, BeamLisp.Compiler.new_env(ns))
  end

  defp eval_in(ns, source) do
    BeamLisp.Compiler.eval_string(source, BeamLisp.Compiler.new_env(ns))
  end

  describe "next — nil-vs-empty is the contract" do
    test "nil when the remainder is empty, the tail seq otherwise" do
      assert eval("(next nil)") == nil
      assert eval("(next '())") == nil
      assert eval("(next [])") == nil
      assert eval("(next '(1))") == nil
      assert eval("(next [1])") == nil
      assert eval("(next '(1 2))") == [2]
      assert eval("(next '(1 2 3))") == [2, 3]
      assert eval("(next [1 2 3])") == [2, 3]
    end

    test "drives the (if (next xs) …) idiom core.jank's recursion uses" do
      assert eval("(if (next '(1)) :more :done)") == :done
      assert eval("(if (next '(1 2)) :more :done)") == :more
      assert eval("(if (next [1 2 3]) :more :done)") == :more
    end

    test "over a LazySeq it forces the head and one tail cell" do
      # Clojure's `next` is `(seq (rest x))`: it must realize the tail
      # to answer nil-vs-empty, so it forces two cells where `rest`
      # forces one. That cost is exactly why Clojure keeps both, and
      # returning an unrealized tail instead would make an exhausted
      # seq truthy — which silently broke every `(when (next s) …)`
      # recursion in jank's core.
      counting = fn op ->
        eval("(let [n (atom 0)
                      s (map (fn [x] (swap! n inc) x) (range))]
                  (#{op} s) @n)")
      end

      assert counting.("rest") == 1
      assert counting.("next") == 2

      assert eval("(next (range 3))") == [1, 2]
      assert eval("(next (range 1))") == nil
      # next of an infinite lazy seq is non-nil (a LazySeq tail), not a force.
      assert eval("(if (next (range)) :more :done)") == :more
    end
  end

  describe "list* — variadic cons onto the final collection" do
    test "prepends leading args onto the last (treated as a sequence)" do
      assert eval("(list* 1 2 [3 4])") == [1, 2, 3, 4]
      assert eval("(list* 1 2 '(3 4))") == [1, 2, 3, 4]
      assert eval("(list* 1 [])") == [1]
      assert eval("(list* 1 2 [])") == [1, 2]
      assert eval("(list* '(3 4))") == [3, 4]
      assert eval("(list*)") == nil
    end
  end

  describe "variadic apply — leading args prepend the final seq" do
    test "2-arity keeps working (lists and vectors)" do
      assert eval("(apply + [1 2 3])") == 6
      assert eval("(apply + '(1 2 3))") == 6
      assert eval("(apply (fn [& xs] xs) [1 2])") == [1, 2]
    end

    test "extra leading args are prepended before the seq" do
      assert eval("(apply + 1 [2 3])") == 6
      assert eval("(apply + 1 2 [3 4])") == 10
      assert eval("(apply + 1 2 3 [4])") == 10
      assert eval("(apply list 1 2 [3 4])") == [1, 2, 3, 4]
      assert eval("(apply (fn [a b c] (list a b c)) 1 2 [3])") == [1, 2, 3]
    end
  end

  describe "reduce 2-arity — folds without an initial accumulator" do
    test "comp's `(reduce comp (list* f g fs))` shape" do
      assert eval("(reduce + [1 2 3 4])") == 10
      assert eval("(reduce * [2 3 4])") == 24
      assert eval("(reduce + [])") == 0
      assert eval("(reduce (fn [a b] (str a b)) [\"a\" \"b\" \"c\"])") == "abc"
    end
  end

  describe "predicate and utility prims (Clojure-correct)" do
    test "fn? / seq? / boolean" do
      assert eval("(fn? (fn [x] x))") == true
      assert eval("(fn? (fn ([x] x) ([x y] y)))") == true
      assert eval("(fn? 5)") == false
      assert eval("(fn? :a)") == false
      assert eval("(seq? '(1 2))") == true
      assert eval("(seq? [])") == false
      assert eval("(seq? nil)") == false
      assert eval("(boolean nil)") == false
      assert eval("(boolean false)") == false
      assert eval("(boolean 0)") == true
      assert eval("(boolean \"\")") == true
    end

    test "find returns the map entry as a [key value] vector, or nil" do
      assert eval("(find {:a 1} :a)") == Vector.new([:a, 1])
      assert eval("(find {:a 1} :b)") == nil
      assert eval("(find nil :a)") == nil
      assert eval("(find {:a 7} :a)") == Vector.new([:a, 7])
    end

    test "contains? checks KEYS for maps and INDICES for vectors — never values" do
      assert eval("(contains? {:a 1} :a)") == true
      assert eval("(contains? {:a 1} 1)") == false
      assert eval("(contains? {:a 1} :b)") == false
      assert eval("(contains? {} :a)") == false
      assert eval("(contains? [10 20 30] 0)") == true
      assert eval("(contains? [10 20 30] 2)") == true
      assert eval("(contains? [10 20 30] 3)") == false
      assert eval("(contains? [10 20 30] 30)") == false
      assert eval("(contains? nil :a)") == false
    end

    test "type predicates" do
      assert eval("(keyword? :a)") == true
      assert eval("(keyword? true)") == false
      assert eval("(keyword? nil)") == false
      assert eval("(keyword? \"a\")") == false
      assert eval("(symbol? 'a)") == true
      assert eval("(symbol? :a)") == false
      assert eval("(string? \"abc\")") == true
      assert eval("(string? :a)") == false
      assert eval("(number? 1)") == true
      assert eval("(number? 1.5)") == true
      assert eval("(int? 1)") == true
      assert eval("(int? 1.5)") == false
      assert eval("(map? {:a 1})") == true
      assert eval("(map? [1])") == false
      assert eval("(vector? [1 2])") == true
      assert eval("(vector? '(1 2))") == false
      assert eval("(list? '(1 2))") == true
      assert eval("(list? [1 2])") == false
      assert eval("(list? nil)") == false
      assert eval("(coll? [1 2])") == true
      assert eval("(coll? '(1 2))") == true
      assert eval("(coll? {:a 1})") == true
      assert eval("(coll? (range 3))") == true
      assert eval("(coll? nil)") == false
      assert eval("(ident? :a)") == true
      assert eval("(ident? 'a)") == true
      assert eval("(ident? 5)") == false
    end
  end

  describe "jank core.jank slices unlocked by this wave" do
    test "some + not-any? (slices 08, 09) — next drives the falsy-first path" do
      # ExUnit does not guarantee definition order here, so both slices
      # are loaded into one shared ns within a single test — `not-any?`
      # calls `some`, exactly as they resolve each other in clojure.core.
      load_slice("slice_08_some.bl", "jank.w14.seq")
      load_slice("slice_09_not_any.bl", "jank.w14.seq")

      assert eval_in("jank.w14.seq", "(some even? [1 2 3])") == true
      assert eval_in("jank.w14.seq", "(some even? [1 3 5])") == nil
      # first selector result is nil (falsy) → recurse via `next` →
      # this is the exact path next unlocks.
      assert eval_in("jank.w14.seq", "(some :a [{:a nil} {:a 7}])") == 7
      assert eval_in("jank.w14.seq", "(some :a [])") == nil

      assert eval_in("jank.w14.seq", "(not-any? even? [1 3 5])") == true
      assert eval_in("jank.w14.seq", "(not-any? even? [1 2 3])") == false
      assert eval_in("jank.w14.seq", "(not-any? odd? [])") == true
    end

    test "comp (slice 04) — 4-arity variadic path needs list* + reduce-2" do
      load_slice("slice_04_comp.bl", "jank.w14.comp")
      assert eval_in("jank.w14.comp", "((comp inc inc) 5)") == 7
      # the ([f g & fs] …) clause: (reduce comp (list* f g fs))
      assert eval_in("jank.w14.comp", "((comp inc inc inc) 0)") == 3
      assert eval_in("jank.w14.comp", "((comp str inc) 3)") == "4"
    end

    test "partial (slice 06) — 4+ fixed args need variadic apply" do
      load_slice("slice_06_partial.bl", "jank.w14.partial")
      assert eval_in("jank.w14.partial", "((partial + 1) 2 3)") == 6
      # 4+ fixed clause: (fn [& args] (apply f arg1 arg2 arg3 (concat more args)))
      assert eval_in("jank.w14.partial", "((partial + 1 2 3 4) 5)") == 15
      assert eval_in("jank.w14.partial", "((partial + 1 2 3) 4 5)") == 15
    end

    test "juxt (slice 05) — variadic clause needs list* + reduce-2 + variadic apply" do
      load_slice("slice_05_juxt.bl", "jank.w14.juxt")
      assert eval_in("jank.w14.juxt", "((juxt inc dec) 5)") == Vector.new([6, 4])
      # the ([f g h & fs] …) clause: reduce conj over (list* f g h fs)
      assert eval_in("jank.w14.juxt", "((juxt inc inc inc dec) 5)") ==
               Vector.new([6, 6, 6, 4])
    end

    test "trampoline (slice 19) — fn? on the returned value ends the loop" do
      load_slice("slice_19_trampoline.bl", "jank.w14.tramp")
      # 1-arity: `(if (fn? ret) (recur ret) ret)` — fn? is the dispatch prim
      assert eval_in("jank.w14.tramp", "(trampoline (fn [] 42))") == 42
      assert eval_in(
               "jank.w14.tramp",
               "(defn e? [n] (if (zero? n) true (fn [] (o? (dec n)))))
                (defn o? [n] (if (zero? n) false (fn [] (e? (dec n)))))
                (trampoline (fn [] (e? 10000)))"
             ) == true
    end
  end
end
