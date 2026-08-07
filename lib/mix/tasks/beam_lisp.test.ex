defmodule Mix.Tasks.BeamLisp.Test do
  @moduledoc """
  Run beam-lisp's self-hosted test suite: `mix beam_lisp.test [PATH]`.

  Loads the prelude and the `priv/test.bl` library, then every
  `test/**/*.bl` (or the given path), runs the registered tests via
  `BeamLisp.TestRT.run_suite/1`, prints the clojure.test-shaped
  summary, and exits non-zero when anything failed.
  """

  @shortdoc "Run the beam-lisp test suite"

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    paths =
      case args do
        [] ->
          # Fixtures are compiler inputs, not test suites: only
          # test/bl (and anything else outside fixtures) is a suite.
          "test/**/*.bl"
          |> Path.wildcard()
          |> Enum.reject(&String.starts_with?(&1, "test/fixtures/"))

        [path] when is_binary(path) ->
          cond do
            File.dir?(path) -> Path.wildcard(Path.join(path, "**/*.bl"))
            File.regular?(path) -> [path]
            true -> Mix.raise("no such beam-lisp test file: #{path}")
          end

        _ ->
          Mix.raise("usage: mix beam_lisp.test [FILE.bl | DIR]")
      end

    if paths == [], do: Mix.raise("no beam-lisp test files found")

    BeamLisp.TestRT.cli(paths)
  end
end
