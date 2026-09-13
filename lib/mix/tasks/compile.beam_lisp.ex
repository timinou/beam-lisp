defmodule Mix.Tasks.Compile.BeamLisp do
  @shortdoc "Compiles beam-lisp `.bl` sources (delegates to BeamLisp.BuildTask)"

  @moduledoc """
  The `.bl` build driver's decisions live in `priv/build/build.bl`; the Elixir side parses flags and shapes results.

  This shell is EMPTY on purpose: the behaviour lives in `BeamLisp.BuildTask`, which needs no
  Mix. It exists so `mix compile` keeps working during the cutover and dies with
  `mix.exs` in W10 — a delegate, not a second implementation.
  """

  use Mix.Task.Compiler

  @impl Mix.Task.Compiler
  def run(argv), do: BeamLisp.BuildTask.run(argv)

  defdelegate refresh_staged_build?(a0), to: BeamLisp.BuildTask
  defdelegate run(a0), to: BeamLisp.BuildTask
  defdelegate clean(), to: BeamLisp.BuildTask
  defdelegate clean(a0), to: BeamLisp.BuildTask
end
