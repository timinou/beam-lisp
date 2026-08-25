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
        strict: [source_dir: :string, force: :boolean]
      )

    source_dir = opts[:source_dir] || source_dir_from_config()
    compile_path = Mix.Project.compile_path()
    manifest_path = Path.join(Mix.Project.manifest_path(), @manifest)

    cond do
      not File.dir?(source_dir) ->
        {:noop, []}

      discover(source_dir) == [] ->
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
        BeamLisp.init()

        sources = discover(source_dir)
        manifest = read_manifest(manifest_path)
        ordered = order_by_requires(sources)

        {manifest, recompiled, errors} =
          Enum.reduce(ordered, {manifest, false, []}, fn path, {m, rc, errs} ->
            hash = content_hash(path)

            if opts[:force] || not up_to_date?(m, path, hash, compile_path) do
              case compile_file(path, compile_path) do
                {:ok, modules} ->
                  {Map.put(m, path, %{hash: hash, modules: modules}), true, errs}

                {:error, err} ->
                  {m, rc, [err | errs]}
              end
            else
              {m, rc, errs}
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

        cond do
          errors != [] -> {:error, Enum.reverse(errors)}
          recompiled -> {:ok, []}
          true -> {:noop, []}
        end
    end
  end

  @impl Mix.Task.Compiler
  def clean do
    manifest_path = Path.join(Mix.Project.manifest_path(), @manifest)

    if File.exists?(manifest_path) do
      compile_path = Mix.Project.compile_path()

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
  defp source_dir_from_config do
    project_config = Mix.Project.config()[:beam_lisp] || []

    project_config[:source_dir] ||
      Application.get_env(:beam_lisp, :source_dir, "bl")
  end

  defp discover(source_dir) do
    source_dir
    |> Path.join("**/*.bl")
    |> Path.wildcard()
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
      e -> {:error, "beam-lisp AOT: #{path}: " <> Exception.message(e)}
    end
  end

  defp delete_beam(mod, compile_path) do
    path = Path.join(compile_path, Atom.to_string(mod) <> ".beam")
    if File.exists?(path), do: File.rm(path)
  end

  # --- require ordering ---

  # Compile sources in dependency order: a source's `ns :require`
  # targets that are themselves sources must compile first. Returns the
  # list in compile order, or raises on a cycle.
  defp order_by_requires(sources) do
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

    ordered
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
