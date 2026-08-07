defmodule BeamLisp.AOT do
  @moduledoc """
  Ahead-of-time compilation of beam-lisp source into real BEAM modules.

  Interactive `defn` builds its per-namespace module at runtime via
  `Module.create` (see `BeamLisp.Link`); that needs a live compiler in
  the running VM and produces nothing that survives into an escript or
  release. AOT flips that: a `.bl` file is treated as a build input,
  compiled once by `mix compile.beam_lisp`, and each namespace it
  defines is written out as a `.beam` file on the app's code path. A
  fresh VM loads those modules from disk — no runtime compilation.

  ## Compilation unit

  One `.bl` file is one compilation unit. The file is driven through
  the ordinary reader/compiler pipeline, so every `defn`/`def`/`defn`
  side effect happens exactly as at runtime (links interned, modules
  created in the compiler VM, macros expanded). Afterwards each
  namespace module is re-emitted with an extra `__bl_init__/0` function
  and its beam binary is written.

  ## What survives into the release

  Each emitted `BeamLisp.Ns.*` module carries:

    * every `defn` as a real named function — call sites compile to
      direct remote calls (`BeamLisp.Ns.Foo.bar(args)`);
    * `__bl_init__/0`, which re-populates the ETS var registry for that
      namespace: it interns the fn var *values* (captures, so `map f`
      and interop keep working), the link metadata (so later code
      compiles calls to the module directly), the value `def`s (their
      initializers re-run in definition order, so a later def can rely
      on an earlier one), and the namespace's def entries.

  `__bl_init__/0` is idempotent and must run after `BeamLisp.init/0`
  (which seeds `core`). It is what the loader's `__bl_init__` hook and
  `BeamLisp.AOT.ensure_loaded/1` call before a namespace is first used
  in a fresh VM.

  ## Macro availability

  Macros are vars, so a file that defines and uses a macro must have
  the defining file compiled first. Within one file the compiler's
  defmacro-before-use ordering already holds (the runtime registry is
  populated form by form). Across files, `mix compile.beam_lisp` sorts
  sources by their `ns :require` edges and compiles required files
  first — so a required file's macros are interned before the requiring
  file compiles. What does *not* work yet: a file `:require`ing another
  that uses a macro from a *third* file in a dependency cycle. Cycles
  are reported as errors.

  ## Redefinition

  The latest `def` of a name wins, matching runtime semantics: each
  `defn` regenerates the namespace module from all current defs, and
  value `def` initializers are captured latest-wins while keeping
  first-definition order.

  ## Limits

  Cross-file namespace *merging* works (defs accumulate, latest wins),
  but the canonical form is one namespace per file. A namespace with
  only value `def`s still gets a module so its initializers can run on
  first use. `__bl_init__/0` does not persist doc metadata for
  redefined value defs beyond the latest one.
  """

  alias BeamLisp.{Compiler, Env, Link, Reader}

  @doc """
  Compile a `.bl` file into BEAM modules, one per namespace it defines.

  Returns `[{module, beam_path}]`. Options:

    * `:output_dir` — where to write the `.beam` files. Defaults to
      `Mix.Project.compile_path()` when a Mix project is loaded.

  The file is a self-contained compilation unit: it is driven through
  the compiler (macros expand, links intern, value defs evaluate) and
  every namespace module it touches is emitted to disk. Requires
  `BeamLisp.Env` to be started (done automatically by `boot/0`).
  """
  def compile_file(path, opts \\ []) do
    boot()

    BeamLisp.Loader.with_load_path(Path.dirname(path), fn ->
      path |> File.read!() |> compile_source(opts)
    end)
  end

  @doc """
  Like `compile_file/2` but for an in-memory source string. The caller
  owns load-path setup for any `:require` targets.
  """
  def compile_source(source, opts \\ []) do
    output_dir = Keyword.get(opts, :output_dir) || default_output_dir()

    boot()

    # Each file is an independent compilation unit defaulting to the
    # `user` namespace. `Env.current_ns/0` leaks across compile_file
    # calls (a prior file's `(ns ...)` is not rolled back), so reset it
    # here — mirroring what `Compiler.eval_string/2` does — before
    # capturing any defs.
    Env.in_ns("user")

    {value_defs, touched, ns_meta} =
      source
      |> Reader.read_all()
      |> Enum.reduce({%{}, MapSet.new(), %{}}, fn form, {vdefs, nss, nsmeta} ->
        ns = Env.current_ns()
        vdefs = capture_value_def(vdefs, form, ns)
        nsmeta = capture_ns_decl(nsmeta, form)
        _ = Compiler.eval_form(form, %{Compiler.new_env() | ns: Env.current_ns()})
        {vdefs, MapSet.put(nss, ns), nsmeta}
      end)

    # A namespace gets a module if it defined functions or value vars.
    touched
    |> Enum.filter(fn ns -> Map.has_key?(value_defs, ns) or Env.ns_defs(ns) != %{} end)
    |> Enum.sort()
    |> Enum.map(fn ns ->
      emit_module(ns, Map.get(value_defs, ns, []), Map.get(ns_meta, ns, %{}), output_dir)
    end)
  end

  @doc """
  Ensure namespace `ns` is usable in this VM: load its AOT module if a
  `.beam` exists on the code path, and run its `__bl_init__/0` (no-op
  for namespaces with no AOT module). Idempotent; returns `:ok`.

  Call after `BeamLisp.init/0` so `core` is seeded for value-def
  initializers. This is the runtime-side hook a loader or application
  start calls before first use of a compiled namespace.
  """
  def ensure_loaded(ns) when is_binary(ns) do
    mod = Link.module_for(ns)

    if code_path_module?(mod) do
      Code.ensure_loaded(mod)
      if function_exported?(mod, :__bl_init__, 0), do: mod.__bl_init__()
    end

    :ok
  end

  @doc "Start `BeamLisp.Env` if needed and seed `core` (idempotent)."
  def boot do
    unless Process.whereis(BeamLisp.Env) do
      {:ok, _} = BeamLisp.Env.start_link([])
    end

    BeamLisp.init()
    :ok
  end

  # --- compilation plumbing ---

  # Capture a value `def`'s initializer (and optional docstring) so the
  # namespace module can re-run it in `__bl_init__/0`. Latest def wins,
  # but first-definition order is preserved (a later def may reference
  # an earlier one).
  defp capture_value_def(vdefs, {:list, [{:symbol, "def"}, {:symbol, name} | rest]}, ns) do
    case rest do
      [init] -> put_value_def(vdefs, ns, name, nil, init)
      [doc, init] when is_binary(doc) -> put_value_def(vdefs, ns, name, doc, init)
      # Malformed def; let the compiler raise its usual error.
      _ -> vdefs
    end
  end

  defp capture_value_def(vdefs, _form, _ns), do: vdefs

  # Capture the alias/refer side effects of an `(ns name (:require ...))`
  # declaration so `__bl_init__/0` can re-run them in a fresh VM (a
  # referred var like `greet` resolves through these at runtime). Latest
  # declaration of an alias/refer wins.
  defp capture_ns_decl(ns_meta, {:list, [{:symbol, "ns"}, {:symbol, ns} | clauses]}) do
    {aliases, refers} =
      Enum.reduce(clauses, {[], []}, fn
        {:list, [{:keyword, "require"} | specs]}, {al, rf} ->
          Enum.reduce(specs, {al, rf}, &capture_require_spec/2)

        _, acc ->
          acc
      end)

    Map.update(ns_meta, ns, %{aliases: aliases, refers: refers}, fn _prev ->
      %{aliases: aliases, refers: refers}
    end)
  end

  defp capture_ns_decl(ns_meta, _form), do: ns_meta

  # Like Compiler.parse_require_spec/1: `[target :as a :refer [x y]]` or
  # a bare `target`. The task compiles required files first, so the
  # require graph is the compilation-order signal; here we only need the
  # alias/refer pairs to re-instantiate at runtime.
  defp capture_require_spec({:symbol, _target}, acc), do: acc

  defp capture_require_spec({:vector, [{:symbol, target} | flags]}, acc) do
    {as_alias, refer_syms} =
      Enum.reduce(flags, {nil, []}, fn
        {:keyword, "as"}, {_a, rf} -> {{:expecting, "as"}, rf}
        {:keyword, "refer"}, {al, _rf} -> {al, {:expecting, "refer"}}
        {:symbol, a}, {{:expecting, "as"}, rf} -> {a, rf}
        {:vector, syms}, {al, {:expecting, "refer"}} -> {al, Enum.map(syms, fn {:symbol, s} -> s end)}
        _other, acc -> acc
      end)

    {aliases, refers} = acc
    aliases = if as_alias, do: aliases ++ [{as_alias, target}], else: aliases
    refers = refers ++ for sym <- refer_syms, do: {sym, target}
    {aliases, refers}
  end

  defp capture_require_spec(_other, acc), do: acc


  defp put_value_def(vdefs, ns, name, doc, init) do
    entries =
      vdefs
      |> Map.get(ns, [])
      |> Enum.reject(fn {n, _, _} -> n == name end)

    Map.put(vdefs, ns, entries ++ [{name, doc, init}])
  end

  # Build and compile the namespace module, then write its beam.
  defp emit_module(ns, value_defs, ns_meta, output_dir) do
    mod = Link.module_for(ns)
    ns_defs = Env.ns_defs(ns)
    fn_asts = Enum.flat_map(ns_defs, fn {_name, defs} -> Enum.map(defs, &elem(&1, 3)) end)
    init_ast = build_init_ast(ns, mod, ns_defs, value_defs, ns_meta)

    quoted =
      quote do
        defmodule unquote(mod) do
          @moduledoc false
          unquote_splicing(fn_asts)
          unquote(init_ast)
        end
      end

    beam = compile_quoted!(quoted, "beam_lisp_aot/#{ns}.bl")
    path = Path.join(output_dir, Atom.to_string(mod) <> ".beam")
    File.mkdir_p!(output_dir)
    File.write!(path, beam)
    {mod, path}
  end

  defp build_init_ast(ns, mod, ns_defs, value_defs, ns_meta) do
    env = Compiler.new_env(ns)

    aliases = Map.get(ns_meta, :aliases, [])
    refers = Map.get(ns_meta, :refers, [])

    # Re-instantiate the ns declaration's alias/refer metadata first, so
    # any referred/aliased resolution in this namespace works at runtime.
    ns_ops =
      for {alias_, target} <- aliases do
        quote do: BeamLisp.Env.add_alias(unquote(ns), unquote(alias_), unquote(target))
      end ++
      for {sym, target} <- refers do
        quote do: BeamLisp.Env.add_refer(unquote(ns), unquote(sym), unquote(target))
      end

    # fn values + link metadata, so `map f`, interop and later call
    # compilation all resolve against this module.
    fn_ops =
      Enum.flat_map(ns_defs, fn {name, defs} ->
        fixed = for {:fixed, arity, fname, _} <- defs, do: {arity, fname}
        variadic = Enum.find_value(defs, fn
          {:variadic, min, fname, _} -> {min, fname}
          _ -> nil
        end)

        [
          quote do
            BeamLisp.Env.intern(unquote(ns), unquote(name), unquote(fn_value_expr(mod, fixed, variadic)))
          end,
          quote do
            BeamLisp.Env.put_link(unquote(ns), unquote(name), unquote(Macro.escape({mod, Map.new(fixed), variadic})))
          end
        ]
      end)

    # Value defs, in first-definition order (a later def may build on
    # an earlier one, exactly as at runtime).
    value_ops =
      for {name, doc, init_form} <- value_defs do
        init_ast = Compiler.compile(init_form, env)
        intern = quote do: BeamLisp.Env.intern(unquote(ns), unquote(name), unquote(init_ast))

        if doc do
          quote do
            _value = unquote(intern)
            BeamLisp.Env.put_meta(unquote(ns), unquote(name), %{doc: unquote(doc)})
          end
        else
          intern
        end
      end

    ns_defs_escaped = Macro.escape(ns_defs)
    quote do
      @doc "Re-populates this namespace's var registry; idempotent."
      def __bl_init__ do
        unquote_splicing(ns_ops)
        unquote_splicing(fn_ops)
        unquote_splicing(value_ops)
        BeamLisp.Env.put_ns_defs(unquote(ns), unquote(ns_defs_escaped))
        :ok
      end
    end
  end

  # The runtime value of a fn var, mirroring BeamLisp.Link.fn_value/3:
  # a single fixed-arity fn is a plain capture; anything else is the
  # tagged multi-arity/variadic wrapper with captures inside.
  defp fn_value_expr(mod, [{arity, fname}], nil) do
    quote do: &unquote(mod).unquote(fname)/unquote(arity)
  end

  defp fn_value_expr(mod, fixed, variadic) do
    fixed_map = {:%{}, [], for {arity, fname} <- fixed do
      {arity, quote(do: &unquote(mod).unquote(fname)/unquote(arity))}
    end}

    variadic_entry =
      case variadic do
        nil ->
          nil

        {min, fname} ->
          {:{}, [], [min, quote(do: &unquote(mod).unquote(fname)/unquote(min + 1))]}
      end

    quote do
      {:"$blfn", unquote(fixed_map), unquote(variadic_entry)}
    end
  end

  defp compile_quoted!(quoted, filename) do
    prev = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      case Code.compile_quoted(quoted, filename) do
        [{_mod, beam}] -> beam
        [] -> raise "AOT: compiling a namespace produced no module"
      end
    after
      Code.compiler_options(prev)
    end
  end

  defp code_path_module?(mod), do: :code.which(mod) != :non_existing

  defp default_output_dir do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix.Project, :compile_path, 0) do
      Mix.Project.compile_path()
    else
      raise ArgumentError,
            "BeamLisp.AOT needs an :output_dir (no Mix project loaded to default to compile_path)"
    end
  end
end
