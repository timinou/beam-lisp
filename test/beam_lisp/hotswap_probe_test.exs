defmodule BeamLisp.HotswapProbeTest do
  use ExUnit.Case, async: false

  # The SELF cluster's load step (PLAN-019), demonstrated end to end with the
  # machinery that ALREADY EXISTS. PLAN-019 listed SELF as blocked on a
  # "hotswap API (compile→binary callable from the language)". The binary was
  # never missing: `AOT.compile_source/2` compiles a namespace and hands the
  # `.beam` bytes to `File.write!`. Everything below is `:code`.
  #
  # The load step is therefore not new machinery, it is a WRAPPER. What is
  # genuinely missing is `reason` (an LLM proposing a revision) and `validate`
  # (deciding whether to keep it) -- not the ability to swap.
  #
  # PLAN-019 decision 1, proven here rather than asserted: the rollback artifact
  # is the compiled BINARY, not source text. A remembered binary cannot fail to
  # recompile -- it already compiled. Re-evaluating remembered SOURCE can fail
  # against a changed sibling, which is the failure mode this deletes.

  @moduletag :tmp_dir

  # `compile_source/2` returns a module per namespace TOUCHED, and the `user`
  # namespace accumulates whatever earlier tests def'd into it in this VM. So
  # it can hand back `[{Ns.Hotswapprobe, _}, {Ns.User, _}]` in a full-suite run
  # and only `[{Ns.Hotswapprobe, _}]` when run alone. Select by name; matching a
  # one-element list passes in isolation and fails in the suite.
  defp pick(emitted, mod), do: Enum.find_value(emitted, fn {m, p} -> m == mod && p end)

  setup do
    BeamLisp.init()
    :ok
  end

  test "compile → load → detect a bad revision → revert to the remembered binary",
       %{tmp_dir: tmp} do
    Code.prepend_path(tmp)

    v1 = "(ns hotswapprobe)\n(defn greet [x] \"v1\")\n"
    v2 = "(ns hotswapprobe)\n(defn greet [x] \"v2\")\n"
    bad = "(ns hotswapprobe)\n(defn greet [x] (throw (ex-info \"boom\" {})))\n"

    load = fn path, mod ->
      :code.purge(mod)
      {:module, ^mod} = :code.load_abs(String.to_charlist(Path.rootname(path)))
      BeamLisp.AOT.ensure_loaded("hotswapprobe")
    end

    call = fn mod -> apply(mod, :greet, [1]) end

    # ── read/emit: compile a namespace to a real .beam ──
    mod = BeamLisp.Ns.Hotswapprobe
    p1 = pick(BeamLisp.AOT.compile_source(v1, output_dir: tmp), mod)
    BeamLisp.AOT.ensure_loaded("hotswapprobe")
    assert call.(mod) == "v1"

    # The known-good artifact is the BINARY. This is the whole decision.
    good_binary = File.read!(p1)

    # ── load: a compatible revision swaps in live, no restart ──
    p2 = pick(BeamLisp.AOT.compile_source(v2, output_dir: tmp), mod)
    load.(p2, mod)
    assert call.(mod) == "v2"

    # ── validate: a bad revision loads fine and fails only when RUN ──
    # This is exactly why `validate` cannot be "did it compile?" -- it did.
    p3 = pick(BeamLisp.AOT.compile_source(bad, output_dir: tmp), mod)
    load.(p3, mod)
    assert {:error, _} = (try do
                            {:ok, call.(mod)}
                          rescue
                            e -> {:error, Exception.message(e)}
                          end)

    # ── revert: load the remembered bytes; cannot fail to compile ──
    :code.purge(mod)
    {:module, ^mod} = :code.load_binary(mod, ~c"revert", good_binary)
    BeamLisp.AOT.ensure_loaded("hotswapprobe")
    assert call.(mod) == "v1"
  end
end
