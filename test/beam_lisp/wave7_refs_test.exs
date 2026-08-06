defmodule BeamLisp.Wave7RefsTest do
  use ExUnit.Case, async: false

  setup do
    BeamLisp.init()
    BeamLisp.Env.in_ns("user")
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  describe "atoms" do
    test "create and deref" do
      assert eval("(deref (atom 42))") == 42
    end

    test "@ reader sugar reads as (deref x)" do
      eval("(def w7-a (atom 5))")
      assert eval("@w7-a") == 5
      assert eval("(deref w7-a)") == 5
      assert eval("@ w7-a") == 5
    end

    test "swap! with extra args via +" do
      eval("(def w7-a (atom 10))")
      assert eval("(swap! w7-a + 1 2)") == 13
      assert eval("@w7-a") == 13
      assert eval("(swap! w7-a + 5)") == 18
    end

    test "swap! with a user defn" do
      eval("(defn w7-acc [total x] (+ total x))")
      eval("(def w7-a (atom 100))")
      assert eval("(swap! w7-a w7-acc 5)") == 105
      assert eval("@w7-a") == 105
    end

    test "reset!" do
      eval("(def w7-a (atom 1))")
      assert eval("(reset! w7-a 99)") == 99
      assert eval("@w7-a") == 99
    end

    test "compare-and-set! succeeds on match and fails on mismatch" do
      eval("(def w7-a (atom 0))")
      assert eval("(compare-and-set! w7-a 0 1)") == true
      assert eval("@w7-a") == 1
      assert eval("(compare-and-set! w7-a 0 99)") == false
      assert eval("@w7-a") == 1
    end
  end

  describe "futures" do
    test "deref a future returns its value" do
      assert eval("(deref (future (+ 1 2)))") == 3
    end

    test "future? predicate" do
      eval("(def w7-f (future 42))")
      assert eval("(future? w7-f)") == true
      assert eval("(future? 42)") == false
      assert eval("(deref w7-f)") == 42
    end

    test "deref with a timeout returns the timeout value on a slow future" do
      # Task.await is single-use: a timed-out await demonitors, so we
      # assert only the timeout branch here.
      eval("(def w7-f (future (Process/sleep 200) :slow))")
      assert eval("(deref w7-f 20 :timeout)") == :timeout
    end

    test "future-cancel kills a running future" do
      eval("(def w7-f (future (Process/sleep 500) :slow))")
      assert eval("(future-cancel w7-f)") == true
    end

    test "future-cancel on an already-completed future is false" do
      eval("(def w7-f (future 1))")
      assert eval("(deref w7-f)") == 1
      assert eval("(future-cancel w7-f)") == false
    end
  end

  describe "promises" do
    test "deliver then deref" do
      eval("(def w7-p (promise))")
      assert eval("(deliver w7-p 7)") != nil
      assert eval("(deref w7-p)") == 7
    end

    test "deref with timeout before deliver returns the timeout value" do
      eval("(def w7-p (promise))")
      assert eval("(deref w7-p 30 :timeout)") == :timeout
      eval("(deliver w7-p :later)")
      assert eval("(deref w7-p)") == :later
    end

    test "@ on a delivered promise" do
      eval("(def w7-p (promise))")
      eval("(deliver w7-p 9)")
      assert eval("@w7-p") == 9
    end

    test "a promise is delivered only once" do
      eval("(def w7-p (promise))")
      assert eval("(deliver w7-p 1)") != nil
      assert eval("(deliver w7-p 2)") == nil
      assert eval("@w7-p") == 1
    end
  end

  describe "reader" do
    test "@ alone (or with only whitespace) is a reader error" do
      assert_raise BeamLisp.Reader.SyntaxError, fn ->
        BeamLisp.Reader.read_all("@")
      end

      assert_raise BeamLisp.Reader.SyntaxError, fn ->
        BeamLisp.Reader.read_all("@   ")
      end
    end

    test "@ inside a string literal is untouched" do
      assert eval("\"@a\"") == "@a"
    end
  end

  describe "errors and cross-namespace" do
    test "deref on a non-reference raises" do
      assert_raise ArgumentError, fn -> eval("(deref 42)") end
    end

    test "swap! on a non-reference raises" do
      assert_raise ArgumentError, fn -> eval("(swap! 42 + 1)") end
    end

    test "future works in any namespace" do
      eval("(ns w7.other)")
      assert eval("(deref (future (* 6 7)))") == 42
      eval("(ns user)")
    end
  end
end
