defmodule BeamLisp.PerEnvDefTest do
  use ExUnit.Case, async: false

  # `^:per-env` defs: a stateful `def` marked per-env materializes its own
  # instance in each consuming env (fork), while un-marked defs keep one global
  # instance. This is the keystone that lets ward isolate a test file's app
  # dependencies and lets a gateway run per-tenant state in one VM.
  #
  # PLAN-060-A. The two probes that matter: (1) two sibling forks get DISTINCT
  # per-env instances but the SAME global instance; (2) it survives AOT
  # compilation (the value replays as a descriptor, not an eager intern).

  alias BeamLisp.Env

  setup do
    BeamLisp.init()
    :ok
  end

  # A fresh isolated fork that evaluates `src` and returns the value.
  defp in_fork(src) do
    Env.isolated(fn -> BeamLisp.eval(src) end)
  end

  describe "source path" do
    setup do
      # A uniquely-named ns per test run so repeated runs don't collide.
      ns = "pe.src#{System.unique_integer([:positive])}"

      BeamLisp.eval("""
      (ns #{ns})
      (def shared (atom :s))
      (def ^:per-env tenant (atom :t))
      """)

      {:ok, ns: ns}
    end

    test "two sibling forks share the global def but isolate the per-env def", %{ns: ns} do
      read = """
      (ns _r (:require [#{ns} :as p]))
      {:shared (erlang/term_to_binary p/shared)
       :tenant (erlang/term_to_binary p/tenant)}
      """

      a = in_fork(read)
      b = in_fork(read)

      assert a[:shared] == b[:shared], "un-marked def must be ONE shared global instance"
      refute a[:tenant] == b[:tenant], "^:per-env def must be a DISTINCT instance per fork"
    end

    test "the per-env instance is identity-stable within one fork", %{ns: ns} do
      # Two reads in the same fork must see the same instance (materialized once).
      same =
        Env.isolated(fn ->
          BeamLisp.eval("""
          (ns _r (:require [#{ns} :as p]))
          (identical? p/tenant p/tenant)
          """)
        end)

      assert same == true
    end

    test "a captured worker sees its parent env's per-env instance", %{ns: ns} do
      # A parent fork materializes its instance, then a spawned worker BOUND to
      # that env must observe the SAME instance (worker runs under parent's env).
      parent = Env.fork()

      {parent_val, worker_val} =
        Env.with_env(parent, fn ->
          pv =
            BeamLisp.eval("""
            (ns _p (:require [#{ns} :as p]))
            (erlang/term_to_binary p/tenant)
            """)

          token = Env.capture()
          me = self()

          spawn(fn ->
            Env.bind(token)

            wv =
              BeamLisp.eval("""
              (ns _w (:require [#{ns} :as p]))
              (erlang/term_to_binary p/tenant)
              """)

            send(me, {:worker, wv})
          end)

          wv =
            receive do
              {:worker, wv} -> wv
            after
              5000 -> flunk("worker never replied")
            end

          {pv, wv}
        end)

      assert parent_val == worker_val, "a bound worker must see the parent env's instance"
    after
      :ok
    end

    test "a true child env does NOT inherit the parent's materialized instance", %{ns: ns} do
      # Parent materializes; a nested isolated CHILD must get its own instance.
      parent = Env.fork()

      {parent_val, child_val} =
        Env.with_env(parent, fn ->
          pv =
            BeamLisp.eval("""
            (ns _p (:require [#{ns} :as p]))
            (erlang/term_to_binary p/tenant)
            """)

          cv =
            Env.isolated(fn ->
              BeamLisp.eval("""
              (ns _c (:require [#{ns} :as p]))
              (erlang/term_to_binary p/tenant)
              """)
            end)

          {pv, cv}
        end)

      refute parent_val == child_val, "a child env must materialize its OWN per-env instance"
    end

    test "destroying an env drops its per-env instance row", %{ns: ns} do
      env = Env.fork()

      Env.with_env(env, fn ->
        BeamLisp.eval("(ns _d (:require [#{ns} :as p])) p/tenant")
      end)

      # Instance row present before destroy, gone after.
      before = Env.with_env(env, fn -> Env.explain(ns, "tenant") end)
      assert Enum.any?(before, &(&1.kind == :per_env_materialized_here))

      Env.destroy(env)

      # A fresh env with the same id space cannot see the old instance (it was
      # swept by destroy's env-prefixed select_delete).
      env2 = Env.fork()
      after_ = Env.with_env(env2, fn -> Env.explain(ns, "tenant") end)
      refute Enum.any?(after_, &(&1.kind == :per_env_materialized_here))
    end

    test "redefining a per-env def rematerializes in an already-live env", %{ns: ns} do
      env = Env.fork()

      v1 =
        Env.with_env(env, fn ->
          BeamLisp.eval("(ns _d (:require [#{ns} :as p])) (reset! p/tenant :first) (deref p/tenant)")
        end)

      assert v1 == :first

      # Redefine the per-env def (new generation) — the live env must pick up the
      # NEW thunk on next read, not serve the stale instance.
      BeamLisp.eval("(ns #{ns}) (def ^:per-env tenant (atom :second))")

      v2 =
        Env.with_env(env, fn ->
          BeamLisp.eval("(ns _d (:require [#{ns} :as p])) (deref p/tenant)")
        end)

      assert v2 == :second, "a redefined per-env def must rematerialize (generation bump)"
    end
  end

  describe "rejections" do
    test "^:per-env on a defn is a compile error" do
      assert_raise BeamLisp.CompileError, ~r/per-env is only valid on a `def`/, fn ->
        BeamLisp.eval("(ns pe.rej1) (defn ^:per-env f [] 1)")
      end
    end

    test "^:per-env on a defmacro is a compile error" do
      assert_raise BeamLisp.CompileError, ~r/per-env is only valid on a `def`/, fn ->
        BeamLisp.eval("(ns pe.rej2) (defmacro ^:per-env m [] 1)")
      end
    end
  end

  describe "cycle detection" do
    test "a per-env init that reads itself raises a deterministic cycle error" do
      ns = "pe.cyc#{System.unique_integer([:positive])}"

      # `a`'s initializer reads `a` — a per-env self-cycle. Must raise, not hang.
      BeamLisp.eval("(ns #{ns}) (def ^:per-env a (deref a))")

      assert_raise RuntimeError, ~r/cyclic per-env initialization/, fn ->
        in_fork("(ns _r (:require [#{ns} :as p])) p/a")
      end
    end
  end

  describe "AOT path" do
    @fixture_dir "test/fixtures/aot"
    @compile_path Path.join(System.tmp_dir!(), "beam_lisp_per_env_fixtures")

    setup do
      Mix.Tasks.Compile.BeamLisp.clean(@compile_path)

      assert {:ok, _} =
               Mix.Tasks.Compile.BeamLisp.run(["--source-dir", @fixture_dir, "--out", @compile_path])

      Code.append_path(@compile_path)
      # Load the AOT namespace exactly as a fresh VM would.
      BeamLisp.Loader.ensure_loaded("per-env-fixture")
      :ok
    end

    test "an AOT-compiled per-env def isolates per fork; the global def is shared" do
      read = """
      (ns _r (:require [per-env-fixture :as p]))
      {:shared (erlang/term_to_binary p/shared-counter)
       :tenant (erlang/term_to_binary p/tenant-counter)}
      """

      a = in_fork(read)
      b = in_fork(read)

      assert a[:shared] == b[:shared], "AOT: un-marked def stays one shared global"
      refute a[:tenant] == b[:tenant], "AOT: ^:per-env def isolates per fork"
    end

    test "AOT per-env mutation stays within a fork" do
      # Each fork bumps its own tenant-counter; neither sees the other's count.
      bump = """
      (ns _r (:require [per-env-fixture :as p]))
      (p/bump-tenant) (p/bump-tenant) (p/tenant-value)
      """

      a = in_fork(bump)
      b = in_fork(bump)

      assert a == 2
      assert b == 2, "a fork's per-env mutations must not leak into another fork"
    end
  end
end
