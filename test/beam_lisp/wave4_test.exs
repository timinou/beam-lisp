defmodule BeamLisp.Wave4Test do
  use ExUnit.Case, async: false

  alias BeamLisp.{Env, Loader}

  setup do
    BeamLisp.init()
    Env.in_ns("user")
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  describe "namespaces" do
    test "ns switches the current namespace for defs" do
      eval("(ns w4.alpha) (defn who [] :alpha)")
      assert eval("(ns w4.beta) (w4.alpha/who)") == :alpha
    end

    test "defs are isolated between namespaces" do
      eval("(ns w4.a1) (def x 1)")
      eval("(ns w4.a2) (def x 2)")
      assert eval("(ns w4.a1) x") == 1
      assert eval("(ns w4.a2) x") == 2
    end

    test "core falls back from any namespace" do
      eval("(ns w4.somewhere)")
      assert eval("(map inc [1 2 3])") == [2, 3, 4]
    end

    test "aliases qualify calls and values" do
      eval("(ns w4.lib) (defn double-it [x] (* 2 x)) (def answer 42)")
      eval("(ns w4.app1 (:require [w4.lib :as lib]))")
      assert eval("(lib/double-it 21)") == 42
      assert eval("lib/answer") == 42
    end

    test "refer brings vars in bare" do
      eval("(ns w4.lib2) (defn triple [x] (* 3 x))")
      eval("(ns w4.app2 (:require [w4.lib2 :refer [triple]]))")
      assert eval("(triple 5)") == 15
    end

    test "macros resolve through aliases" do
      eval("(ns w4.mlib) (defmacro unless-m [c t f] `(if (not ~c) ~t ~f))")
      eval("(ns w4.mapp (:require [w4.mlib :as m]))")
      assert eval("(m/unless-m (= 1 2) :yes :no)") == :yes
    end

    test "a missing var in another ns reports that ns" do
      eval("(ns w4.empty-ns) (defn _placeholder [] 1)")
      eval("(ns w4.caller-ns)")
      assert_raise RuntimeError, ~r/undefined var: w4.empty-ns/, fn ->
        eval("(w4.empty-ns/nope 1)")
      end
    end
  end

  describe "the loader" do
    test "require loads <ns>.bl from the load path, once" do
      dir = Path.join(System.tmp_dir!(), "bl_w4_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "w4disk.bl")

      File.write!(path, """
      (ns w4disk)
      (defn from-disk [] :loaded)
      """)

      Loader.with_load_path(dir, fn ->
        eval("(ns w4.diskapp (:require [w4disk :as disk]))")
        assert eval("(disk/from-disk)") == :loaded
      end)

      assert Env.loaded_ns?("w4disk")
      File.rm_rf!(dir)
    end

    test "a required file's ns form does not leak into the requiring ns" do
      dir = Path.join(System.tmp_dir!(), "bl_w4_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "w4leak.bl"), """
      (ns w4leak)
      (def marker :from-w4leak)
      """)

      Loader.with_load_path(dir, fn ->
        eval("(ns w4.leakapp (:require [w4leak]))")
        assert Env.current_ns() == "w4.leakapp"
      end)

      File.rm_rf!(dir)
    end

    test "requiring a missing namespace names the search" do
      assert_raise RuntimeError, ~r/namespace not found: no.such.ns/, fn ->
        eval("(ns w4.broken (:require [no.such.ns]))")
      end
    end
  end

  describe "fn-targeted recur" do
    test "recur re-enters the fn in constant stack" do
      assert eval("(defn w4-countdown [n] (if (= n 0) :done (recur (dec n)))) (w4-countdown 500000)") == :done
    end

    test "multi-arg recur" do
      assert eval("(defn w4-fib [n a b] (if (= n 0) a (recur (dec n) b (+ a b)))) (w4-fib 30 0 1)") == 832_040
    end

    test "an inner fn's recur targets the inner fn, not the outer" do
      assert eval("""
             (defn w4-outer [n]
               (let [helper (fn [k] (if (= k 0) :inner-done (recur (dec k))))]
                 (helper n)))
             (w4-outer 100)
             """) == :"inner-done"
    end

    test "recur arity must match the fn's params" do
      assert_raise RuntimeError, ~r/recur arity mismatch/, fn ->
        eval("(fn [a b] (recur 1))")
      end
    end
  end

  describe "variadic arithmetic" do
    test "+ and * fold any arity, with identity at zero" do
      assert eval("(+)") == 0
      assert eval("(*)") == 1
      assert eval("(+ 1 2 3 4)") == 10
      assert eval("(* 2 3 4)") == 24
    end

    test "- and / with one arg negate and invert" do
      assert eval("(- 5)") == -5
      assert eval("(/ 2)") == 0.5
      assert eval("(- 10 3 2)") == 5
    end

    test "comparisons chain" do
      assert eval("(< 1 2 3)") == true
      assert eval("(< 1 3 2)") == false
      assert eval("(= 2 2 2)") == true
      assert eval("(= 2 2 3)") == false
      assert eval("(< 1)") == true
    end
  end
end
