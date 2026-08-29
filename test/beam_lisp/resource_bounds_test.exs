defmodule BeamLisp.ResourceBoundsTest do
  use ExUnit.Case, async: false
  alias BeamLisp.Env

  setup do
    BeamLisp.init()
    :ok
  end

  test "max_heap_words kills a runaway future, not the VM" do
    env = Env.fork(:global, max_heap_words: 50_000)

    Env.with_env(env, fn ->
      f = BeamLisp.Refs.future_exec(fn -> BeamLisp.eval("(apply str (range 1000000))") end)
      # the future's process overflows its heap and dies; deref returns the
      # timeout value for a dead task, and the VM (this test) is unharmed
      BeamLisp.Refs.deref(f, 5000, :heap_bound_enforced)
      refute Process.alive?(f.task.pid)
    end)

    Env.destroy(env)
  end

  test "bounded heap is monotonic: child never exceeds parent" do
    parent = Env.fork(:global, max_heap_words: 100_000)
    child = Env.fork(parent, max_heap_words: 200_000)
    assert Env.heap_of(child) == 100_000
    grandchild = Env.fork(parent, max_heap_words: 50_000)
    assert Env.heap_of(grandchild) == 50_000
  end

  test "unbounded envs spawn unbounded futures (default unchanged)" do
    assert Env.max_heap() == nil
    f = BeamLisp.Refs.future_exec(fn -> BeamLisp.eval("(+ 1 2)") end)
    assert BeamLisp.Refs.deref(f, 5000, :timeout) == 3
  end
end
