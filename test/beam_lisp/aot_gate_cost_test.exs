defmodule BeamLisp.AotGateCostTest do
  use ExUnit.Case, async: false

  # Two defects that together made AOT a no-op for any application built from
  # the language's checkout, root-caused on a ninety-namespace app whose load
  # took 72s with every beam present and fresh:
  #
  #   1. `mix compile.beam_lisp --source-dir DIR` (DIR outside cwd) stamped
  #      every beam that requires a SIBLING with a closure key the runtime gate
  #      never matched: the emitter resolved siblings by name through the
  #      ambient search path, which did not contain DIR, so each sibling
  #      contributed `x:?` to the key. The gate, running with DIR on its path,
  #      folded the real hashes. Same bytes, different key → "stale" → silent
  #      source fallback on every boot. The build now registers its source
  #      dirs as search roots for its duration.
  #
  #   2. The gate's `ns_closure_hash/1` re-read and re-parsed a namespace's
  #      whole require-closure on EVERY call, and it is called once per
  #      namespace loaded — 90 × 90 parses (71.7s of the 72.5s). A plan node
  #      is a pure function of a file's bytes, so `BuildPlan.memo_node/2`
  #      memoizes it by content hash; the key is still folded from live bytes
  #      per call, so an edit is still seen.

  @tmp Path.join(System.tmp_dir!(), "beam_lisp_gate_cost")
  @src_dir Path.join(@tmp, "src")
  @out Path.join(@tmp, "out")

  @leaf_ns "gc.leaf"
  @root_ns "gc.root"
  @leaf Path.join(@src_dir, "gc/leaf.bl")
  @root Path.join(@src_dir, "gc/root.bl")

  setup do
    ensure_named(BeamLisp.Env, fn -> BeamLisp.Env.start_link([]) end)
    ensure_named(BeamLisp.Loader.Server, fn -> BeamLisp.Loader.Server.start_link([]) end)
    BeamLisp.init()
    File.rm_rf!(@tmp)
    File.mkdir_p!(Path.dirname(@leaf))
    File.write!(@leaf, "(ns gc.leaf)\n(defn one [] 1)\n")
    File.write!(@root, "(ns gc.root (:require [gc.leaf :as l]))\n(defn two [] (+ (l/one) (l/one)))\n")
    Code.append_path(@out)
    BeamLisp.BuildPlan.clear_memo()

    on_exit(fn ->
      File.rm_rf!(@tmp)
      BeamLisp.BuildPlan.clear_memo()
    end)

    :ok
  end

  defp ensure_named(name, start) do
    case Process.whereis(name) do
      nil ->
        {:ok, pid} =
          case start.() do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
          end

        Process.unlink(pid)
        :ok

      _ ->
        :ok
    end
  end

  defp build! do
    Mix.Tasks.Compile.BeamLisp.clean(@out)
    assert {:ok, _} = Mix.Tasks.Compile.BeamLisp.run(["--source-dir", @src_dir, "--out", @out])
    ensure_named(BeamLisp.Env, fn -> BeamLisp.Env.start_link([]) end)
    ensure_named(BeamLisp.Loader.Server, fn -> BeamLisp.Loader.Server.start_link([]) end)
  end

  defp provenance(ns) do
    mod = BeamLisp.Link.module_for(ns)
    :code.purge(mod)
    :code.delete(mod)
    path = Path.join(@out, Atom.to_string(mod) <> ".beam")
    {:module, ^mod} = :code.load_binary(mod, String.to_charlist(path), File.read!(path))
    {stamp, _key} = apply(mod, :__bl_provenance__, [])
    stamp
  end

  defp live_key(ns),
    do: BeamLisp.Loader.with_search_dir(@src_dir, fn -> BeamLisp.AOT.ns_closure_hash(ns) end)

  test "a beam that requires a sibling in a --source-dir outside cwd is fresh to the gate" do
    refute String.starts_with?(@src_dir, File.cwd!()), "fixture must live outside cwd"
    build!()

    # The leaf never failed (no requires); the root did — its stamp folded
    # `gc.leaf:?` where the gate folds the leaf's interface.
    assert provenance(@leaf_ns) == live_key(@leaf_ns)
    assert provenance(@root_ns) == live_key(@root_ns)

    # And the build must not leave its root on the app's search path.
    refute Path.expand(@src_dir) in BeamLisp.Env.search_paths()
  end

  test "the memoized gate still sees an edit to a closure member" do
    build!()
    before = live_key(@root_ns)
    assert before == provenance(@root_ns)

    # Repeated calls parse nothing new: the memo holds both files.
    assert live_key(@root_ns) == before
    assert memo_size() == 2

    # Edit the LEAF only. The root's bytes are unchanged, yet its key must
    # move (its closure is keyed over live bytes), and the gate must now
    # call the root stale.
    File.write!(@leaf, "(ns gc.leaf)\n(defn one [] 1)\n(defn zero [] 0)\n")
    after_edit = live_key(@root_ns)
    refute after_edit == before
    assert memo_size() == 3, "the edited file is parsed afresh; the root is not"

    Process.put(:bl_search_dirs, [@src_dir])
    assert BeamLisp.AOT.ensure_loaded(@root_ns) == :no_module
  end

  defp memo_size, do: :ets.info(:beam_lisp_build_plan_nodes, :size)
end
