defmodule BeamLisp.GenerationSemanticsTest do
  use ExUnit.Case, async: false

  alias BeamLisp.Compiler

  defp eval(source) do
    ns = "generation.semantic.#{System.unique_integer([:positive])}"
    Compiler.eval_string("(ns #{ns})\n" <> source, Compiler.new_env(ns))
  end

  describe "call position preserves callability-based local/global dispatch" do
    test "callable local of matching arity wins over linked global" do
      assert eval("(defn pick [x] [:global x]) (let [pick (fn [x] [:local x])] (pick 1))") ==
               BeamLisp.Vector.new([:local, 1])
    end

    test "non-callable local and wrong-arity local fall back to linked global" do
      assert eval("(defn pick [x] [:global x]) (let [pick 7] (pick 1))") ==
               BeamLisp.Vector.new([:global, 1])

      assert eval("(defn pick [x] [:global x]) (let [pick (fn [x y] [:local x y])] (pick 1))") ==
               BeamLisp.Vector.new([:global, 1])
    end

    test "missing global calls fail, including an uncallable local with no fallback" do
      assert_raise RuntimeError, ~r/undefined var/, fn -> eval("(missing-generation-global 1)") end

      assert_raise BadArityError, fn ->
        eval("(let [only-local (fn [x y] (+ x y))] (only-local 1))")
      end
    end
  end

  test "fixed and variadic clauses dispatch by argument count" do
    assert eval("(defn collect ([x] [:fixed x]) ([x & xs] [:variadic x xs])) [(collect 1) (collect 1 2 3)]") ==
             BeamLisp.Vector.new([
               BeamLisp.Vector.new([:fixed, 1]),
               BeamLisp.Vector.new([:variadic, 1, [2, 3]])
             ])
  end

  test "guards run legal predicates and reject calls outside the guard vocabulary" do
    assert eval("(defn classify ([x] :when (int? x) :integer) ([_] :other)) [(classify 1) (classify :x)]") ==
             BeamLisp.Vector.new([:integer, :other])

    error =
      assert_raise BeamLisp.CompileError, fn ->
        eval("(defn classify ([x] :when (println x) :bad) ([_] :other))")
      end

    assert error.message =~ "not allowed in a guard"
  end

  test "typed and untyped catches, reraising, and finally effects are observable" do
    assert eval("(try (throw :x) (catch e (ex-message e)))") == ":x"
    assert eval("(try (throw :x) (catch BeamLisp.ExInfo e :typed))") == :typed

    Process.delete(:"generation-finally")
    assert_raise BeamLisp.ExInfo, fn ->
      eval("(try (throw :again) (catch e (throw e)) (finally (erlang/put :generation-finally true)))")
    end
    assert Process.get(:"generation-finally") == true
  end

  test "macro bodies expand in source order" do
    assert eval("(def counter (atom 0)) (defmacro tick [] (swap! counter inc)) (defn f ([_] (tick)) ([_ _] (tick))) [(f 1) (f 1 2)]") ==
             BeamLisp.Vector.new([1, 2])
  end

  test "declare after def preserves the value" do
    assert eval("(def already 42) (declare already) already") == 42
  end

  test "a retained closure survives three global redefinitions" do
    assert eval("(defn current [] (fn [] 1)) (def retained (current)) (defn current [] (fn [] 2)) (defn current [] (fn [] 3)) (defn current [] (fn [] 4)) [(retained) ((current))]") ==
             BeamLisp.Vector.new([1, 4])
  end
end
