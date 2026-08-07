defmodule BeamLisp.Wave23LazySeqTest do
  use ExUnit.Case, async: false

  alias BeamLisp.Vector

  setup do
    BeamLisp.init()
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  describe "lazy-seq thunk may return a bare LazySeq (wave 23)" do
    test "minimal repro: nested lazy-seq returning another seq via concat" do
      assert eval(
               "(reduce conj [] (concat (lazy-seq (concat (lazy-seq (list 1)) (list 2))) (list 3)))"
             ) == Vector.new([1, 2, 3])
    end

    test "a thunk returning a bare lazy seq at several nesting depths" do
      assert eval("(reduce conj [] (lazy-seq (lazy-seq (lazy-seq (lazy-seq (list 1 2 3))))))") ==
               Vector.new([1, 2, 3])

      assert eval("(first (lazy-seq (lazy-seq (list 42))))") == 42

      assert eval("(reduce conj [] (concat (lazy-seq []) (lazy-seq (list 7))))") ==
               Vector.new([7])
    end

    test "take over an infinite lazy seq realizes only what it needs" do
      assert eval("(take 5 (concat (lazy-seq (map inc (range))) (list 99)))") ==
               [1, 2, 3, 4, 5]

      # The counter proves only 5 cells of the infinite seq were forced:
      # concat's thunk peels the outer lazy-seq and map realizes exactly
      # the cells `take` consumes, never the tail.
      assert eval(
               "(let [n (atom 0)
                      inf (map (fn [x] (swap! n inc) x) (range))]
                  (doall (take 5 (concat (lazy-seq inf) (list 99))))
                  @n)"
             ) == 5
    end

    test "thunks returning [], a vector, a set, and nil all normalize" do
      assert eval("(reduce conj [] (lazy-seq []))") == Vector.new([])

      assert eval("(reduce conj [] (concat (lazy-seq [1 2]) (lazy-seq [3])))") ==
               Vector.new([1, 2, 3])

      # A set's member order is unspecified — check membership, not order.
      # The # in a set literal must be split from the { to avoid Elixir's
      # #{ interpolation inside the source string.
      set_result = eval("(reduce conj [] (lazy-seq #" <> "{1 2}))")
      assert set_result |> Vector.to_list() |> Enum.sort() == [1, 2]

      assert eval("(reduce conj [] (concat (lazy-seq nil) (list 5)))") == Vector.new([5])
    end

    test "concat combines lazy and strict inputs in both orders" do
      assert eval("(reduce conj [] (concat (list 1) (lazy-seq (list 2))))") ==
               Vector.new([1, 2])

      assert eval("(reduce conj [] (concat (lazy-seq (list 1)) (list 2)))") ==
               Vector.new([1, 2])
    end
  end
end
