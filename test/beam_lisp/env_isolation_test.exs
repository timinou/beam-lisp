defmodule BeamLisp.EnvIsolationTest do
  @moduledoc """
  PLAN-046 L1/L2: process-scoped envs, read-through chains, spawn
  propagation. These tests exercise the isolation machinery itself, so
  they run at `:global` and fork explicitly — they are `async: false`
  only because they assert on `:global` rows.
  """

  use ExUnit.Case, async: false

  alias BeamLisp.Env

  setup do
    BeamLisp.init()
    :ok
  end

  test "a fork reads through to its parent and writes stay local" do
    Env.intern("iso.t", "base-var", :from_global)
    base = Env.fork()

    Env.with_env(base, fn ->
      assert {:ok, :from_global} = Env.fetch("iso.t", "base-var")

      Env.intern("iso.t", "base-var", :shadowed)
      Env.intern("iso.t", "own-var", :mine)

      assert {:ok, :shadowed} = Env.fetch("iso.t", "base-var")
      assert {:ok, :mine} = Env.fetch("iso.t", "own-var")
    end)

    assert {:ok, :from_global} = Env.fetch("iso.t", "base-var")
    assert :error = Env.fetch("iso.t", "own-var")
    Env.destroy(base)
  end

  test "two concurrent forks of one base isolate the same var" do
    a = Env.fork()
    b = Env.fork()
    parent = self()

    ta =
      Task.async(fn ->
        Env.with_env(a, fn ->
          Env.intern("iso.c", "v", :a)
          Process.sleep(30)
          send(parent, {:a, Env.fetch("iso.c", "v")})
        end)
      end)

    tb =
      Task.async(fn ->
        Env.with_env(b, fn ->
          Env.intern("iso.c", "v", :b)
          Process.sleep(30)
          send(parent, {:b, Env.fetch("iso.c", "v")})
        end)
      end)

    Task.await(ta)
    Task.await(tb)
    assert_received {:a, {:ok, :a}}
    assert_received {:b, {:ok, :b}}
    assert :error = Env.fetch("iso.c", "v")

    Env.destroy(a)
    Env.destroy(b)
  end

  test "a forked fork chains two deep" do
    Env.intern("iso.d", "deep", :global_value)
    mid = Env.fork()
    Env.with_env(mid, fn -> Env.intern("iso.d", "mid-only", 1) end)
    leaf = Env.fork(mid)

    Env.with_env(leaf, fn ->
      assert {:ok, 1} = Env.fetch("iso.d", "mid-only")
      assert {:ok, :global_value} = Env.fetch("iso.d", "deep")
    end)

    Env.destroy(leaf)
    Env.destroy(mid)
  end

  test "isolated/1 destroys its env afterwards" do
    assert :done = Env.isolated(fn -> Env.intern("iso.gone", "z", 1) && :done end)
    assert :error = Env.fetch("iso.gone", "z")
  end

  test "destroy sweeps every key shape of the env" do
    env = Env.fork()

    Env.with_env(env, fn ->
      Env.intern("iso.sweep", "v", 1)
      Env.declare_ns("iso.sweep2")
      Env.add_alias("iso.sweep", "a", "core")
      Env.add_refer("iso.sweep", "map", "core")
      Env.put_meta("iso.sweep", "v", %{doc: "x"})
      Env.put_link("iso.sweep", "v", {Some.Mod, %{1 => :f}, nil})
      Env.put_ns_defs("iso.sweep", %{"v" => []})
    end)

    Env.destroy(env)
    # A fresh fork of :global must see NONE of it (a live env would
    # still hold the rows; a destroyed one must not).
    Env.isolated(fn ->
      assert :error = Env.fetch("iso.sweep", "v")
      refute Env.ns_exists?("iso.sweep2")
      assert Env.alias_target("iso.sweep", "a") == nil
      assert Env.refer_source("iso.sweep", "map") == nil
      assert Env.meta("iso.sweep", "v") == :error
      assert Env.link("iso.sweep", "v") == :error
      assert Env.ns_defs("iso.sweep") == %{}
    end)
  end

  test "current_ns is process-local inside a fork" do
    env = Env.fork()
    parent = self()

    Env.with_env(env, fn ->
      assert Env.current_ns() == "user"
      Env.in_ns("iso.ns")

      Task.async(fn ->
        Env.with_env(env, fn -> send(parent, {:child_ns, Env.current_ns()}) end)
      end)
      |> Task.await()

      assert_received {:child_ns, "user"}
      assert Env.current_ns() == "iso.ns"
    end)

    Env.destroy(env)
  end

  test "mark_loaded is per-env and chain-visible" do
    env = Env.fork()

    Env.with_env(env, fn ->
      refute Env.loaded_ns?("iso.loaded")
      Env.mark_loaded("iso.loaded")
      assert Env.loaded_ns?("iso.loaded")
    end)

    refute Env.loaded_ns?("iso.loaded")
    # Chain: a fork OF env sees env's marks.
    child = Env.fork(env)
    Env.with_env(child, fn -> assert Env.loaded_ns?("iso.loaded") end)

    Env.destroy(child)
    Env.destroy(env)
  end

  test "put_meta in a fork merges onto the ancestor's copy, locally" do
    Env.put_meta("iso.m", "v", %{doc: "base doc", private: true})
    env = Env.fork()

    Env.with_env(env, fn ->
      Env.put_meta("iso.m", "v", %{doc: "fork doc"})
      assert {:ok, %{doc: "fork doc", private: true}} = Env.meta("iso.m", "v")
    end)

    assert {:ok, %{doc: "base doc", private: true}} = Env.meta("iso.m", "v")
    Env.destroy(env)
  end

  test "L2: a future inherits the spawning env" do
    env = Env.fork()

    result =
      Env.with_env(env, fn ->
        Env.intern("iso.fut", "answer", 42)

        f = BeamLisp.Refs.future_exec(fn -> Env.fetch("iso.fut", "answer") end)
        Task.await(f.task)
      end)

    assert {:ok, 42} = result
    Env.destroy(env)
  end

  test "L2: capture/bind carries the env across a bare spawn" do
    env = Env.fork()
    parent = self()

    Env.with_env(env, fn ->
      Env.intern("iso.cap", "v", :carried)
      token = Env.capture()
      spawn(fn -> Env.bind(token); send(parent, {:spawned, Env.fetch("iso.cap", "v")}) end)
    end)

    assert_receive {:spawned, {:ok, :carried}}, 1000
    Env.destroy(env)
  end

  test "a bare spawn WITHOUT bind lands in :global (documents the contract)" do
    env = Env.fork()
    parent = self()

    Env.with_env(env, fn ->
      Env.intern("iso.nobind", "v", 1)
      spawn(fn -> send(parent, {:bare, Env.fetch("iso.nobind", "v")}) end)
    end)

    assert_receive {:bare, :error}, 1000
    Env.destroy(env)
  end

  test "explain/2 walks the chain" do
    Env.intern("iso.ex", "v", 1)
    env = Env.fork()

    rows = Env.with_env(env, fn -> Env.explain("iso.ex", "v") end)

    assert %{env: ^env, found: false} = Enum.find(rows, &(&1.env == env))
    assert %{env: :global, found: true} = Enum.find(rows, &(&1.env == :global))
    Env.destroy(env)
  end
end
