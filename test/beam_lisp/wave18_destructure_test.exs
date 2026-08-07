defmodule BeamLisp.Wave18DestructureTest do
  use ExUnit.Case, async: false

  alias BeamLisp.Vector

  setup do
    BeamLisp.init()
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  describe "sequential :as destructuring" do
    test ":as binds the entire original collection in let" do
      assert eval("(let [[a :as whole] [1 2]] (= whole [1 2]))") == true
      assert eval("(let [[a b :as whole] [1 2 3]] (count whole))") == 3
    end

    test ":as binds the whole collection, not the remainder" do
      # a gets the first element; whole is the full vector, not [2].
      assert eval("(let [[a :as whole] [1 2]] whole)") == %Vector{items: {1, 2}}
      assert eval("(let [[a b :as whole] [1 2 3]] whole)") == %Vector{items: {1, 2, 3}}
    end

    test ":as combines with & rest" do
      assert eval("(let [[a & more :as all] [1 2 3]] (and (= all [1 2 3]) (= more (list 2 3))))") ==
               true
    end

    test ":as still binds the whole when & rest is exhausted to nil" do
      assert eval("(let [[a & rest :as all] [1]] (and (= all [1]) (nil? rest)))") == true
    end

    test ":as keeps a list a list" do
      assert eval("(let [[a :as all] '(1 2)] (and (= a 1) (= all '(1 2)) (list? all)))") == true
    end

    test ":as binds a lazy seq without realizing it" do
      # Binding `:as` alone forces nothing: the counter stays 0 until
      # `first` actually walks the seq (which forces one cell → 1).
      assert eval("""
             (let [n (atom 0)
                   s (lazy-seq (swap! n inc) (list 1 2 3))
                   [:as all] s]
               [@n (first all) @n])
             """) == %Vector{items: {0, 1, 1}}
    end

    test "nested :as binds inner and outer wholes" do
      assert eval(
               "(let [[[a :as inner] :as outer] [[1] 2]] (and (= inner [1]) (= outer [[1] 2])))"
             ) == true
    end

    test ":as in fn params" do
      assert eval("((fn [[a :as whole]] [a (count whole)]) [1 2 3])") ==
               %Vector{items: {1, 3}}

      assert eval("((fn [[a & more :as all]] [a (count all) (first more)]) [9 8 7])") ==
               %Vector{items: {9, 3, 8}}
    end

    test ":as in defn params" do
      assert eval("(defn f [[a :as whole]] [a (count whole)]) (f [1 2 3])") ==
               %Vector{items: {1, 3}}
    end

    test ":as in loop bindings, rebinding each iteration" do
      # `[x :as xs]` destructures a list (and a nil rest) across re-curs;
      # the recursion only terminates when x is nil, so :as must not
      # interfere with the exhausted-rest nil semantics.
      assert eval("""
             (loop [[x :as xs] (list 1 2 3)]
               (if (nil? x)
                 (str "done with " (count xs))
                 (recur (rest xs))))
             """) == "done with 0"
    end

    test ":as with a name is required — a missing name raises" do
      assert_raise RuntimeError, ~r/followed by a name/, fn ->
        eval("(let [[a :as] [1]] a)")
      end
    end

    test ":as in a non-final position raises" do
      assert_raise RuntimeError, ~r/last two elements/, fn ->
        eval("(let [[a :as x b] [1 2]] a)")
      end
    end

    test "lenient behavior is not regressed: too few elements binds nil" do
      assert eval("(let [[a b c] [1]] (and (= a 1) (nil? b) (nil? c)))") == true
      assert eval("(let [[a b :as all] [1]] (and (= a 1) (nil? b) (= all [1])))") == true
    end
  end
end
