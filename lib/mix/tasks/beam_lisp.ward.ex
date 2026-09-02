defmodule Mix.Tasks.BeamLisp.Ward do
  @shortdoc "Run .bl test files in a warm, isolated, coherence-guarded runner"

  @moduledoc """
  A pure-beam-lisp test runner built on the coherent-reload machinery.

      mix beam_lisp.ward FILE.bl [FILE.bl ...] [--path DIR ...]

  Each file runs in its OWN isolated env fork off a warm base:

    * ISOLATED   — a file's defs and state live in its fork, destroyed on exit;
      no shared mutable singleton for one file to tear down under another, so the
      "application shutdown" cross-file contamination is not representable.
    * COHERENCE-GATED — a file is statically checked (dangling refs, promises,
      types) before it runs; a broken file is reported, never crashes the run.
    * CRASH-CONTAINED — a top-level throw at load time is caught in the fork; the
      file is reported and the runner moves on.
    * ALWAYS-LATEST — the file's SOURCE is read fresh and evaluated; no compiled
      beam is consulted, so a stale-beam green run is impossible.
    * WARM — the test library loads once into a warm base; each file forks off it.

  Exits non-zero unless every file is green (passed, and none failed or
  incoherent) — the shape a CI gate reads.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, files} =
      OptionParser.parse!(argv, strict: [path: :keep], aliases: [p: :path])

    for {:path, dir} <- opts, do: BeamLisp.Env.add_search_path(dir)

    if files == [], do: Mix.raise("usage: mix beam_lisp.ward FILE.bl [FILE.bl ...]")

    BeamLisp.init()

    # The test library into core, exactly as the stock bl runner does, so
    # `deftest`/`is`/`run-tests` resolve inside every fork via the core fallback.
    BeamLisp.Compiler.eval_string(
      File.read!(Application.app_dir(:beam_lisp, "priv/std/test.bl")),
      BeamLisp.Compiler.new_env("core")
    )

    BeamLisp.Loader.ensure_loaded("reload")
    BeamLisp.Loader.ensure_loaded("reload.ward")

    # Bind the file sources into a var ward can read, then run + report in bl.
    sources = Enum.map(files, &File.read!/1)
    BeamLisp.Env.intern("user", "__ward_sources__", sources)

    result =
      BeamLisp.eval("""
      (let [r (reload.ward/run (BeamLisp.Env/fetch! "user" "__ward_sources__"))]
        (println (reload.ward/report r))
        (:ok? r))
      """)

    unless result, do: exit({:shutdown, 1})
  end
end
