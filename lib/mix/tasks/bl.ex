defmodule Mix.Tasks.Bl do
  @shortdoc "The beam-lisp CLI: mix bl ARGS… ≡ bl ARGS…"

  @moduledoc """
  `mix bl` is the beam-lisp CLI inside a Mix project: the same commands,
  flags and exit codes as the shipped `bl` binary.

      mix bl run examples/hello.bl
      mix bl test test/bl
      mix bl help

  One runtime task carries every verb. It
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

    # Optional code paths the CALLER wants visible to the run (a precompiled
    # NIF binding such as librarium's xberg_rt, a prebuilt ebin). They must be
    # added AFTER app.start: mix prunes the code path to the project's own
    # deps when the app starts, so -pa / ERL_LIBS given at VM boot are gone by
    # the time any .bl code runs. Same variable and format (colon-separated
    # ebin dirs) the apps' run-bl.sh scripts already use.
    (System.get_env("BL_EXTRA_PATHS") || "")
    |> String.split(":", trim: true)
    |> Enum.each(&Code.prepend_path/1)

    BeamLisp.Loader.ensure_loaded("bl.cli")
    code = BeamLisp.RT.invoke(BeamLisp.Env.fetch!("bl.cli", "run-argv"), [argv])

    if code != 0, do: exit({:shutdown, code})
    :ok
  end
end
