defmodule Mix.Tasks.Bl do
  @shortdoc "The beam-lisp CLI: mix bl ARGS… ≡ bl ARGS…"

  @moduledoc """
  `mix bl` is the beam-lisp CLI inside a Mix project: the same commands,
  flags and exit codes as the shipped `bl` binary.

      mix bl run examples/hello.bl
      mix bl test test/bl
      mix bl help

  One runtime task replaces the old per-verb `mix beam_lisp.*` tasks. It
  starts the application, loads `bl.cli`, and calls its `run-argv` — the same
  entry point the daemon and the drop launcher use, so behavior cannot drift
  between them.

  `--code-path DIR` (or the colon-separated `BEAM_LISP_CODE_PATH`) puts a
  directory of AOT beams on the VM code path. The flag adds the directory
  after Mix prunes the code path down to the project's dependencies, so it
  reaches the program even though a `-pa` handed to the VM does not.

  With no arguments `mix bl` starts the repl.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    BeamLisp.Loader.ensure_loaded("bl.cli")
    code = BeamLisp.RT.invoke(BeamLisp.Env.fetch!("bl.cli", "run-argv"), [argv])

    if code != 0, do: exit({:shutdown, code})
    :ok
  end
end
