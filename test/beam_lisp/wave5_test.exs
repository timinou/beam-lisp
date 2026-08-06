defmodule BeamLisp.Wave5Test do
  use ExUnit.Case, async: false

  setup do
    BeamLisp.init()
    BeamLisp.Env.in_ns("user")
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  defp self_send(msg), do: send(self(), msg)

  describe "var linking" do
    test "a defn is a named function in the namespace module" do
      eval("(defn w5-linked [x] (* x x))")
      assert apply(BeamLisp.Ns.User, :"w5-linked", [9]) == 81
    end

    test "redefinition takes effect for new calls" do
      eval("(defn w5-redef [x] 1)")
      assert eval("(w5-redef 0)") == 1
      eval("(defn w5-redef [x] 2)")
      assert eval("(w5-redef 0)") == 2
    end

    test "the interned value is a composable capture" do
      eval("(defn w5-double [x] (* 2 x))")
      assert eval("(Enum/map [1 2 3] w5-double)") == [2, 4, 6]
      assert eval("(map w5-double [1 2])") == [2, 4]
    end

    test "variadic and multi-arity defns link too" do
      eval("(defn w5-v [& xs] (count xs))")
      assert eval("(w5-v 1 2 3 4)") == 4
      eval("(defn w5-m ( [x] x) ( [x y] (+ x y)))")
      assert eval("(w5-m 1)") == 1
      assert eval("(w5-m 1 2)") == 3
    end

    test "recur in a defn is a named self-call in constant stack" do
      eval("(defn w5-cd [n] (if (= n 0) :done (recur (dec n))))")
      assert eval("(w5-cd 2000000)") == :done
    end

    test "linked calls work across namespaces" do
      eval("(ns w5.lib) (defn quadruple [x] (* 4 x))")
      eval("(ns w5.app (:require [w5.lib :as l]))")
      assert eval("(l/quadruple 5)") == 20
      eval("(ns user)")
    end

    test "prims link: variadic fallbacks still work" do
      assert eval("(+ 1 2 3 4)") == 10
      assert eval("(< 1 2 3)") == true
      assert eval("(= 1 1 1)") == true
    end
  end

  describe "receive" do
    test "keyword pattern" do
      self_send(:pong)
      assert eval("(receive :pong :got-it)") == :"got-it"
    end

    test "symbol pattern binds the message" do
      self_send(42)
      assert eval("(receive n (* n 2))") == 84
    end

    test "vector pattern matches an Erlang tuple" do
      self_send({:greet, "tuple"})
      assert eval(~s|(receive [:greet who] (str "hi " who))|) == "hi tuple"
    end

    test "the same vector pattern matches a beam-lisp vector" do
      eval("(erlang/send (erlang/self) [:greet \"vector\"])")
      assert eval(~s|(receive [:greet who] (str "hi " who))|) == "hi vector"
    end

    test "map pattern binds values" do
      self_send(%{cmd: 7})
      assert eval("(receive {:cmd n} (+ n 1))") == 8
    end

    test "after-timeout fires when nothing matches" do
      assert eval("(receive :never :no (after 10 :timed-out))") == :"timed-out"
    end

    test "first matching clause wins" do
      self_send(:x)
      assert eval("(receive :y :wrong :x :right)") == :right
    end

    test "wildcard matches anything" do
      self_send(:whatever)
      assert eval("(receive _ :wild)") == :wild
    end
  end
end
