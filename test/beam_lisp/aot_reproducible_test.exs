defmodule BeamLisp.AotReproducibleTest do
  @moduledoc """
  A compiled beam is a function of its source — nothing else.

  Reproducibility is what makes the AOT cache, the byte-parity oracle and
  "did this edit change the output?" mean anything, and it is exactly what
  a parallel build can quietly lose. This suite pins the four leaks that were
  found and closed (see the commit "Reproducible AOT"), on fixtures shaped
  to trigger each:

    * template gensyms (`x#` in a macro used by a dependent)
    * forward references (a defn calling one defined later in the file)
    * map literals through macros (atom-key enumeration order)
    * a defnative declaration surviving the worker that made it

  The property under test: compile the same sources twice — serially, then
  with 4 jobs, then serially again after unrelated compilation has advanced
  every VM-global counter — and every beam is byte-identical.
  """
  use ExUnit.Case, async: false

  @src Path.join(System.tmp_dir!(), "beam_lisp_repro_src")
  @out Path.join(System.tmp_dir!(), "beam_lisp_repro_out")

  setup do
    BeamLisp.init()
    File.rm_rf!(@src)
    File.mkdir_p!(@src)

    File.write!(Path.join(@src, "macros.bl"), """
    (ns repro.macros)
    (defmacro my-or [a b]
      `(let [t# ~a] (if t# t# ~b)))
    (defmacro with-map [x]
      `(let [m# {:zeta 1 :alpha 2 :on-click ~x :variant 3}] m#))
    """)

    File.write!(Path.join(@src, "user.bl"), """
    (ns repro.user (:require [repro.macros :as m]))
    ;; forward reference: mplus calls bind, defined below it
    (defn mplus [a b] (if (nil? a) b (bind a b)))
    (defn bind [a b] (m/my-or a b))
    (defn both [x] (m/my-or (m/my-or x 1) (m/with-map x)))
    (defn nested [xs] (when-let [s (seq xs)] (first s)))
    """)

    on_exit(fn ->
      File.rm_rf!(@src)
      Mix.Tasks.Compile.BeamLisp.clean(@out)
    end)

    :ok
  end

  defp build!(jobs) do
    Mix.Tasks.Compile.BeamLisp.clean(@out)
    args = ["--source-dir", @src, "--out", @out, "--force", "--jobs", Integer.to_string(jobs)]
    assert {:ok, _} = Mix.Tasks.Compile.BeamLisp.run(args)

    @out
    |> Path.join("Elixir.BeamLisp.Ns.*Repro.*.beam")
    |> Path.wildcard()
    |> Map.new(fn p -> {Path.basename(p), :crypto.hash(:sha256, File.read!(p))} end)
  end

  # Advance every VM-global counter the old emitters leaked through:
  # unique_integer, atom creation order, gensym baking.
  defp perturb! do
    for i <- 1..50, do: _ = String.to_atom("repro_perturb_atom_#{i}_#{System.unique_integer([:positive])}")

    BeamLisp.Compiler.eval_string(
      "(defmacro perturb-or [a b] `(let [t# ~a] (if t# t# ~b))) (perturb-or 1 2)",
      BeamLisp.Compiler.new_env("repro.perturb")
    )

    :ok
  end

  test "serial, parallel, and post-perturbation builds emit byte-identical beams" do
    a = build!(1)
    assert map_size(a) >= 4, "expected shim/body/init beams for both namespaces"

    b = build!(4)
    assert a == b, "parallel build differs from serial: #{inspect(differing(a, b))}"

    perturb!()
    c = build!(1)
    assert a == c, "build after VM-global perturbation differs: #{inspect(differing(a, c))}"
  end

  test "an expansion's gensyms are canonical (__c), never baked (__auto)" do
    BeamLisp.Compiler.reset_fresh!()
    form = BeamLisp.Reader.read_one("(fn [x] (when-let [s (seq x)] (first s)))")
    src = form |> BeamLisp.Compiler.compile(BeamLisp.Compiler.new_env("repro.user")) |> Macro.to_string()
    names = Regex.scan(~r/temp__\d+__(auto|c)/, src) |> Enum.map(&List.last/1) |> Enum.uniq()
    assert names == ["c"], "expected only canonical gensyms, saw #{inspect(names)} in #{src}"
  end

  defp differing(a, b) do
    for {k, v} <- a, Map.get(b, k) != v, do: k
  end
end
