defmodule Mix.Tasks.BeamLisp.Reload.Monitor do
  @shortdoc "Watch .bl files and print the live reload image as it changes"

  @moduledoc """
  A live terminal monitor for the coherent reload loop.

      mix beam_lisp.reload.monitor DIR [--path PRELUDE_DIR ...]

  Starts a filesystem watcher over `DIR`: every `.bl` save is staged and
  committed through `reload` (the coherent, namespace-level loop), and after each
  commit the current live image is re-rendered to the terminal — the namespaces
  in the running system, their vars, and the reload journal (what applied, what
  was held and why). Edit a file and watch the image change, or watch a bad edit
  be held with its reason while the old code keeps serving.

  This is the CLI half of monitorability; the web half (`reload.monitor/render-view`
  over a socket) renders the same `reload/inspect` read-model, so terminal and
  browser never disagree about what the running system is doing.

  Ctrl-C to stop.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, args} =
      OptionParser.parse!(argv, strict: [path: :keep], aliases: [p: :path])

    for {:path, dir} <- opts, do: BeamLisp.Env.add_search_path(dir)

    dir =
      case args do
        [d] -> d
        _ -> Mix.raise("usage: mix beam_lisp.reload.monitor DIR [--path PRELUDE_DIR ...]")
      end

    unless File.dir?(dir), do: Mix.raise("not a directory: #{dir}")

    BeamLisp.init()
    BeamLisp.Loader.ensure_loaded("reload")
    BeamLisp.Loader.ensure_loaded("reload.monitor")

    # Re-render the whole image after every commit the watcher drives. The
    # watcher calls this 1-arg fn with each commit's status map; we ignore the
    # per-commit status and pull a fresh full snapshot, so a hold and the
    # namespaces it did NOT change are shown together — one coherent frame.
    on_result = fn _status -> render() end

    {:ok, _pid} =
      BeamLisp.ReloadWatcher.start_link(
        dirs: [dir],
        auto_commit: true,
        on_result: on_result
      )

    IO.puts(IO.ANSI.clear() <> IO.ANSI.home())
    IO.puts("beam-lisp reload monitor — watching #{dir}/  (Ctrl-C to stop)\n")
    render()

    # Park forever; the watcher runs in its own process and drives the renders.
    Process.sleep(:infinity)
  end

  # Pull a fresh snapshot and paint it, clearing the screen so each frame
  # replaces the last — a live dashboard, not a scrolling log.
  defp render do
    text = BeamLisp.eval("(reload.monitor/render-text (reload/inspect))")
    IO.puts(IO.ANSI.clear() <> IO.ANSI.home() <> text)
  end
end
