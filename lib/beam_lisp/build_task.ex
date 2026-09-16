defmodule BeamLisp.BuildTask do
  @shortdoc "Compiles beam-lisp `.bl` sources into BEAM modules"

  @moduledoc """
  Ahead-of-time compiles beam-lisp source into real BEAM modules.

  This task is a SHELL. The build itself — planning the sources into
  dependency order and parallel waves, deciding what is fresh, compiling or
  fetching from the shared cache, writing the manifest — is `priv/build/build.bl`,
  a beam-lisp program (`build/run`). What lives here is only what MUST be
  Elixir: the `Mix.Task.Compiler` behaviour, flag parsing, the project's
  compile and manifest paths, seeding the bootstrap compiler before the
  language can run, and turning the result into the tuple Mix expects.

  ## Flags

      --source-dir DIR   build DIR instead of the configured source dirs
      --out DIR          beams AND manifest go to DIR (an isolated build; tests)
      --force            rebuild everything
      --jobs N           parallel width per wave (default: schedulers)

  ## Source directories

  `:beam_lisp, :source_dirs` in the project config (beam-lisp's own is the
  tiered `priv/{boot,std,lib}`), else `:source_dir`, else `bl/`. A missing
  directory is a no-op, so the compiler is safe in `Mix.compilers()` for a
  project that ships no `.bl`.

  ## Freshness

  The manifest maps each source to its per-source key (interface-keyed —
  see `priv/build/build-plan.bl` and docs/build/interface-keys.bl.md), the
  toolchain key, and the modules it produced. Byte-derived, never mtime.
  `mix clean` removes the manifest and every module it names.
  """


  @recursive true
  @manifest "compile.beam_lisp"

  @doc false
  def refresh_staged_build?(staged) when is_list(staged), do: "build" in staged

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [source_dir: :string, force: :boolean, out: :string, jobs: :integer]
      )

    source_dirs = if d = opts[:source_dir], do: [d], else: source_dirs_from_config()
    sources = discover(source_dirs)

    # `--out DIR` scopes the whole build to DIR — beams and manifest — so a
    # test that compiles a fixture set never touches the production code path.
    out = opts[:out] || BeamLisp.AOT.default_output_dir()

    manifest =
      if opts[:out],
        do: Path.join(out, @manifest),
        else: Path.join(manifest_dir(), @manifest)

    if opts[:out], do: File.mkdir_p!(out)

    if sources == [] do
      {:noop, []}
    else
      result =
        in_runtime(source_dirs, fn ->
          build_call("run", [
            %{
              sources: sources,
              out: out,
              manifest: manifest,
              force?: opts[:force] == true,
              jobs: opts[:jobs],
              log: fn msg -> IO.puts(msg) end
            }
          ])
        end)

      errors = result |> BeamLisp.RT.get(:errors) |> Enum.to_list()
      built = BeamLisp.RT.get(result, :built)

      cond do
        errors != [] ->
          Enum.each(errors, fn e -> IO.puts(:stderr, e) end)
          {:error, errors}

        built > 0 ->
          {:ok, []}

        true ->
          {:noop, []}
      end
    end
  end

  def clean,
    do: clean(BeamLisp.AOT.default_output_dir(), Path.join(manifest_dir(), @manifest))

  @doc "Remove the manifest at `out/compile.beam_lisp` and every module it names (isolated builds)."
  def clean(out) when is_binary(out), do: clean(out, Path.join(out, @manifest))

  defp clean(out, manifest) do
    if File.exists?(manifest), do: in_runtime([], fn -> build_call("clean", [out, manifest]) end)
    :ok
  end

  # Run `fun` with the language up, and leave the VM as it was found.
  #
  # The self-hosted compiler is a `.bl` namespace; on a fresh tree there is
  # no beam for it yet. The committed seed under priv/bootstrap/seed/ is
  # verified and installed into the production compile path BEFORE `boot/0`,
  # so the very first form compiles through it. `boot/0` starts `Env` and
  # `Loader.Server` (owners of the var table and the native/perf ETS tables)
  # and seeds core; the `build` namespace is then loaded — from its beam if
  # built, from source if not — and the build runs in the language.
  #
  # Whatever this task started, it stops: a Mix compile VM goes on to start
  # the application, which wants to own its own `Env`; a test's `on_exit`
  # must not leave a linked `Env` behind either.
  #
  # `source_dirs` — the roots being built — are registered as search paths for
  # the build's duration. Every emitted beam is stamped with its namespace's
  # closure key, and that key is folded over the require-closure RESOLVED BY
  # NAME: `blueprint.plan` requiring `blueprint.schema` must find the sibling
  # file. The emitter's own load path only holds the compiling file's
  # directory, so a `--source-dir` outside cwd (an application built from the
  # language's checkout) resolved its own siblings as "unresolvable" (`x:?`)
  # and stamped a key the runtime gate — which does see them — never matched.
  # Every beam then looked stale, and every load silently fell back to source:
  # the AOT path was a no-op for any app not living under cwd. Root cause of
  # `BEAM_LISP_PATH=<dir>` being needed for the build to be worth anything.
  defp in_runtime(source_dirs, fun) do
    env_was_running? = Process.whereis(BeamLisp.Env) != nil
    server_was_running? = Process.whereis(BeamLisp.Loader.Server) != nil

    # A consuming app must not receive its own copy of the bootstrap floor:
    # that copy can shadow a newer compiler already built in the dependency.
    compiler_path =
      if language_tree?(mix_project()[:app], source_dirs) do
        BeamLisp.AOT.default_output_dir()
      else
        case :code.lib_dir(:beam_lisp) do
          {:error, reason} -> raise "beam_lisp dependency is unavailable: #{inspect(reason)}"
          path -> Path.join(to_string(path), "ebin")
        end
      end

    BeamLisp.Bootstrap.install!(compiler_path)
    BeamLisp.AOT.boot()

    before = BeamLisp.Env.search_paths()
    added = source_dirs |> Enum.map(&Path.expand/1) |> Enum.reject(&(&1 in before))
    Enum.each(added, &BeamLisp.Env.add_search_path/1)

    try do
      fun.()
    after
      # Leave the env as found: a Mix compile VM goes on to start the app,
      # whose own configuration must not inherit a build-time root.
      Enum.each(added, &BeamLisp.Env.remove_search_path/1)
      if not env_was_running?, do: try_stop(BeamLisp.Env)
      if not server_was_running?, do: try_stop(BeamLisp.Loader.Server)
    end
  end

  # A var of the `build` namespace, loaded on demand. Through the var table
  # (not a module call) so it works whether `build` is AOT-built or read from
  # source — the compile task's own first run is the latter.
  defp build_call(name, args) do
    staged = Application.get_env(:beam_lisp, :bootstrap_staging, [])

    # The seed's build namespace is only a previous-generation bootstrap tool.
    # Keep the staged compiler available, but force build itself through the
    # loader's normal source fallback so scheduling changes take effect now.
    if name == "run" and refresh_staged_build?(staged) do
      Application.put_env(:beam_lisp, :bootstrap_staging, List.delete(staged, "build"))
    end

    BeamLisp.Loader.ensure_loaded("build")
    BeamLisp.RT.invoke(BeamLisp.Env.fetch!("build", name), args)
  end

  # Every source the loader would load: plain `.bl` plus literate `.bl.md` /
  # `.bl.org` documents (their code cells are the program).
  defp discover(source_dirs) do
    exts = BeamLisp.Loader.doc_extensions()

    source_dirs
    |> List.wrap()
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn dir ->
      Enum.flat_map(exts, &Path.wildcard(Path.join(dir, "**/*" <> &1)))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp source_dirs_from_config do
    project_config = mix_project()[:beam_lisp] || []

    configured =
      project_config[:source_dirs] || project_config[:source_dir] ||
        Application.get_env(:beam_lisp, :source_dirs) ||
        Application.get_env(:beam_lisp, :source_dir, "bl")

    List.wrap(configured)
  end

  # A Mix PROJECT is loaded exactly when Mix's project stack is running — which
  # is the guard Mix's own code uses, and the only one that is TRUE.
  #
  # `Code.ensure_loaded?(Mix)` is not the question and never was: Mix ships with
  # Elixir, so it is loadable in every VM a checkout runs — while
  # `Mix.Project.config/0` then EXITS with `GenServer.call(Mix.ProjectStack, …):
  # no process`. Measured in a plain `elixir` VM, which is where `bl build` and
  # CI run. With `mix.exs` deleted there is no project stack in this repository
  # at all, so this answers `[]` and every caller falls through to its declared
  # default.
  defp mix_project do
    if Process.whereis(Mix.ProjectStack), do: Mix.Project.config(), else: []
  end

  # Whether the tree being built IS the language, rather than an application that
  # depends on it.
  #
  # Mix answered this from the project config (`[:app] == :beam_lisp`). With no
  # Mix project the question is put to the TREE, where the answer lives anyway:
  # only the language's own checkout carries the codegen sources, and a consumer
  # application that happens to be named `beam_lisp` would still have no boot
  # tier to install. Getting this wrong is not cosmetic — the `else` branch
  # installs the floor into the DEPENDENCY's ebin instead of the tree's, and the
  # comment below records what that protects against.
  defp language_tree?(app, source_dirs) do
    app == :beam_lisp or
      Enum.any?(List.wrap(source_dirs), fn d -> File.exists?(Path.join(d, "compiler.bl")) end)
  end

  # `GenServer.stop/1` rather than `Process.exit/2`: these servers own ETS
  # tables that must be torn down cleanly.
  defp try_stop(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _ -> :ok
  end

  # Where this build keeps its state: beside the output directory. It used to be
  # Mix's manifest directory when a Mix project was loaded; with no Mix project
  # there is nothing to ask, and a build's state still has to live where the
  # build can find it (the `Process.whereis` guard, not `ensure_loaded?`, is what
  # makes that question answerable — see `mix_project/0`).
  defp manifest_dir do
    if Process.whereis(Mix.ProjectStack) do
      Mix.Project.manifest_path()
    else
      Path.join(BeamLisp.AOT.default_output_dir(), ".beam_lisp")
    end
  end
end
