defmodule Mix.Tasks.Compile.BeamLisp do
  @shortdoc "Compiles beam-lisp `.bl` sources into BEAM modules"

  @moduledoc """
  Ahead-of-time compiles beam-lisp source into real BEAM modules.

  `mix compile.beam_lisp` treats every `.bl` file under a source
  directory as a build input: each one is driven through the
  reader/compiler pipeline and every namespace it defines is emitted as
  a `.beam` file on the app's code path. A fresh VM then loads those
  modules from disk with no runtime compilation (see `BeamLisp.AOT`).

  ## Source directory

  Defaults to `bl/` at the project root. Override with the
  `:source_dir` flag or the `:beam_lisp, :source_dir` application
  config:

      mix compile.beam_lisp --source-dir test/fixtures/aot

      config :beam_lisp, source_dir: "bl"

  If the directory does not exist the task is a no-op, so it is safe to
  wire into `Mix.compilers()` even when a project ships no `.bl`
  sources.

  ## Incremental + clean

  The task keeps a content-hash manifest under
  `Mix.Project.manifest_path()/compile.beam_lisp` mapping each source to
  its modules. A source is recompiled only when its content hash
  changes; `--force` recompiles everything. `mix clean` removes the
  manifest and every generated module.

  ## Compilation order

  Sources are compiled in `ns :require` dependency order (required files
  first), so a required file's functions *and macros* are available when
  the requiring file compiles. A require cycle among the sources is
  reported as an error.
  """

  use Mix.Task.Compiler

  @recursive true
  @manifest "compile.beam_lisp"

  @impl Mix.Task.Compiler
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [source_dir: :string, force: :boolean, out: :string]
      )

    source_dirs = if d = opts[:source_dir], do: [d], else: source_dirs_from_config()

    # `--out DIR` scopes the WHOLE build to an isolated directory: beams land
    # in DIR and the manifest lives at DIR/compile.beam_lisp, decoupled from
    # the production `Mix.Project.compile_path()` + `manifest_path()`. Without
    # it a test that compiles a fixture set (`--source-dir test/fixtures/aot`)
    # would `clean` and rebuild INTO the shared code path -- deleting the real
    # AOT beams every other test depends on and leaving a fixture-only
    # manifest, so the next `mix test` recompiled all sources from scratch.
    # An isolated build never touches the production tree.
    compile_path = opts[:out] || Mix.Project.compile_path()

    manifest_path =
      if out = opts[:out],
        do: Path.join(out, @manifest),
        else: Path.join(Mix.Project.manifest_path(), @manifest)

    if opts[:out], do: File.mkdir_p!(opts[:out])

    cond do
      not Enum.any?(source_dirs, &File.dir?/1) ->
        {:noop, []}

      discover(source_dirs) == [] ->
        {:noop, []}

      true ->
        # THE RUNTIME FIRST. Reading a `.bl` file is not a pure parse: the
        # reader consults a table of reader macros (`@x` → `(deref x)` among
        # them), and that table is created by `BeamLisp.init/0`. Without it
        # the very first `@` in a source fails with "the table identifier
        # does not refer to an existing ETS table" — a message that names
        # `:beam_lisp_vars` and says nothing about the missing init.
        #
        # It surfaced only when a project whose sources use `@` wired this
        # task in: the fixtures under `test/fixtures/aot` do not, so the task
        # had never needed the runtime it was reading with. Idempotent, so
        # calling it here costs nothing when something already has.
        #
        # Note whether the runtime was ALREADY up, because Mix runs
        # compilers in the same VM that later starts the application — and
        # the application starts `BeamLisp.Env` under its own supervisor.
        # An `Env` left running by this task made that fail with "already
        # started", so `mix test` died before a single test ran in a
        # project whose code was perfectly fine. Cleaned up below.
        env_was_running? = Process.whereis(BeamLisp.Env) != nil
        BeamLisp.init()

        sources = discover(source_dirs)
        manifest = read_manifest(manifest_path)
        {ordered, deps} = order_and_deps(sources)

        hashes = Map.new(ordered, fn path -> {path, content_hash(path)} end)

        cache_key =
          if BeamLisp.AOTCache.enabled?() and opts[:force] != true do
            BeamLisp.AOTCache.compiler_key()
          end

        # How many sources actually need building this run. On a warm tree
        # this is 0 (everything up to date); on a COLD build it is every
        # source, and a cold build of the full prelude is hundreds of
        # namespaces taking tens of minutes. Without a running count the
        # cold build looks like a silent hang, so we print `[n/total] path`
        # as each source compiles — the difference between "stuck" and
        # "working through 400 files". Counted up front so the total is known.
        to_build =
          Enum.count(ordered, fn path ->
            opts[:force] || not up_to_date?(manifest, path, Map.fetch!(hashes, path), compile_path)
          end)

        if to_build > 0 do
          Mix.shell().info("beam-lisp AOT: building #{to_build} source(s)")
        end

        {manifest, recompiled, errors, _built} =
          Enum.reduce(ordered, {manifest, false, [], 0}, fn path, {m, rc, errs, built} ->
            hash = Map.fetch!(hashes, path)

            if opts[:force] || not up_to_date?(m, path, hash, compile_path) do
              built = built + 1
              Mix.shell().info("  [#{built}/#{to_build}] #{Path.relative_to_cwd(path)}")
              closure_key =
                if cache_key, do: BeamLisp.AOTCache.closure_key(path, deps, hashes)

              cached =
                if closure_key do
                  BeamLisp.AOTCache.fetch(cache_key, closure_key, compile_path)
                end

              result =
                case cached do
                  {:ok, modules} ->
                    # A fetch evaluates nothing; run each namespace's init
                    # hook so value defs are interned as a fresh compile
                    # would have interned them.
                    BeamLisp.AOTCache.run_init_modules(modules, compile_path)
                    {:ok, modules}

                  _ ->
                    compile_file(path, compile_path)
                end

              case result do
                {:ok, modules} ->
                  # Delete beams this source used to emit but no longer does.
                  # A namespace emits one namespace module plus one body module
                  # per var and a value/macro companion — all deterministically
                  # named. When a var is removed or renamed its body beam would
                  # otherwise linger on the code path, outside the new manifest
                  # and so invisible to `clean`. Remove `old -- new` on every
                  # recompile so the on-disk module set exactly matches what the
                  # source now defines.
                  old_modules = (m[path] || %{}) |> Map.get(:modules, [])
                  Enum.each(old_modules -- modules, &delete_beam(&1, compile_path))

                  m2 = Map.put(m, path, %{hash: hash, modules: modules})
                  # Checkpoint the manifest after each successful source. The
                  # build writes beams to ebin incrementally, but this manifest
                  # was historically persisted only after the whole reduce
                  # finished -- so an interrupted cold build (timeout/kill) left
                  # a populated ebin with NO manifest. The next run then saw a
                  # partial beam set (shims whose body modules were not emitted
                  # yet -> UndefinedFunctionError at test time) and, finding no
                  # manifest, recompiled every source from scratch with no
                  # resume. Persisting per source makes the cold build resumable
                  # and keeps manifest and ebin in step at every observable point.
                  write_manifest(manifest_path, m2)

                  # Publish freshly compiled beams; cache hits and failed
                  # stores alike fall through to the normal flow.
                  if closure_key != nil and not match?({:ok, _}, cached) do
                    BeamLisp.AOTCache.store(cache_key, closure_key, compile_path, modules)
                  end

                  {m2, true, errs, built}

                {:error, err} ->
                  {m, rc, [err | errs], built}
              end
            else
              {m, rc, errs, built}
            end
          end)

        # Drop manifest entries for sources that disappeared and remove
        # their generated beams. split_with returns lists of {path, meta}
        # pairs, so fold the survivors back into a map for storage.
        {kept, stale} = Enum.split_with(manifest, fn {path, _} -> path in sources end)

        Enum.each(stale, fn {_path, %{modules: mods}} ->
          Enum.each(mods, &delete_beam(&1, compile_path))
        end)

        write_manifest(manifest_path, Map.new(kept))

        # Leave the VM as we found it. Only if WE started it — a project
        # that had `Env` running before this task is entitled to keep it.
        if not env_was_running?, do: stop_env()
        stop_loader_server()

        cond do
          errors != [] -> {:error, Enum.reverse(errors)}
          recompiled -> {:ok, []}
          true -> {:noop, []}
        end
    end
  end

  @impl Mix.Task.Compiler
  def clean, do: clean_at(Mix.Project.compile_path(), Path.join(Mix.Project.manifest_path(), @manifest))

  @doc """
  Clean an isolated build produced with `run([\"--out\", dir])`. Removes every
  beam the manifest recorded plus the manifest itself, scoped to `dir` — the
  shared production code path is never touched. Used by tests that compile a
  fixture set into a throwaway directory.
  """
  def clean(out) when is_binary(out), do: clean_at(out, Path.join(out, @manifest))

  defp clean_at(compile_path, manifest_path) do
    if File.exists?(manifest_path) do
      manifest_path
      |> read_manifest()
      |> Map.values()
      |> Enum.each(fn %{modules: mods} ->
        Enum.each(mods, &delete_beam(&1, compile_path))
      end)

      File.rm(manifest_path)
    end

    :ok
  end

  # --- discovery ---

  # THE PROJECT BEING COMPILED, not the application environment.
  #
  # This task is `@recursive`, so it runs once per project in the tree — the
  # dep and the app that depends on it. `Application.get_env/3` reads ONE
  # global, so the top app's `config :beam_lisp, source_dir: "src"` was the
  # answer given while compiling `beam_lisp` ITSELF, whose sources are in
  # `priv/`. The dep found no `src/`, no-op'd, and emitted nothing; the
  # failure surfaced much later and elsewhere, as a `datom` module missing
  # from the code path at runtime.
  #
  # `Mix.Project.config/1` is per-project and follows the recursion, so each
  # project answers for itself. The application env stays as a fallback —
  # for a project that sets it and has no `:beam_lisp` project key — but the
  # project key wins, which is what makes an umbrella correct.
  # A LIST, because one project can own more than one tree of `.bl`. This
  # library ships two — `priv/` (core, datom) and `spell/src` (the
  # contract/view stack) — and a consumer that AOT-compiles a namespace
  # requiring `spell.contract` needs both on the path or the compile fails
  # with "namespace not found: spell.contract".
  #
  # `:source_dir` still accepts a single string, which is what every
  # existing config passes.
  defp source_dirs_from_config do
    project_config = Mix.Project.config()[:beam_lisp] || []

    configured =
      project_config[:source_dirs] || project_config[:source_dir] ||
        Application.get_env(:beam_lisp, :source_dirs) ||
        Application.get_env(:beam_lisp, :source_dir, "bl")

    List.wrap(configured)
  end

  # Stop the `Env` this task started, so the application can start its own.
  # `GenServer.stop/1` rather than `Process.exit/2`: the registry owns ETS
  # tables, and an orderly terminate releases them.
  defp stop_env do
    case Process.whereis(BeamLisp.Env) do
      nil -> :ok
      pid -> try_stop(pid)
    end
  end

  defp try_stop(pid) do
    GenServer.stop(pid, :normal, 5_000)
  catch
    # Already gone, or refusing to stop. Neither is worth failing a
    # compile over — the next `init/0` is idempotent either way.
    _, _ -> :ok
  end

  # Same discipline as stop_env/0: a Loader.Server started on demand by a
  # compile-time library load would otherwise block the application's own
  # supervisor child with "already started".
  defp stop_loader_server do
    case Process.whereis(BeamLisp.Loader.Server) do
      nil -> :ok
      pid -> try_stop(pid)
    end
  end

  defp discover(source_dirs) do
    source_dirs
    |> List.wrap()
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.bl")))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # --- manifest ---

  # %{source_path => %{hash: sha256hex, modules: [module_atom]}}
  defp read_manifest(path) do
    case File.read(path) do
      {:ok, bin} when bin != <<>> ->
        case :erlang.binary_to_term(bin) do
          # is_map-ok: this term came off disk via binary_to_term, not from
          # user code -- it is the build manifest, a plain Elixir map, and a
          # beam-lisp struct can never appear here.
          term when is_map(term) -> term
          # A corrupt or truncated manifest is treated as empty rather
          # than letting a bad term self-perpetuate.
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp write_manifest(path, manifest) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(manifest))
  end

  defp content_hash(source), do: source |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16()

  defp up_to_date?(manifest, path, hash, compile_path) do
    case manifest[path] do
      %{hash: ^hash, modules: mods} ->
        Enum.all?(mods, &File.exists?(Path.join(compile_path, Atom.to_string(&1) <> ".beam")))

      _ ->
        false
    end
  end

  # --- compilation ---

  defp compile_file(path, compile_path) do
    try do
      mods = BeamLisp.AOT.compile_file(path, output_dir: compile_path)
      {:ok, Enum.map(mods, &elem(&1, 0))}
    rescue
      e ->
        # PRINT IT HERE. These strings are returned to `Mix.Task.Compiler`,
        # which renders `%Diagnostic{}` structs and quietly discards plain
        # strings — so a failing AOT compile printed "Generated beam_lisp
        # app" followed by mix's generic "could not compile dependency"
        # and NOTHING about which file or why. Two real bugs hid behind
        # that for an hour. The return value stays as it was, so the task
        # still fails; this only makes the reason visible.
        message = "beam-lisp AOT: #{path}: " <> Exception.message(e)
        Mix.shell().error(message)
        {:error, message}
    end
  end

  defp delete_beam(mod, compile_path) do
    path = Path.join(compile_path, Atom.to_string(mod) <> ".beam")
    if File.exists?(path), do: File.rm(path)
  end

  # --- require ordering ---

  # Compile sources in dependency order: a source's `ns :require`
  # targets that are themselves sources must compile first. Returns the
  # list in compile order plus the resolved path → required-paths map
  # (the AOT cache keys on the transitive closure), or raises on a cycle.
  defp order_and_deps(sources) do
    # primary ns and require targets per source
    info =
      Enum.map(sources, fn path ->
        forms = BeamLisp.Reader.read_all(File.read!(path))
        {primary_ns(forms), requires(forms), path}
      end)

    # ns -> source path, for require targets that are among the sources
    ns_to_path = Map.new(info, fn {ns, _reqs, path} -> {ns, path} end)

    deps =
      Map.new(info, fn {_ns, reqs, path} ->
        {path, reqs |> Enum.map(&Map.get(ns_to_path, &1)) |> Enum.reject(&is_nil/1) |> Enum.uniq()}
      end)

    visited = MapSet.new()
    stack = MapSet.new()

    {ordered, _} =
      Enum.reduce(sources, {[], {visited, stack}}, fn path, {acc, vs} ->
        {sub, vs} = visit(path, deps, vs)
        {acc ++ sub, vs}
      end)

    {ordered, deps}
  end

  defp visit(path, deps, vs) do
    {visited, stack} = vs

    cond do
      MapSet.member?(stack, path) ->
        raise "beam-lisp AOT: require cycle involving #{path}"

      MapSet.member?(visited, path) ->
        {[], vs}

      true ->
        # `path` is in progress while we walk its deps, so a cycle
        # back to it is detected by the stack membership test above.
        {sub, {visited, stack}} =
          Enum.reduce(
            Map.get(deps, path, []),
            {[], {visited, MapSet.put(stack, path)}},
            fn dep, {acc, vs} ->
              {s, vs} = visit(dep, deps, vs)
              {acc ++ s, vs}
            end
          )

        visited = MapSet.put(visited, path)
        stack = MapSet.delete(stack, path)
        {sub ++ [path], {visited, stack}}
    end
  end

  # The first `(ns name ...)` form names the source's namespace (nil if
  # none — such a file lands in `user`).
  defp primary_ns(forms) do
    Enum.find_value(forms, nil, fn
      {:list, [{:symbol, "ns"}, {:symbol, name} | _]} -> name
      _ -> nil
    end)
  end

  # Namespaces required via `(:require [other.ns ...])` / `other.ns`.
  defp requires(forms) do
    Enum.flat_map(forms, fn
      {:list, [{:symbol, "ns"}, _name | clauses]} ->
        Enum.flat_map(clauses, fn
          {:list, [{:keyword, "require"} | specs]} -> Enum.map(specs, &require_target/1)
          _ -> []
        end)

      _ ->
        []
    end)
  end

  defp require_target({:symbol, target}), do: target
  defp require_target({:vector, [{:symbol, target} | _]}), do: target
  defp require_target(_), do: nil
end
