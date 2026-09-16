defmodule BeamLisp.ConcatLinearityTest do
  # `mapcat` is `(apply concat (apply map f colls))`, so an `f` that yields one
  # element per input hands `concat` n one-element seqs — exactly the shape
  # `datom.tx/expand-tx-fns` realises with `(into [] (mapcat …))`. That shape
  # was QUADRATIC: every chunk re-normalized and re-walked the seqs it had not
  # reached yet, so realising n elements cost O(n^2).
  #
  # Measured on the reference host, `(count (mapcat (fn [x] [x]) (range n)))`:
  #
  #   n        quadratic   linear
  #   1000     ~70 ms      ~40 ms
  #   2000     ~274 ms     ~50 ms
  #   4000     ~1240 ms    ~110 ms
  #   8000     ~4600 ms    ~235 ms
  #
  # The bounds below sit between the two. Between 1000 and 8000 n grows 8x:
  # linear lands near 8x, quadratic near 64x, and the 20x ratio bound has ~2.5x
  # of margin either side. The absolute bound fails the old code by ~4x and
  # passes the new one with ~5x of headroom. Min-of-three keeps a stray GC or
  # scheduler hiccup from deciding the outcome.
  use ExUnit.Case, async: false

  alias BeamLisp.Vector

  setup do
    BeamLisp.init()
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  defp min_ms(source, expected, runs \\ 3) do
    1..runs
    |> Enum.map(fn _ ->
      {us, value} = :timer.tc(fn -> eval(source) end)
      assert value == expected, "expected #{expected} elements, got #{inspect(value)}"
      div(us, 1000)
    end)
    |> Enum.min()
  end

  # Warm the interpreter (parse/compile caches, first-call allocations) so the
  # measurements below are of the algorithm, not of the JIT.
  defp warm_up, do: assert(eval("(count (mapcat (fn [x] [x]) (range 500)))") == 500)

  test "concat over n one-element seqs grows linearly, not quadratically" do
    warm_up()

    t1000 = min_ms("(count (mapcat (fn [x] [x]) (range 1000)))", 1000)
    t8000 = min_ms("(count (mapcat (fn [x] [x]) (range 8000)))", 8000)

    assert t8000 < 1200,
           "mapcat 8000 took #{t8000} ms — the quadratic cost was ~4600 ms"

    # n grows 8x here: linear lands near 8x, quadratic near 64x.
    assert t8000 < 20 * max(t1000, 5),
           "mapcat 1000 -> #{t1000} ms, 8000 -> #{t8000} ms: 8x the elements " <>
             "should not cost anywhere near 64x the time"
  end

  describe "concat semantics" do
    test "elements come out in input order, empties skipped, nil is empty" do
      assert eval("(vec (mapcat (fn [x] [x]) [1 2 3]))") == Vector.new([1, 2, 3])
      assert eval("(vec (concat [1 2] [] [3] nil [4 5]))") == Vector.new([1, 2, 3, 4, 5])
      assert eval("(vec (concat [1] [2] [3]))") == Vector.new([1, 2, 3])

      # same objects, not copies
      assert eval("(let [a (list 1 2) b (list 3 4) r (concat a b)] (= (first r) (first a)))") ==
               true
    end

    test "no args, nil, and [] all give an empty seq (not an error)" do
      assert eval("(empty? (concat))") == true
      assert eval("(empty? (concat nil))") == true
      assert eval("(empty? (concat []))") == true
      assert eval("(= (concat) ())") == true
    end

    test "nested concats flatten one level, as seqs yielding seqs" do
      assert eval("(vec (concat (concat [1 2] [3]) [4]))") == Vector.new([1, 2, 3, 4])
      assert eval("(vec (concat (concat (concat [1] [2]) [3]) [4]))") == Vector.new([1, 2, 3, 4])

      assert eval(
               "(vec (concat (lazy-seq (concat (lazy-seq (list 1)) (list 2))) (list 3)))"
             ) == Vector.new([1, 2, 3])
    end

    test "a chunk never reaches into a later, unforced seq" do
      # The realized `(:a :b)` head is all `take 2` needs; the lazy map tail
      # must not be mapped at all.
      assert eval("""
             (let [n (atom 0)
                   s (concat (list :a :b) (map (fn [x] (swap! n inc) x) (range 1000000)))]
               (take 2 s)
               @n)
             """) == 0
    end

    test "forcing only the head of a concat does not force a throwing tail" do
      assert eval("(first (concat [1 2] (lazy-seq (throw (ex-info \"boom\" {})))))") == 1

      assert eval("(vec (take 1 (concat [1 2] (lazy-seq (throw (ex-info \"boom\" {}))))))") ==
               Vector.new([1])
    end

    test "the lazy tail is still reached once the head is exhausted" do
      assert eval("(vec (take 4 (concat [1 2] (range))))") == Vector.new([1, 2, 0, 1])
    end

    test "a first seq whose length is an exact chunk multiple keeps the rest" do
      # Regression: `concat_chunk` returned an EMPTY chunk when the first seq
      # exhausted exactly at the 32-element chunk boundary, and `chain([], …)`
      # is nil — so every later seq was silently DROPPED. `(concat v32 [:x])`
      # answered `(0 … 31)` with `:x` gone. Exercise each boundary multiple.
      for n <- [31, 32, 33, 63, 64, 65, 96, 128] do
        got = eval("(count (to-list (concat (vec (range #{n})) [:x])))")
        assert got == n + 1, "concat dropped the tail after a #{n}-element head"

        assert eval("(contains? (set (to-list (concat (vec (range #{n})) [:x]))) :x)") ==
                 true
      end
    end

    test "a deep left-nested concat accumulator keeps every element" do
      # The `(reduce (fn [a i] (concat a [i])) [] …)` shape the code indexer's
      # per-file call accumulation uses: it truncated at 32 before the fix.
      assert eval("(count (to-list (reduce (fn [a i] (concat a [i])) [] (range 50))))") == 50
      assert eval("(count (to-list (reduce (fn [a i] (concat a [i])) [] (range 500))))") == 500
    end
  end
end
