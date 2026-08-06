defmodule BeamLisp.Wave6ErrorsTest do
  use ExUnit.Case, async: false

  setup do
    BeamLisp.init()
    BeamLisp.Env.in_ns("user")
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  defp self_send(msg), do: send(self(), msg)

  describe "throw / untyped catch" do
    test "a thrown ex-info round-trips through ex-data" do
      assert eval(~s|(try (throw (ex-info "boom" {:code 42})) (catch e (ex-data e)))|) == %{code: 42}
    end

    test "ex-message recovers the payload message" do
      assert eval(~s|(try (throw (ex-info "boom" {:code 42})) (catch e (ex-message e)))|) == "boom"
    end

    test "a thrown bare value is wrapped and its message is the print form" do
      assert eval(~s|(ex-message (try (throw :plain) (catch e e)))|) == ":plain"
    end

    test "a non-map payload has nil ex-data" do
      assert eval(~s|(ex-data (try (throw :plain) (catch e e)))|) == nil
    end

    test "ex-data on a non-exception is nil" do
      assert eval(~s|(ex-data 42)|) == nil
    end
  end

  describe "ex-info / ex-message helpers" do
    test "ex-info builds a payload with data" do
      assert eval(~s|(ex-data (ex-info "kaboom" {:n 7}))|) == %{n: 7}
    end

    test "ex-message returns the message" do
      assert eval(~s|(ex-message (ex-info "kaboom" {:n 7}))|) == "kaboom"
    end
  end

  describe "finally" do
    test "finally runs on success and the body value wins" do
      self_send(:"w6-ran")
      assert eval("(try :body (finally (erlang/send (erlang/self) :w6-ran)))") == :body
      assert_received :"w6-ran"
    end

    test "finally runs on a caught raise" do
      self_send(:"w6-caught")
      assert eval("(try (throw :x) (catch e :caught) (finally (erlang/send (erlang/self) :w6-caught)))") == :caught
      assert_received :"w6-caught"
    end

    test "finally's value is discarded" do
      self_send(:"w6-discard")
      assert eval("(try :body (finally (do (erlang/send (erlang/self) :w6-discard) :discarded)))") == :body
      assert_received :"w6-discard"
    end
  end

  describe "typed catch" do
    test "matches only its struct" do
      assert eval(~s|(try (throw (ex-info "boom" {:code 42})) (catch BeamLisp.ExInfo e :matched))|) == :matched
    end

    test "a different exception falls through and re-raises" do
      assert_raise ArithmeticError, fn -> eval(~s|(try (/ 1 0) (catch BeamLisp.ExInfo e :matched))|) end
    end
  end

  describe "raw Erlang errors" do
    test "an arithmetic error is caught and normalized to a struct" do
      assert eval(~s|(try (/ 1 0) (catch e (ex-message e)))|) == "bad argument in arithmetic expression"
    end

    test "ex-data on a non-ExInfo error is nil" do
      assert eval(~s|(try (/ 1 0) (catch e (ex-data e)))|) == nil
    end
  end

  describe "structure" do
    test "nested try: inner catch wins" do
      assert eval("(try (try (throw :inner) (catch e :inner-caught)) (catch e :outer-caught))") == :"inner-caught"
    end

    test "first matching clause wins" do
      self_send(:"w6-first")
      assert eval("(try (throw :x) (catch e (erlang/send (erlang/self) :w6-first) :a) (catch e :b))") == :a
      assert_received :"w6-first"
    end

    test "try value semantics: bare try is its body" do
      assert eval("(try 42)") == 42
    end
  end

  describe "compile errors" do
    test "a catch whose first arg is not a symbol is a compile error" do
      assert_raise RuntimeError, ~r/catch requires a variable or Module.Name/, fn ->
        eval("(try :x (catch :bad e :h))")
      end
    end
  end
end
