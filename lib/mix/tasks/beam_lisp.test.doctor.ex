defmodule Mix.Tasks.BeamLisp.Test.Doctor do
  @moduledoc """
  Audit the project's ExUnit suites for beam-lisp async-readiness:
  `mix beam_lisp.test.doctor [DIR]` (default `test`).

  For every `*_test.exs` file the doctor reports one verdict:

    * ADOPTS — already uses `BeamLisp.ExUnitCase`
    * READY — uses no beam-lisp runtime at all; `async: true` is free
    * FLIPPABLE — touches the beam-lisp runtime but none of the
      documented-global registries; convert with
      `use BeamLisp.ExUnitCase, warm: {…}` (see doc/async-testing.md)
    * STAYS SYNC — touches `BeamLisp.Record` / `BeamLisp.Native` /
      `BeamLisp.LazySeq` internals, `Interface.Server`-style app
      singletons, or mutates `:global` env directly; keep `async: false`
      and say why in a comment

  Verdicts are grep-grade heuristics — they exist to order the migration,
  not to prove a file safe. The suite run is the proof.
  """

  @shortdoc "Audit test files for beam-lisp async-readiness"

  use Mix.Task

  @global_smells [
    {"BeamLisp.Record", "record registry is VM-global"},
    {"BeamLisp.Native", "native host modules are VM-global"},
    {"BeamLisp.LazySeq", "lazy-seq realization cache is VM-global"},
    {"Interface.Server", "app singleton (agent registry on persistent_term)"},
    {"Env.intern", "writes to the ambient env — fine inside a fork, global outside"},
    {"clear_registry", "bl test registry sweep — exact-env, but check intent"},
    {":persistent_term.put", "VM-global write"}
  ]

  @runtime_marks ["BeamLisp.Env", "BeamLisp.RT", "BeamLisp.Sandbox", "SpellCase", "eval_string"]

  @impl true
  def run(args) do
    dir = List.first(args) || "test"

    files =
      dir
      |> then(&Path.join(&1, "**/*_test.exs"))
      |> Path.wildcard()
      |> Enum.sort()

    if files == [], do: Mix.raise("no *_test.exs under #{dir}")

    rows = Enum.map(files, &audit/1)

    Enum.each(rows, fn {file, verdict, notes} ->
      Mix.shell().info("#{pad(verdict)} #{file}")
      for note <- notes, do: Mix.shell().info("           #{note}")
    end)

    counts = Enum.frequencies_by(rows, fn {_f, v, _n} -> v end)

    Mix.shell().info("")

    for verdict <- ["ADOPTS", "READY", "FLIPPABLE", "STAYS SYNC"] do
      Mix.shell().info("#{pad(verdict)} #{Map.get(counts, verdict, 0)}")
    end
  end

  defp audit(file) do
    src = File.read!(file)

    cond do
      src =~ "BeamLisp.ExUnitCase" ->
        {file, "ADOPTS", []}

      not Enum.any?(@runtime_marks, &String.contains?(src, &1)) ->
        {file, "READY", []}

      true ->
        notes =
          for {mark, why} <- @global_smells, String.contains?(src, mark) do
            "#{mark} — #{why}"
          end

        if src =~ "async: false" or notes != [] do
          {file, "STAYS SYNC", notes}
        else
          {file, "FLIPPABLE", []}
        end
    end
  end

  defp pad(s), do: String.pad_trailing(s, 10)
end
