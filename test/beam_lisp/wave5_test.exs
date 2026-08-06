defmodule BeamLisp.Wave5Test do
  use ExUnit.Case, async: false

  setup do
    BeamLisp.init()
    BeamLisp.Env.in_ns("user")
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  defp self_send(msg), do: send(self(), msg)

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
