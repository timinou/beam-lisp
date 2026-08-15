defmodule Mix.Tasks.BeamLisp.Test do
  @moduledoc """
  Run beam-lisp's self-hosted test suite: `mix beam_lisp.test [PATH]`.

  Loads the prelude and the `priv/test.bl` library, then every
  `test/**/*.bl` (or the given path), runs the registered tests via
  `BeamLisp.TestRT.run_suite/1`, prints the clojure.test-shaped
  summary, and exits non-zero when anything failed.

  `--path DIR` adds a library root to the loader's search path (repeatable),
  as does the `BEAM_LISP_PATH` environment variable. A suite otherwise only
  sees its OWN directory, cwd and `priv/` — so a library living anywhere else
  (`spell/src`) could not be required from a test at all.
  """

  @shortdoc "Run the beam-lisp test suite"

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, args} = OptionParser.parse!(args, strict: [path: :keep], aliases: [p: :path])
    for {:path, dir} <- opts, do: BeamLisp.Env.add_search_path(dir)

    # `spell/src` is this repo's own library root, so a suite requiring
    # `spell.machine` resolves without every invocation repeating `--path`.
    # Added only when it exists, so the task stays correct in a checkout
    # that does not carry spell/. An explicit --path still outranks it:
    # add_search_path preserves insertion order.
    if File.dir?(BeamLisp.Spell.src_path()), do: BeamLisp.Env.add_search_path(BeamLisp.Spell.src_path())

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
