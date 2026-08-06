defmodule BeamLisp.Wave2Test do
  use ExUnit.Case, async: false

  setup do
    BeamLisp.RT.seed_core()
    :ok
  end

  defp eval(source), do: BeamLisp.Compiler.eval_string(source)

  describe "loop/recur" do
    test "loop binds and recurs" do
      assert eval("(loop [i 0 acc 0] (if (< i 5) (recur (+ i 1) (+ acc i)) acc))") == 10
    end

    test "recur in tail position is constant-stack" do
      # 200k iterations of self-application: runs in constant stack
      # under erl_eval's interpreted funs (and native once wave 3
      # compiles to modules).
      assert eval("(loop [i 0] (if (< i 200000) (recur (+ i 1)) i))") == 200_000
    end

    test "recur through nested lets and ifs stays in tail position" do
      assert eval("""
             (loop [i 0]
               (let [done? (>= i 10)]
                 (if done?
                   (let [answer (* i 2)] answer)
                   (recur (+ i 1)))))
             """) == 20
    end

    test "recur outside tail position is a compile error" do
      assert_raise RuntimeError, ~r/tail position/, fn ->
        eval("(loop [i 0] (+ 1 (recur (+ i 1))))")
      end
    end

    test "recur with no target is a compile error" do
      assert_raise RuntimeError, ~r/no enclosing/, fn -> eval("(recur 1)") end
    end

    test "recur arity must match the loop" do
      assert_raise RuntimeError, ~r/arity mismatch/, fn ->
        eval("(loop [i 0] (recur 1 2))")
      end
    end

    test "recur inside an inner fn targets that fn, not the loop" do
      # The fn is the innermost target; its arity (0) mismatches.
      assert_raise RuntimeError, ~r/arity mismatch/, fn ->
        eval("(loop [i 0] ((fn [] (recur 1))))")
      end
    end

    test "recur at top level still has no target" do
      assert_raise RuntimeError, ~r/no enclosing/, fn ->
        eval("(recur 1)")
      end
    end

    test "loop result is a value" do
      assert eval("(+ 1 (loop [i 0] (if (< i 2) (recur (+ i 1)) i)))") == 3
    end
  end

  describe "destructuring" do
    test "sequential in let" do
      assert eval("(let [[a b] [1 2]] (+ a b))") == 3
      assert eval("(let [[a b c] [1 2 3]] (+ a (+ b c)))") == 6
    end

    test "sequential with rest" do
      assert eval("(let [[a & rest] [1 2 3]] rest)") == [2, 3]
      assert eval("(let [[a & rest] [1]] rest)") == []
    end

    test "nested sequential" do
      assert eval("(let [[[a b] c] [[1 2] 3]] (+ a (+ b c)))") == 6
    end

    test "map with :keys" do
      assert eval("(let [{:keys [a b]} {:a 1 :b 2}] (+ a b))") == 3
    end

    test "map with explicit keys" do
      assert eval("(let [{:x x :y y} {:x 1 :y 2}] (+ x y))") == 3
    end

    test "map with :as binds the whole" do
      assert eval("(let [{:keys [a] :as m} {:a 1 :b 2}] (:b m))") == 2
    end

    test "sequential params in defn" do
      assert eval("(defn add-pair [[a b]] (+ a b)) (add-pair [3 4])") == 7
    end

    test "map params in defn with :as" do
      assert eval("(defn greet [{:keys [name] :as person}] (str name)) (greet {:name \"beam\"})") == "beam"
    end
  end

  describe "variadic params" do
    test "rest collects extra args" do
      assert eval("(defn f [a & rest] rest) (f 1 2 3)") == [2, 3]
    end

    test "zero extra args gives an empty rest" do
      assert eval("(defn f [a & rest] rest) (f 1)") == []
    end

    test "all-variadic" do
      assert eval("(defn f [& xs] (count xs)) (f 1 2 3 4)") == 4
    end

    test "fixed and rest are both bound" do
      assert eval("(defn f [a b & rest] (+ a (+ b (count rest)))) (f 1 2 3 4 5)") == 6
    end

    test "too few args raises" do
      assert_raise RuntimeError, ~r/at least 2/, fn ->
        eval("(defn f [a b & rest] a) (f 1)")
      end
    end
  end

  describe "prelude wave-2 fns" do
    setup do
      BeamLisp.init()
      :ok
    end

    test "reduce is loop-based and still correct" do
      assert BeamLisp.eval("(reduce (fn [acc x] (+ acc x)) 0 (range 100))") == 4950
    end

    test "range" do
      assert BeamLisp.eval("(range 5)") == [0, 1, 2, 3, 4]
      assert BeamLisp.eval("(range 2 5)") == [2, 3, 4]
      assert BeamLisp.eval("(range 0)") == []
    end

    test "second" do
      assert BeamLisp.eval("(second [10 20 30])") == 20
    end

    test "list is variadic" do
      assert BeamLisp.eval("(list 1 2 3)") == [1, 2, 3]
      assert BeamLisp.eval("(list)") == []
    end

    test "zipmap" do
      assert BeamLisp.eval("(zipmap [:a :b] [1 2])") == %{a: 1, b: 2}
    end
  end
end
