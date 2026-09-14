defmodule BeamLisp.EnvFetchMemoTest do
  @moduledoc """
  The epoch + per-process memo on `Env.fetch/2` (blueprint FUP-019).

  Every var deref used to be a raw `:ets.lookup`, and an ETS read copies the
  term into the caller's heap: a loop referencing a `(def big …)` of 20k
  elements paid ~40 µs per deref (807 ms for 20k iterations vs 1 ms for a
  let-bound local). The memo makes a repeat deref a pdict read + an atomics
  read; every mutation path (`put_key/2`, `delete_key/1`, `destroy/1`,
  `match_delete_own/1`) bumps a global epoch that invalidates it.

  These tests pin the two properties that make the memo SAFE — invalidation
  on write and isolation across env chains — plus the one that makes it
  WORTHWHILE — a hot deref stops copying.
  """

  use ExUnit.Case, async: false

  alias BeamLisp.Env

  setup do
    BeamLisp.init()
    :ok
  end

  test "a re-interned var is visible on the very next fetch (epoch invalidation)" do
    Env.intern("memo.t", "v", :one)
    assert {:ok, :one} = Env.fetch("memo.t", "v")
    # Second fetch is served by the memo; the re-intern must still win.
    assert {:ok, :one} = Env.fetch("memo.t", "v")

    Env.intern("memo.t", "v", :two)
    assert {:ok, :two} = Env.fetch("memo.t", "v")
  end

  test "an undefined var is gone on the very next fetch" do
    Env.intern("memo.t", "doomed", :here)
    assert {:ok, :here} = Env.fetch("memo.t", "doomed")

    Env.undefine_var("memo.t", "doomed")
    assert :error = Env.fetch("memo.t", "doomed")
  end

  test "the memo is keyed by env chain: a fork's shadow never leaks to global" do
    Env.intern("memo.t", "chained", :global_value)
    assert {:ok, :global_value} = Env.fetch("memo.t", "chained")

    fork = Env.fork()

    Env.with_env(fork, fn ->
      assert {:ok, :global_value} = Env.fetch("memo.t", "chained")
      Env.intern("memo.t", "chained", :shadowed)
      assert {:ok, :shadowed} = Env.fetch("memo.t", "chained")
      # memo hit inside the fork
      assert {:ok, :shadowed} = Env.fetch("memo.t", "chained")
    end)

    # Back at :global the memo entry for THIS chain still says :global_value,
    # and the fork's write never touched it.
    assert {:ok, :global_value} = Env.fetch("memo.t", "chained")
    Env.destroy(fork)
  end

  test "a hot deref of a large var stops paying the ETS copy" do
    big = Enum.to_list(1..20_000)
    Env.intern("memo.t", "big", big)

    # Warm the memo.
    assert {:ok, ^big} = Env.fetch("memo.t", "big")

    {us, _} =
      :timer.tc(fn ->
        for _ <- 1..20_000, do: Env.fetch!("memo.t", "big")
      end)

    # Pre-memo this loop copied 20k cons cells per iteration: ~800 ms on the
    # reference host. The memo path is a pdict + atomics read; the bound here
    # is 100x under the old cost and still 10x above a slow CI host.
    assert us < 100_000, "20k hot derefs took #{us}µs — the memo is not holding"
  end
end
