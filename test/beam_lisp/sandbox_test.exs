defmodule BeamLisp.SandboxTest do
  @moduledoc """
  PLAN-046 L3a: warm base images, checkout/checkin, cold loads, and the
  ExUnitCase wiring itself (this module IS an ExUnitCase consumer).
  """

  use BeamLisp.ExUnitCase,
    warm: {:sandbox_math, [Path.expand("../fixtures/aot/math.bl", __DIR__)]}

  alias BeamLisp.{Env, Sandbox}

  test "a warm fork sees the base's vars" do
    assert {:ok, 42} = Env.fetch("math", "answer")
  end

  test "writes stay in the fork" do
    Env.intern("math", "answer", 43)
    assert {:ok, 43} = Env.fetch("math", "answer")
  end

  test "the base is untouched by the previous test's shadow" do
    assert {:ok, 42} = Env.fetch("math", "answer")
  end

  test "warm!/2 is idempotent per VM" do
    base = Sandbox.base!(:sandbox_math)
    assert ^base = Sandbox.warm!(:sandbox_math, ["ignored"])
  end

  test "a cold env sees only the prelude until it loads" do
    Env.isolated(:global, fn ->
      assert :error = Env.fetch("math", "answer")
      # core prelude is reachable through the chain
      assert {:ok, _} = Env.fetch("user", "map")

      Sandbox.eval(~s[(ns sandbox.cold) (def x 7)])
      assert {:ok, 7} = Env.fetch("sandbox.cold", "x")
    end)

    # destroyed on exit: nothing leaks to :global
    assert :error = Env.fetch("sandbox.cold", "x")
  end
end
