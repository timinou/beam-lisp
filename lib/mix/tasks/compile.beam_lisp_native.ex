defmodule Mix.Tasks.Compile.BeamLispNative do
  @shortdoc "Builds native (cargo) artefacts (delegates to BeamLisp.NativeTask)"

  @moduledoc """
  Superseded by the `.bl` native stage in `priv/build/build.bl`; this shell delegates until W10 removes it.

  This shell is EMPTY on purpose: the behaviour lives in `BeamLisp.NativeTask`, which needs no
  Mix. It exists so `mix compile` keeps working during the cutover and dies with
  `mix.exs` in W10 — a delegate, not a second implementation.
  """

  use Mix.Task.Compiler

  @impl Mix.Task.Compiler
  def run(argv), do: BeamLisp.NativeTask.run(argv)

  defdelegate run(a0), to: BeamLisp.NativeTask
  defdelegate installed_path(a0), to: BeamLisp.NativeTask
  defdelegate nif_ext(), to: BeamLisp.NativeTask
end
