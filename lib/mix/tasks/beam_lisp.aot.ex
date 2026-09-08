defmodule Mix.Tasks.BeamLisp.Aot do
  @shortdoc "AOT-compile a directory of `.bl` sources into an output directory"

  @moduledoc """
  Build an application's `.bl` tree ahead of time, outside the project's own
  compile path:

      mix beam_lisp.aot --source-dir ../app/src --out ../app/_build/bl [--force] [--jobs N]

  Then put `--out` on the code path (`ERL_AFLAGS="-pa ../app/_build/bl"`) and
  every `require` of one of those namespaces loads its beam instead of
  compiling its source — the difference between a 50s and a 2s VM start for
  a ninety-namespace application.

  Why a separate task: `compile.beam_lisp` is a `Mix.Task.Compiler` listed in
  this project's `Mix.compilers()`. Invoking it from the command line runs the
  project's `compile` first, which runs `compile.beam_lisp` over `priv/` and
  marks it done — so the explicit invocation, flags and all, was a silent
  `:noop` and nothing was written. This task is the same build (it delegates
  to `Mix.Tasks.Compile.BeamLisp.run/1`), re-enabled and run once with the
  caller's flags. Incremental by the same byte-keyed manifest.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [source_dir: :string, out: :string, force: :boolean, jobs: :integer])

    unless opts[:source_dir] && opts[:out],
      do: Mix.raise("usage: mix beam_lisp.aot --source-dir DIR --out DIR [--force] [--jobs N]")

    Mix.Task.run("compile")
    Mix.Task.reenable("compile.beam_lisp")

    case Mix.Task.run("compile.beam_lisp", args) do
      {:ok, _} -> Mix.shell().info("beam-lisp AOT: #{opts[:out]} up to date")
      {:noop, _} -> :ok
      {:error, errors} -> Mix.raise("beam-lisp AOT: #{length(errors)} error(s)")
    end
  end
end
