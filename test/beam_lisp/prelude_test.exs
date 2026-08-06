defmodule BeamLisp.PreludeTest do
  use ExUnit.Case, async: false

  defp eval(source), do: BeamLisp.eval(source)

  test "the prelude defines self-hosted core fns" do
    assert eval("(inc 41)") == 42
    assert eval("(dec 43)") == 42
    assert eval("(identity :self)") == :self
    assert eval("(nil? nil)") == true
    assert eval("(not= 1 2)") == true
    assert eval("(some? 1)") == true
  end

  test "map, filter, reduce are written in beam-lisp" do
    assert eval("(map inc [1 2 3])") == [2, 3, 4]
    assert eval("(map (fn [x] (* x x)) [1 2 3])") == [1, 4, 9]
    assert eval("(filter (fn [x] (> x 2)) [1 2 3 4])") == [3, 4]
    assert eval("(reduce (fn [acc x] (+ acc x)) 0 [1 2 3 4])") == 10
  end

  test "take and every?" do
    assert eval("(take 2 [1 2 3 4])") == [1, 2]
    assert eval("(take 5 [1 2])") == [1, 2]
    assert eval("(every? (fn [x] (> x 0)) [1 2 3])") == true
    assert eval("(every? (fn [x] (> x 1)) [1 2 3])") == false
  end

  test "prelude fns compose with interop" do
    assert eval("(map String/upcase [\"a\" \"b\"])") == ["A", "B"]
  end

  test "str is variadic via arity dispatch" do
    assert eval("(str \"beam\" \"-lisp\")") == "beam-lisp"
    assert eval("(str 42)") == "42"
  end
end
