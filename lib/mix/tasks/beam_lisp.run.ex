defmodule Mix.Tasks.BeamLisp.Run do
  @moduledoc "Run a beam-lisp file: `mix beam_lisp.run examples/hello.bl`"
  @shortdoc "Run a beam-lisp file"

  use Mix.Task

  @impl true
  def run([path]) do
    Mix.Task.run("app.start")
    path |> BeamLisp.run_file() |> BeamLisp.RT.print_str() |> IO.puts()
  end

  def run(_args) do
    Mix.raise("usage: mix beam_lisp.run FILE.bl")
  end
end
