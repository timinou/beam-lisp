defmodule Mix.Tasks.Compile.BeamLisp do
  @shortdoc "Compiles beam-lisp `.bl` sources into BEAM modules"

  @moduledoc """
  Ahead-of-time compiles beam-lisp source into real BEAM modules.

  This task is a SHELL. The build itself — planning the sources into
  dependency order and parallel waves, deciding what is fresh, compiling or
  fetching from the shared cache, writing the manifest — is `priv/boot/build.bl`,
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
  see `priv/boot/build-plan.bl` and docs/build/interface-keys.bl.md), the
  toolchain key, and the modules it produced. Byte-derived, never mtime.
  `mix clean` removes the manifest and every module it names.
  """

  use Mix.Task.Compiler

  @recursive true
  @manifest "compile.beam_lisp"

  @impl Mix.Task.Compiler
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [source_dir: :string, force: :boolean, out: :string, jobs: :integer]
      )

    source_dirs = if d = opts[:source_dir], do: [d], else: source_dirs_from_config()
    sources = discover(source_dirs)

    # `--out DIR` scopes the whole build to DIR — beams and manifest — so a
    # test that compiles a fixture set never touches the production code path.
    out = opts[:out] || Mix.Project.compile_path()
    manifest = if opts[:out], do: Path.join(out, @manifest), else: Path.join(Mix.Project.manifest_path(), @manifest)
    if opts[:out], do: File.mkdir_p!(out)

    if sources == [] do
      {:noop, []}
    else
      result =
        in_runtime(fn ->
          build_call("run", [
            %{
              sources: sources,
              out: out,
              manifest: manifest,
              force?: opts[:force] == true,
              jobs: opts[:jobs],
              log: fn msg -> Mix.shell().info(msg) end
            }
          ])
        end)

      errors = result |> BeamLisp.RT.get(:errors) |> Enum.to_list()
      built = BeamLisp.RT.get(result, :built)

      cond do
        errors != [] ->
          Enum.each(errors, fn e -> Mix.shell().error(e) end)
          {:error, errors}

        built > 0 ->
          {:ok, []}

        true ->
          {:noop, []}
      end
    end
  end

  @impl Mix.Task.Compiler
  def clean, do: clean(Mix.Project.compile_path(), Path.join(Mix.Project.manifest_path(), @manifest))

  @doc "Remove the manifest at `out/compile.beam_lisp` and every module it names (isolated builds)."
  def clean(out) when is_binary(out), do: clean(out, Path.join(out, @manifest))

  defp clean(out, manifest) do
    if File.exists?(manifest), do: in_runtime(fn -> build_call("clean", [out, manifest]) end)
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
  defp in_runtime(fun) do
    env_was_running? = Process.whereis(BeamLisp.Env) != nil
    server_was_running? = Process.whereis(BeamLisp.Loader.Server) != nil

    BeamLisp.Bootstrap.install!(Mix.Project.compile_path())
    BeamLisp.AOT.boot()

    try do
      fun.()
    after
      if not env_was_running?, do: try_stop(BeamLisp.Env)
      if not server_was_running?, do: try_stop(BeamLisp.Loader.Server)
    end
  end

  # A var of the `build` namespace, loaded on demand. Through the var table
  # (not a module call) so it works whether `build` is AOT-built or read from
  # source — the compile task's own first run is the latter.
  defp build_call(name, args) do
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
    |> Enum.flat_map(fn dir -> Enum.flat_map(exts, &Path.wildcard(Path.join(dir, "**/*" <> &1))) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp source_dirs_from_config do
    project_config = Mix.Project.config()[:beam_lisp] || []

    configured =
      project_config[:source_dirs] || project_config[:source_dir] ||
        Application.get_env(:beam_lisp, :source_dirs) ||
        Application.get_env(:beam_lisp, :source_dir, "bl")

    List.wrap(configured)
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
end
