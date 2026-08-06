defmodule BeamLisp.CompilerTest do
  use ExUnit.Case, async: false

  setup do
    BeamLisp.RT.seed_core()
    :ok
  end

  defp eval(source), do: BeamLisp.Compiler.eval_string(source)

  test "literals evaluate to themselves" do
    assert eval("42") == 42
    assert eval("2.5") == 2.5
    assert eval("\"hi\"") == "hi"
    assert eval("nil") == nil
    assert eval("true") == true
    assert eval(":kw") == :kw
  end

  test "collections" do
    assert eval("[1 2 3]") == [1, 2, 3]
    assert eval("[(+ 1 1) (+ 2 2)]") == [2, 4]
    assert eval("{:a 1}") == %{a: 1}
  end

  test "def and var lookup" do
    assert eval("(def meaning 42) meaning") == 42
  end

  test "arithmetic through seeded core vars" do
    assert eval("(+ 1 2)") == 3
    assert eval("(* (+ 1 2) 3)") == 9
    assert eval("(< 1 2)") == true
  end

  test "fn values are real Elixir fns" do
    f = eval("(fn [x] (* x x))")
    assert is_function(f, 1)
    assert f.(7) == 49
    assert eval("((fn [x] (+ x 1)) 10)") == 11
  end

  test "fn closes over locals" do
    add1 = eval("((fn [x] (fn [y] (+ x y))) 1)")
    assert add1.(2) == 3
  end

  test "defn defines and calls" do
    assert eval("(defn double [x] (+ x x)) (double 21)") == 42
  end

  test "defn with docstring" do
    assert eval("(defn d \"docs\" [x] x) (d 5)") == 5
  end

  test "multi-arity defn dispatches on argument count" do
    assert eval("(defn f ([x] (* x 10)) ([x y] (+ x y))) (f 5)") == 50
    assert eval("(defn g ([x] (* x 10)) ([x y] (+ x y))) (g 3 4)") == 7
  end

  test "recursion through the var" do
    assert eval("(defn sum [xs] (if (empty? xs) 0 (+ (first xs) (sum (rest xs))))) (sum [1 2 3 4])") == 10
  end

  test "let binds sequentially" do
    assert eval("(let [a 1 b (+ a 2) c (+ b 3)] (+ a (+ b c)))") == 10
    assert eval("(let [x 1] (let [x (+ x 1)] x))") == 2
  end

  test "if treats nil and false as falsey, everything else truthy" do
    assert eval("(if nil 1 2)") == 2
    assert eval("(if false 1 2)") == 2
    assert eval("(if 0 1 2)") == 1
    assert eval("(if true 1)") == 1
    assert eval("(if false 1)") == nil
  end

  test "do returns the last form" do
    assert eval("(do 1 2 3)") == 3
  end

  test "quote yields data" do
    assert eval("(quote (a b c))") == [{:symbol, "a"}, {:symbol, "b"}, {:symbol, "c"}]
    assert eval("'(1 :two \"three\")") == [1, :two, "three"]
    assert eval("'foo") == {:symbol, "foo"}
  end

  test "keywords are functions of maps" do
    assert eval("(:a {:a 1 :b 2})") == 1
    assert eval("(:missing {})") == nil
    assert eval("(:missing {} :fallback)") == :fallback
  end

  test "elixir interop: uppercase prefix is an Elixir module" do
    assert eval("(String/upcase \"beam\")") == "BEAM"
    assert eval("(Enum/sum [1 2 3])") == 6
    assert eval("(String/length \"four\")") == 4
  end

  test "erlang interop: lowercase prefix is an Erlang module" do
    assert eval("(lists/reverse [1 2 3])") == [3, 2, 1]
    assert eval("(lists/seq 1 3)") == [1, 2, 3]
  end

  test "remote functions are first-class values" do
    handle = eval("String/upcase")
    assert BeamLisp.RT.invoke(handle, ["beam"]) == "BEAM"
    assert BeamLisp.RT.print_str(handle) == "#fn[Elixir.String/upcase]"
  end

  test "undefined vars raise" do
    assert_raise RuntimeError, ~r/undefined var/, fn -> eval("(missing 1)") end
  end

  test "functions pass through apply" do
    assert eval("(apply (fn [x y] (+ x y)) [3 4])") == 7
  end
end
