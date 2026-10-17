# ns_guard_child.exs — a fresh VM whose code path prefers `Elixir.BeamLisp.Env`
# and `Elixir.BeamLisp.Loader` compiled from the CURRENT `priv/host` sources.
#
# Why a child VM: `priv/host/*.bl` is the source of the PINNED host beams that
# the committed floor carries. Editing the source does not replace the beams the
# running VM executes (`docs/bootstrap-regeneration.org`), so a test that wants
# to see a host-source change before the floor is regenerated has to compile the
# sources and run them as the production atoms in a VM of its own — the same
# technique `test/bl/env_host_test.bl` uses for the registry's boot semantics.
#
# Two callers share this script:
#
#   test/bl/namespace_readiness_fast_path_test.bl   asserts `semantics=ok`
#   bench/ns_guard_bench.bl                         reads the `-us=` timings
#
# It prints `name=value` lines and never exits non-zero on a failed check: a
# check that fails is DATA (`check-…=FAIL …`), because the same script is run
# against the old floor to produce a before/after measurement.

defmodule NsGuardChild do
  @moduledoc false

  defmodule Ctx do
    defstruct [:dir, :prov, :caller, :bencher, :count]
  end

  # ── small helpers ─────────────────────────────────────────────────────────

  def write!(path, text) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
    path
  end

  def count(path), do: path |> File.read!() |> String.length()

  def check(results, name, fun) do
    value =
      try do
        fun.()
      catch
        kind, error -> {:raised, kind, Exception.message(error)}
      end

    ok? = value == true
    IO.puts("check-#{name}=#{if ok?, do: "ok", else: "FAIL #{inspect(value)}"}")
    [ok? | results]
  end

  def timed(label, fun) do
    {us, value} = :timer.tc(fun)
    IO.puts("#{label}-us=#{us}")
    value
  end

  def ns_ready_loop(_ns, 0), do: :ok

  def ns_ready_loop(ns, n) do
    true = BeamLisp.Env.ns_ready?(ns)
    ns_ready_loop(ns, n - 1)
  end

  def ensure_loop(_ns, 0), do: :ok

  def ensure_loop(ns, n) do
    :ok = BeamLisp.Loader.ensure_ready(ns)
    ensure_loop(ns, n - 1)
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  def setup! do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    dir = Path.join(System.tmp_dir!(), "bl_ns_guard_" <> suffix)
    File.mkdir_p!(dir)

    prov = "guard.prov" <> suffix
    caller = "guard.call" <> suffix
    bencher = "guard.bench" <> suffix
    count = Path.join(dir, "init.count")
    File.write!(count, "")

    write!(Path.join(dir, "guard/prov#{suffix}.bl"),
      "(ns #{prov})\n" <>
        "(def init-count (do (File/write! #{inspect(count)} " <>
        "(str (File/read! #{inspect(count)}) \"+\")) 1))\n" <>
        "(defn ping [] 7)\n")

    # `:as` makes the require DEFERRED: the first use initializes the provider.
    write!(Path.join(dir, "guard/call#{suffix}.bl"),
      "(ns #{caller} (:require [#{prov} :as p]))\n" <>
        "(defn go [] (p/ping))\n")

    # The same direct cross-namespace call, in a loop: the guard the compiler
    # emits ahead of `(p/ping)` runs once per iteration.
    write!(Path.join(dir, "guard/bench#{suffix}.bl"),
      "(ns #{bencher} (:require [#{prov} :as p]))\n" <>
        "(defn go [n] (loop [i 0] (if (< i n) (do (p/ping) (recur (inc i))) i)))\n")

    %Ctx{dir: dir, prov: prov, caller: caller, bencher: bencher, count: count}
  end

  # ── the run ───────────────────────────────────────────────────────────────

  def main do
    BeamLisp.init()
    BeamLisp.Env.attach(:global)
    BeamLisp.Env.clear_search_paths()

    IO.puts("env-beam=" <> List.to_string(:code.which(BeamLisp.Env)))
    IO.puts("loader-beam=" <> List.to_string(:code.which(BeamLisp.Loader)))

    ctx = setup!()
    results = []

    results =
      BeamLisp.Loader.with_ambient_dirs([ctx.dir], fn ->
        BeamLisp.Loader.ensure_loaded(ctx.caller)
        BeamLisp.Loader.ensure_loaded(ctx.bencher)

        results =
          check(results, "declared-is-not-ready", fn ->
            BeamLisp.Env.ns_ready?(ctx.prov) == false
          end)

        # (a) A deferred namespace still initializes EXACTLY once, through the
        # emitted direct-call guard.
        results =
          check(results, "direct-call-initializes", fn ->
            BeamLisp.eval("(#{ctx.caller}/go)") == 7
          end)

        results =
          check(results, "init-ran-once", fn ->
            count(ctx.count) == 1
          end)

        results =
          check(results, "ready-after-init", fn ->
            BeamLisp.Env.ns_ready?(ctx.prov) == true
          end)

        results =
          check(results, "guard-is-a-no-op-when-ready", fn ->
            BeamLisp.Loader.ensure_ready(ctx.prov) == :ok and
              BeamLisp.Loader.ensure_ready(ctx.prov) == :ok and
              count(ctx.count) == 1
          end)

        # (b) The fast path is a global-env fact in `persistent_term`, and it is
        # consulted BEFORE the env chain: with no chain at all a globally ready
        # namespace still answers ready, while an unrelated one answers false.
        results =
          check(results, "global-flag-set", fn ->
            :persistent_term.get({:beam_lisp_ns_ready, ctx.prov}, false) == true
          end)

        saved = Process.get(:bl_env_chain)

        results =
          check(results, "fast-path-skips-chain", fn ->
            Process.put(:bl_env_chain, [])
            try do
              BeamLisp.Env.ns_ready?(ctx.prov) == true
            after
              restore_chain(saved)
            end
          end)

        results =
          check(results, "unknown-namespace-stays-false", fn ->
            Process.put(:bl_env_chain, [])
            try do
              BeamLisp.Env.ns_ready?("guard.never" <> Integer.to_string(System.unique_integer([:positive]))) == false
            after
              restore_chain(saved)
            end
          end)

        # (c) Loading from inside a child env: namespaces initialize in the
        # GLOBAL env (the loader's long-standing rule — a source namespace is
        # one shared definition), so the fast fact agrees with the ETS mirror:
        # ready everywhere, and the env that asked sees it too.
        child_leaf = "provchild" <> Integer.to_string(System.unique_integer([:positive]))
        child_prov = "guard." <> child_leaf

        write!(Path.join(ctx.dir, "guard/#{child_leaf}.bl"),
          "(ns #{child_prov})\n(defn ping [] 9)\n")

        env = BeamLisp.Env.fork()

        results =
          check(results, "child-env-load-is-ready-in-child", fn ->
            BeamLisp.Env.with_env(env, fn -> BeamLisp.Loader.ensure_loaded(child_prov) end)
            BeamLisp.Env.with_env(env, fn -> BeamLisp.Env.ns_ready?(child_prov) end) == true
          end)

        results =
          check(results, "fast-fact-agrees-with-global-mirror", fn ->
            global? = :ets.member(:beam_lisp_vars, {:global, :ns_ready, child_prov})
            BeamLisp.Env.ns_ready?(child_prov) == global? and
              :persistent_term.get({:beam_lisp_ns_ready, child_prov}, false) == global?
          end)

        BeamLisp.Env.destroy(env)

        # Measurements. The first two isolate the guard; the third is the real
        # emitted shape: a direct cross-namespace call in a loop.
        _ = timed("ns-ready-1m", fn -> ns_ready_loop(ctx.prov, 1_000_000) end)
        _ = timed("ensure-ready-1m", fn -> ensure_loop(ctx.prov, 1_000_000) end)
        _ = timed("direct-call-1m", fn -> BeamLisp.eval("(#{ctx.bencher}/go 1000000)") end)

        # Cost per `ns_ready?` in reductions: the fast path is one persistent
        # term read, so a call cannot approach the ~600 reductions the chain
        # walk + tuple construction used to cost.
        r0 = :erlang.process_info(self(), :reductions) |> elem(1)
        ns_ready_loop(ctx.prov, 100_000)
        r1 = :erlang.process_info(self(), :reductions) |> elem(1)
        per_call = (r1 - r0) / 100_000
        IO.puts("ns-ready-reductions-per-call=#{Float.round(per_call, 1)}")

        # The chain walk + tuple construction measured ~600 reductions per
        # guard; the fast path is one persistent-term read and a loop tick.
        check(results, "guard-reduction-bound", fn -> per_call < 100 end)
      end)

    File.rm_rf(ctx.dir)
    IO.puts("semantics=#{if Enum.all?(results), do: "ok", else: "fail"}")
  end

  defp restore_chain(nil), do: Process.delete(:bl_env_chain)
  defp restore_chain(chain), do: Process.put(:bl_env_chain, chain)
end

NsGuardChild.main()
