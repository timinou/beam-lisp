defmodule BeamLisp.Wave10LazyTest do
  use ExUnit.Case, async: false

  alias BeamLisp.Vector

  setup do
    BeamLisp.init()
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  describe "prelude gaps (wave 10)" do
    test "get works at both arities" do
      assert eval("(get {:a 1} :a)") == 1
      assert eval("(get {:a 1} :missing)") == nil
      assert eval("(get {:a 1} :missing :dflt)") == :dflt
      assert eval("(get {:a 1} :a :dflt)") == 1
    end

    test "assoc is polymorphic over maps and vectors, and variadic" do
      assert eval("(assoc {:a 1} :b 2)") == %{a: 1, b: 2}
      assert eval("(assoc {} :a 1 :b 2)") == %{a: 1, b: 2}
      assert eval("(assoc {:a 1} :a 9)") == %{a: 9}
      assert eval("(assoc nil :a 1)") == %{a: 1}
      assert eval("(assoc [10 20 30] 1 99)") == Vector.new([10, 99, 30])
    end

    test "numeric/collection predicates are one-liners in core" do
      assert eval("(even? 4)") == true
      assert eval("(even? 3)") == false
      assert eval("(odd? 3)") == true
      assert eval("(zero? 0)") == true
      assert eval("(pos? 3)") == true
      assert eval("(pos? 0)") == false
      assert eval("(neg? -2)") == true
    end

    test "take and drop are Clojure-ordered (n first)" do
      assert eval("(take 3 (list 1 2 3 4 5))") == [1, 2, 3]
      assert eval("(drop 2 (list 1 2 3 4))") == [3, 4]
      assert eval("(drop 0 (list 1 2))") == [1, 2]
      assert eval("(drop 5 (list 1 2))") == []
    end
  end

  describe "lazy sequences" do
    test "infinite range + take realize only what they need" do
      assert eval("(take 5 (map inc (range)))") == [1, 2, 3, 4, 5]
      # map over an infinite range must not realize the whole thing
      assert eval("(count (take 10 (range)))") == 10
    end

    test "a chunk's thunk realizes once, caching its whole chunk" do
      # map is chunked at 32: the first force realizes one chunk (32
      # elements) and caches it, so re-forcing the same cells re-runs
      # nothing. The counter is 32 (one chunk), not 1 (one element) —
      # chunking trades a little over-realization for ~14× less per-element
      # allocation, exactly Clojure's tradeoff.
      assert eval(
               "(let [n (atom 0)
                      s (map (fn [x] (swap! n inc) x) (range))]
                  (first s) (first s) (first s) (rest s) @n)"
             ) == 32
    end

    test "lazy-seq macro memoizes its body the same way" do
      assert eval(
               "(let [n (atom 0)
                      s (lazy-seq (swap! n inc) (list 1 2 3))]
                  (first s) (first s) (first s) @n)"
             ) == 1
    end

    test "forcing a finite prefix of an infinite seq realizes exactly one chunk" do
      # `take 5` forces one 32-element chunk (map is chunked), so the thunk
      # runs 32 times — not all of an infinite range, and not just 5 either:
      # the chunk boundary is the granularity of realization.
      assert eval(
               "(let [n (atom 0)
                      s (map (fn [x] (swap! n inc) x) (range))]
                  (doall (take 5 s))
                  @n)"
             ) == 32
    end

    test "iterate / take-while / drop-while / cycle are lazy and compose" do
      assert eval("(take 5 (iterate (fn [x] (* x 2)) 1))") == [1, 2, 4, 8, 16]
      assert eval("(doall (take-while (fn [x] (< x 5)) (range)))") == [0, 1, 2, 3, 4]
      assert eval("(take 3 (drop-while (fn [x] (< x 5)) (range)))") == [5, 6, 7]
      assert eval("(take 4 (cycle (list 1 2 3)))") == [1, 2, 3, 1]
      assert eval("(take 4 (concat (list 1 2) (range)))") == [1, 2, 0, 1]
      assert eval("(first (filter even? (iterate inc 1)))") == 2
    end

    test "repeat is infinite and lazy; repeat n is a realized list" do
      assert eval("(take 4 (repeat :x))") == [:x, :x, :x, :x]
      assert eval("(repeat 3 :x)") == [:x, :x, :x]
      assert eval("(repeat 0 :x)") == []
    end

    test "lazy seqs are Enumerable for Elixir interop" do
      assert eval("(Enum/take (map inc (range)) 5)") == [1, 2, 3, 4, 5]
      assert eval("(Enum/to_list (take 4 (cycle (list 1 2))))") == [1, 2, 1, 2]
      assert eval("(Enum/sum (take 5 (range)))") == 10
      assert eval("(Enum/map (take 3 (range)) (fn [x] (* x x)))") == [0, 1, 4]
    end

    test "printing an infinite seq is bounded, not a hang" do
      pr = eval("(pr-str (map inc (range)))")
      assert is_binary(pr)
      assert String.starts_with?(pr, "(1 2 3")
      assert String.ends_with?(pr, "…)")
    end

    test "100k doall does not blow the stack" do
      assert eval("(count (doall (take 100000 (map inc (range)))))") == 100_000
    end

    test "seq/empty?/first/rest/nth dispatch on lazy seqs" do
      assert eval("(nil? (seq (map inc (range))))") == false
      assert eval("(nil? (seq (take 0 (range))))") == true
      assert eval("(empty? (map inc (range)))") == false
      assert eval("(empty? (take 0 (range)))") == true
      assert eval("(first (map inc (range)))") == 1
      assert eval("(nth (map inc (range)) 4)") == 5
      assert eval("(count (take 5 (map inc (range))))") == 5
      assert eval("(= (take 4 (cycle (list 1 2))) (list 1 2 1 2))") == true
    end
  end
end
