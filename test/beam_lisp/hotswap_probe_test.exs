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

  # `compile_source/2` emits SEVERAL beams per namespace — the `BeamLisp.Ns.<Ns>`
  # shim module, its `BeamLisp.Ns.Body.<Ns>` body module (where the real fn code
  # lives), and a `BeamLisp.Ns.Init.<Ns>` companion when there are value/macro
  # defs — plus a `Ns.User` entry for whatever earlier tests def'd into `user`
  # in this VM. The hot-swap UNIT is therefore the set of beams whose module is
  # the namespace module or lives under its `Body`/`Init` children; loading only
  # the shim would leave the old body code in place. `ns_beams/2` selects that
  # set (by module-name prefix), and `paths/1` returns their `.beam` paths.
  defp ns_beams(emitted, ns_mod) do
    # tail after `BeamLisp.Ns`, e.g. ["Hotswapprobe"] — the namespace's own
    # segment(s), shared by its `Body`/`Init` children.
    ["BeamLisp", "Ns" | tail] = Module.split(ns_mod)
    body = Module.concat([BeamLisp.Ns, "Body" | tail])
    init = Module.concat([BeamLisp.Ns, "Init" | tail])
    set = [ns_mod, body, init]
    Enum.filter(emitted, fn {m, _p} -> m in set end)
  end

  # Load every beam in an emitted set from disk, newest code wins.
  defp load_all(emitted) do
    for {m, p} <- emitted do
      :code.purge(m)
      {:module, ^m} = :code.load_abs(String.to_charlist(Path.rootname(p)))
    end
  end

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

    call = fn mod -> apply(mod, :greet, [1]) end

    # ── read/emit: compile a namespace to a real beam SET ──
    # The hot-swap unit is the namespace's shim + body (+ init) beams; the real
    # `greet` code lives in the body module, so all of them move together.
    mod = BeamLisp.Ns.Hotswapprobe
    e1 = ns_beams(BeamLisp.AOT.compile_source(v1, output_dir: tmp), mod)
    load_all(e1)
    BeamLisp.AOT.ensure_loaded("hotswapprobe")
    assert call.(mod) == "v1"

    # The known-good artifact is the BINARY set. This is the whole decision:
    # remembered bytes cannot fail to recompile because they already compiled.
    good_binaries = for {m, p} <- e1, do: {m, File.read!(p)}

    # ── load: a compatible revision swaps in live, no restart ──
    e2 = ns_beams(BeamLisp.AOT.compile_source(v2, output_dir: tmp), mod)
    load_all(e2)
    BeamLisp.AOT.ensure_loaded("hotswapprobe")
    assert call.(mod) == "v2"

    # ── validate: a bad revision loads fine and fails only when RUN ──
    # This is exactly why `validate` cannot be "did it compile?" -- it did.
    e3 = ns_beams(BeamLisp.AOT.compile_source(bad, output_dir: tmp), mod)
    load_all(e3)
    BeamLisp.AOT.ensure_loaded("hotswapprobe")
    assert {:error, _} = (try do
                            {:ok, call.(mod)}
                          rescue
                            e -> {:error, Exception.message(e)}
                          end)

    # ── revert: load the remembered bytes; cannot fail to compile ──
    for {m, bin} <- good_binaries do
      :code.purge(m)
      {:module, ^m} = :code.load_binary(m, ~c"revert", bin)
    end

    BeamLisp.AOT.ensure_loaded("hotswapprobe")
    assert call.(mod) == "v1"
  end
end
