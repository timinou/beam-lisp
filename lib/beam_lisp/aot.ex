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

  alias BeamLisp.{Compiler, Emit, Env, Link, Reader}

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
      path |> File.read!() |> compile_source(Keyword.put_new(opts, :file, path))
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

    # The source path rides along so an AOT-compiled module's line table
    # names the .bl file. These .beam files persist and are what a
    # production stack trace hits, so this is the attribution that
    # matters most — an eval module is transient, this is not.
    file = Keyword.get(opts, :file)

    {value_defs, touched, ns_meta} =
      source
      |> Reader.read_string(file)
      |> Enum.reduce({%{}, MapSet.new(), %{}}, fn form, {vdefs, nss, nsmeta} ->
        ns = Env.current_ns()
        vdefs = capture_value_def(vdefs, form, ns)
        nsmeta = capture_ns_decl(nsmeta, form)
        _ = Compiler.eval_form(form, %{Compiler.new_env() | ns: Env.current_ns()})
        {vdefs, MapSet.put(nss, ns), nsmeta}
      end)

    # A namespace gets a module if it defined functions or value vars. Each
    # namespace now emits SEVERAL beams — the shim namespace module plus one
    # per body module — so flat_map the per-namespace lists into one
    # `[{mod, path}]` for the caller and the Mix manifest.
    touched
    |> Enum.filter(fn ns -> Map.has_key?(value_defs, ns) or Env.ns_defs(ns) != %{} end)
    |> Enum.sort()
    |> Enum.flat_map(fn ns ->
      emit_module(ns, Map.get(value_defs, ns, []), Map.get(ns_meta, ns, %{}), output_dir, file)
    end)
  end

  @doc """
  Ensure namespace `ns` is usable in this VM: load its AOT module if a
  `.beam` exists on the code path, and run its `__bl_init__/0` (no-op
  for namespaces with no AOT module). Idempotent.

  Returns `:loaded` when a compiled module was found and made usable — the
  namespace is then marked loaded, so `Env.loaded_ns?/1` says yes and a
  source load is neither needed nor performed — or `:no_module` when nothing
  was on the code path and the caller should fall back to reading source.

  Call after `BeamLisp.init/0` so `core` is seeded for value-def
  initializers. This is the runtime-side hook a loader or application
  start calls before first use of a compiled namespace.
  """
  def ensure_loaded(ns) when is_binary(ns) do
    mod = Link.module_for(ns)

    if code_path_module?(mod) and Code.ensure_loaded?(mod) and
         function_exported?(mod, :__bl_init__, 0) do
      # MARK IT BEFORE RUNNING IT, exactly as the source loader does.
      #
      # Two reasons, and the order matters for the second. First, the mark is
      # what lets `Loader.ensure_loaded/1` skip the source: without it the
      # answer to `loaded_ns?` was `false` and the loader read and compiled
      # the source it had just been handed — `datom` cost 41s through the
      # loader against 14.7s calling this directly.
      #
      # Second, `__bl_init__/0` now replays this namespace's requires, and a
      # require cycle would come back around to here. Marking first makes the
      # loader's guard cut the cycle; marking afterwards would recurse until
      # the stack gave out.
      Env.mark_loaded(ns)
      mod.__bl_init__()

      :loaded
    else
      # SAY SO. A bare `:ok` for both outcomes is what hid the bug this return
      # value fixed: the caller could not distinguish "loaded from disk" from
      # "there was nothing to load", so it could not skip the fallback.
      #
      # THE `__bl_init__/0` CHECK IS LOAD-BEARING, not a formality. Every AOT
      # beam the emitter writes carries `__bl_init__/0` (see `build_init_ast`),
      # so its presence distinguishes a real compiled module from an IN-MEMORY
      # namespace shim. `BeamLisp.init/0` (seeding core from source) and
      # `Link.defvar` (every runtime `def`) build such a shim via
      # `Module.create`, and `:code.which/1` reports it loaded — it returns
      # `[]`, not `:non_existing`, so `code_path_module?` alone says yes. When
      # a shim shadows the on-disk beam in some VM (the compile VM does exactly
      # this: it seeds core from source, THEN emits the beam), reporting
      # `:loaded` would intern nothing — the shim has no init to run. Falling
      # through to `:no_module` sends the caller to the source path, which is
      # correct (and, in that already-seeded VM, a no-op).
      :no_module
    end
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
  # Reader forms arrive carrying source positions, so peel the wrapper
  # before matching shape. Only lists are wrapped, so this one clause
  # per matcher is the whole cost of position-awareness here.
  defp capture_value_def(vdefs, {:meta, form, _m}, ns), do: capture_value_def(vdefs, form, ns)

  # THE NAME can carry metadata too, and `^:private` is the common case.
  # `(def ^:private T :x)` reaches here as a meta-wrapped SYMBOL in the name
  # position, which matched no clause below — so the def was silently
  # dropped from `__bl_init__/0` and the var simply did not exist in an AOT
  # build. It surfaced as "undefined var: reel.film/TEMPIDS" raised from a
  # function that plainly referenced it, in a namespace that had loaded
  # without complaint. Peel the name, then match as usual.
  defp capture_value_def(vdefs, {:list, [{:symbol, "def"}, {:meta, name_form, _m} | rest]}, ns) do
    capture_value_def(vdefs, {:list, [{:symbol, "def"}, name_form | rest]}, ns)
  end

  # DEFINE-BY-INTERNING forms, replayed whole.
  #
  # `defn`/`defmacro` become real functions in the emitted module, so the
  # `fn_ops` above reconstruct them. These do not: each one builds something
  # at EVAL time — a gen_server module via `Module.create`, a record's
  # constructor and accessors, a protocol's dispatch table — and interns the
  # result. An AOT build wrote none of it to disk and nothing recreated it,
  # so the namespace loaded cleanly and then failed at first use:
  # "undefined var: reel.store/store", "undefined var:
  # datom.store-redb/->RedbStore". The same shape as the `defnative` hole
  # (BUG-021), which was fixed one form at a time; this is that fix
  # generalised, because the property is shared and the list is closed.
  #
  # Replaying the FORM is right rather than expedient: the form is the
  # definition, and re-evaluating it in `__bl_init__/0` reconstructs exactly
  # what evaluating the source would. All of them are idempotent by
  # construction (module creates set `ignore_module_conflict`).
  # `defmacro` is here for a different reason than the rest, and it matters.
  # A macro is a compile-time expander held in the var registry; the emitted
  # module has no function for it, because by the time a caller is compiled
  # the macro has already done its work. But a namespace loaded from a
  # `.beam` still has to OFFER its macros to whatever compiles next — a
  # script, the REPL, another namespace read from source — and without this
  # they were simply gone: "undefined var: rewrite.test/defrule", from a
  # namespace that had loaded successfully.
  @replayed_forms ~w(defmacro defserver defrecord deftype defprotocol defmulti extend-type extend-protocol)

  defp capture_value_def(vdefs, {:list, [{:symbol, head}, name_form | _]} = form, ns)
       when head in @replayed_forms do
    put_value_def(vdefs, ns, definition_name(head, name_form), nil, form)
  end

  defp capture_value_def(vdefs, {:list, [{:symbol, "def"}, {:symbol, name} | rest]}, ns) do
    case rest do
      [init] -> put_value_def(vdefs, ns, name, nil, init)
      [doc, init] when is_binary(doc) -> put_value_def(vdefs, ns, name, doc, init)
      # Malformed def; let the compiler raise its usual error.
      _ -> vdefs
    end
  end

  defp capture_value_def(vdefs, _form, _ns), do: vdefs

  # The key a replayed form is stored under. It only has to be STABLE and
  # unique per definition — `put_value_def` uses it for "latest wins", and
  # the extra `Env.intern` the emitter wraps around the form is harmless
  # because the form has already interned the real vars itself.
  #
  # `extend-type`/`extend-protocol` intern nothing and name a type rather
  # than a var, so they are keyed by a prefix that cannot collide with a
  # legal var name.
  defp definition_name(head, name_form) when head in ~w(extend-type extend-protocol),
    do: "#{head} #{bare_name(name_form)}"

  defp definition_name(_head, name_form), do: bare_name(name_form)

  # A definition's name, with or without metadata on it.
  defp bare_name({:meta, form, _m}), do: bare_name(form)
  defp bare_name({:symbol, name}), do: name
  defp bare_name(other), do: inspect(other)

  # Capture the alias/refer side effects of an `(ns name (:require ...))`
  # declaration so `__bl_init__/0` can re-run them in a fresh VM (a
  # referred var like `greet` resolves through these at runtime). Latest
  # declaration of an alias/refer wins.
  defp capture_ns_decl(ns_meta, {:meta, form, _m}), do: capture_ns_decl(ns_meta, form)

  defp capture_ns_decl(ns_meta, {:list, [{:symbol, "ns"}, {:symbol, ns} | clauses]}) do
    # PEEL THE CLAUSES FIRST. The reader wraps each one in `{:meta, _, _}`
    # to carry its source position, so matching `{:list, [{:keyword,
    # "require"} | _]}` directly matched nothing and every `(:require …)`
    # read as absent — silently, because these are pattern-matching
    # comprehensions that filter rather than raise.
    clauses = Enum.map(clauses, &unmeta/1)

    {aliases, refers, refer_alls} =
      Enum.reduce(clauses, {[], [], []}, fn
        {:list, [{:keyword, "require"} | specs]}, acc ->
          Enum.reduce(specs, acc, &capture_require_spec/2)

        _, acc ->
          acc
      end)

    # The require TARGETS, separately from the alias/refer pairs they carry.
    # A bare `(:require [datom.tx])` contributes no alias and no refer, so it
    # left no trace in the two lists above — and yet the requiring namespace
    # cannot run without it.
    requires =
      Enum.flat_map(clauses, fn
        {:list, [{:keyword, "require"} | specs]} -> Enum.map(specs, &require_target/1)
        _ -> []
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    meta = %{aliases: aliases, refers: refers, refer_alls: refer_alls, requires: requires}
    Map.update(ns_meta, ns, meta, fn _prev -> meta end)
  end

  defp capture_ns_decl(ns_meta, _form), do: ns_meta

  # The namespace a require spec names, in either accepted shape.
  defp require_target(spec) do
    case unmeta(spec) do
      {:symbol, target} ->
        target

      {:vector, [head | _flags]} ->
        case unmeta(head) do
          {:symbol, target} -> target
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Strip one layer of reader position metadata.
  defp unmeta({:meta, form, _m}), do: form
  defp unmeta(form), do: form

  # Like Compiler.parse_require_spec/1: `[target :as a :refer [x y]]` or
  # a bare `target`. The task compiles required files first, so the
  # require graph is the compilation-order signal; here we only need the
  # alias/refer pairs to re-instantiate at runtime.
  defp capture_require_spec({:meta, form, _m}, acc), do: capture_require_spec(form, acc)

  defp capture_require_spec({:symbol, _target}, acc), do: acc

  # A require spec whose TARGET carries metadata, e.g. `[^:x foo :as f]`.
  defp capture_require_spec({:vector, [{:meta, head, _m} | flags]}, acc),
    do: capture_require_spec({:vector, [head | flags]}, acc)

  defp capture_require_spec({:vector, [{:symbol, target} | flags]}, acc) do
    # PEEL EACH FLAG. The reader wraps them in position metadata, so
    # `{:keyword, "refer"}` arrived as `{:meta, {:keyword, "refer"}, _}` and
    # fell to the catch-all — leaving the accumulator holding the
    # `{:expecting, "refer"}` SENTINEL instead of a list of symbols. The
    # sentinel then reached the comprehension below, where a tuple is not
    # enumerable: "protocol Enumerable not implemented for Tuple", raised
    # from a require clause that is perfectly well formed.
    # `:refer :all` (a `{:keyword, "all"}` after `:refer`) refers EVERY public
    # name of the target and must be replayed as `add_refer_all/2` — the target
    # namespace's exports are not known until it is loaded, so we cannot expand
    # it to individual pairs here. `:refer [a b c]` stays a `{:vector, syms}`.
    {as_alias, refer_syms, refer_all?} =
      flags
      |> Enum.map(&unmeta/1)
      |> Enum.reduce({nil, [], false}, fn
        {:keyword, "as"}, {_a, rf, ra} -> {{:expecting, "as"}, rf, ra}
        {:keyword, "refer"}, {al, _rf, ra} -> {al, {:expecting, "refer"}, ra}
        {:symbol, a}, {{:expecting, "as"}, rf, ra} -> {a, rf, ra}
        {:keyword, "all"}, {al, {:expecting, "refer"}, _ra} -> {al, [], true}
        {:vector, syms}, {al, {:expecting, "refer"}, ra} -> {al, Enum.map(syms, &bare_name/1), ra}
        _other, acc -> acc
      end)

    {aliases, refers, refer_alls} = acc

    # An `:as`/`:refer` never followed by its argument leaves the sentinel
    # behind. Treat it as absent rather than letting a tuple downstream.
    as_alias = if is_binary(as_alias), do: as_alias
    refer_syms = if is_list(refer_syms), do: refer_syms, else: []

    aliases = if as_alias, do: aliases ++ [{as_alias, target}], else: aliases
    refers = refers ++ for sym <- refer_syms, do: {sym, target}
    refer_alls = if refer_all?, do: refer_alls ++ [target], else: refer_alls
    {aliases, refers, refer_alls}
  end

  defp capture_require_spec(_other, acc), do: acc


  defp put_value_def(vdefs, ns, name, doc, init) do
    entries =
      vdefs
      |> Map.get(ns, [])
      |> Enum.reject(fn {n, _, _} -> n == name end)

    Map.put(vdefs, ns, entries ++ [{name, doc, init}])
  end

  # Emit a namespace as the SAME shim/body split the runtime uses, so an
  # AOT-loaded namespace is byte-for-byte the source-loaded one and survives
  # module version churn (a runtime `(def)` into the ns reloads the ns module;
  # the BEAM purges the oldest of two versions on the third load, which strands
  # any closure or fn-capture that lived in the reloaded module).
  #
  # The runtime already drove each `defn`'s real code into an immutable
  # `BeamLisp.Ns.Fn.M<n>` BODY module during `compile_source`'s `eval_form`
  # pass, leaving `Env.ns_defs/1` holding the 5-field tuples that name those
  # body modules. We emit:
  #
  #   * one `.beam` per body module (the real code), NEVER reloaded, so churn
  #     can't purge it, and
  #   * the namespace module carrying only forwarding SHIMS plus `__bl_init__/0`.
  #
  # `__bl_init__/0` interns fn values as captures of the stable SHIM names
  # (`&BeamLisp.Ns.<Ns>.f/arity`) and re-persists `ns_defs` (which names the
  # body modules). Because those body-module beams are now on the code path,
  # the shims resolve, and a later runtime `(def)` that rebuilds the shims from
  # `ns_defs` forwards each existing fn to its own on-disk body module rather
  # than a phantom one. Returns every emitted `{mod, path}` so the Mix task can
  # track and clean all of them.
  defp emit_module(ns, value_defs, ns_meta, output_dir, file) do
    mod = Emit.module_for(ns)
    filename = file || "beam_lisp_aot/#{ns}.bl"

    # Runtime `Link.defvar` named each var's body module with a
    # process-unique integer (`Ns.Fn.M<n>`) — perfect for the runtime, where
    # every `def` wants a brand-new module, but NON-DETERMINISTIC across
    # builds: two AOT compiles of the same source would emit different body
    # module names, so `.beam` files accumulate and the Mix manifest never
    # stabilises. Rename each body module to a name derived purely from the
    # namespace and var, so a rebuild is byte-stable and the manifest can
    # track exactly the modules on disk.
    ns_defs = stabilise_body_modules(ns, Env.ns_defs(ns))

    # Body modules: one `defmodule` of real code per var's body module.
    body_module_quoteds =
      for {body_mod, def_asts} <- Emit.body_modules(ns_defs) do
        quote do
          defmodule unquote(body_mod) do
            @moduledoc false
            unquote_splicing(def_asts)
          end
        end
      end

    # Namespace module: forwarding shims + the init hook. `build_init_ast`
    # also hands back a stable companion module (`BeamLisp.Ns.Init.<Ns>`) that
    # holds the value/macro initializers, or nil when there are none — emitted
    # as its own never-reloaded beam so macro-expander closures survive churn.
    shim_asts = Emit.shim_defs(ns_defs)
    {init_ast, companion_quoted} = build_init_ast(ns, mod, ns_defs, value_defs, ns_meta)

    ns_module_quoted =
      quote do
        defmodule unquote(mod) do
          @moduledoc false
          unquote_splicing(shim_asts)
          unquote(init_ast)
        end
      end

    # ONE compiler invocation for the whole namespace. A namespace with 130
    # vars emits ~132 modules (body modules + shim ns module + companion);
    # calling `Code.compile_quoted/2` once per module spun the Elixir compiler
    # up ~132 times and made `core.bl` alone cost 8s. Compiling them together
    # — one block of `defmodule`s, one invocation — restores near-single-module
    # cost. The block is order-insensitive: body modules are referenced by the
    # shims only at call time, not at compile time.
    all_quoted =
      [ns_module_quoted | body_module_quoteds] ++ List.wrap(companion_quoted)

    block = {:__block__, [], all_quoted}

    compile_block!(block, filename)
    |> Enum.map(fn {emitted_mod, beam} -> write_beam(emitted_mod, beam, output_dir) end)
  end

  # Compile-to-disk for one module; returns `{mod, path}`.
  defp write_beam(mod, beam, output_dir) do
    path = Path.join(output_dir, Atom.to_string(mod) <> ".beam")
    File.mkdir_p!(output_dir)
    File.write!(path, beam)
    {mod, path}
  end

  # `ns_meta` is the per-namespace map captured from the `(ns …)` form:
  # `%{aliases:, refers:, requires:}`.
  defp build_init_ast(ns, mod, ns_defs, value_defs, ns_meta) do
    env = Compiler.new_env(ns)

    aliases = Map.get(ns_meta, :aliases, [])
    refers = Map.get(ns_meta, :refers, [])
    refer_alls = Map.get(ns_meta, :refer_alls, [])
    requires = Map.get(ns_meta, :requires, [])

    # THE REQUIRES FIRST, before this namespace's own init touches anything.
    #
    # A value def's initializer can CALL into a required namespace, and
    # `__bl_init__/0` runs those initializers for real. `reel.corpus` does
    # exactly this — a top-level def that calls `reel.film/tempid-for` — and
    # it failed with "undefined var: reel.film/TEMPIDS": the module for
    # `reel.film` was loaded, but its own value defs had not run yet, so the
    # table its function reaches for did not exist.
    #
    # Compilation order was already right (the task compiles required files
    # first); LOAD order was not, because nothing recorded what to load.
    # Recursing through the loader is what fixes it, and the loader's
    # `loaded_ns?` guard is what stops a require cycle from spinning.
    require_ops =
      for target <- requires do
        quote do: BeamLisp.Loader.ensure_loaded(unquote(target))
      end

    # Then re-instantiate the ns declaration's alias/refer metadata, so
    # any referred/aliased resolution in this namespace works at runtime.
    ns_ops =
      require_ops ++
      for {alias_, target} <- aliases do
        quote do: BeamLisp.Env.add_alias(unquote(ns), unquote(alias_), unquote(target))
      end ++
      for {sym, target} <- refers do
        quote do: BeamLisp.Env.add_refer(unquote(ns), unquote(sym), unquote(target))
      end ++
      # `:refer :all` — pull EVERY public name of the target. Emitted after the
      # requires above so the target namespace is loaded and its exports are
      # enumerable. Without this, a namespace that re-exports through
      # `(def x x)` over a `:refer :all` (specter.navs does exactly this) could
      # not resolve the referred name and `__bl_init__` raised
      # `undefined var: <ns>/<name>`.
      for target <- refer_alls do
        quote do: BeamLisp.Env.add_refer_all(unquote(ns), unquote(target))
      end

    # A `defnative` declaration is replayed BEFORE the fn links, so the
    # host module exists and its names are bound by the time anything
    # resolves against them. Without this an AOT build had no native
    # backend at all: the host is created by `Module.create` at runtime,
    # so it was never written to disk, and nothing recreated it
    # (BUG-021).
    native_ops =
      case BeamLisp.Native.declaration(ns) do
        nil ->
          []

        {crate, signatures} ->
          [
            quote do
              BeamLisp.Native.declare(
                unquote(ns),
                unquote(crate),
                unquote(Macro.escape(signatures))
              )
            end
          ]
      end

    # fn values + link metadata, so `map f`, interop and later call
    # compilation all resolve against this module.
    fn_ops =
      Enum.flat_map(ns_defs, fn {name, defs} ->
        # MATCH ON THE TAG AND READ BY INDEX, not on the tuple's width. These
        # arrive as `{:fixed, arity, fname, ast, meta}` — five elements — and
        # a four-element pattern here matched NOTHING. A comprehension filters
        # rather than raises, so `fixed` came out `[]` and the emitted var was
        # `{:"$blfn", %{}, nil}`: a function value with an empty dispatch
        # table, which fails at the call site with "wrong number of args (1)"
        # for an argument count the module plainly exports.
        #
        # Single-arity fns were unaffected — they take the one-clause branch
        # in `fn_value_expr/3` — so this was invisible until a namespace with
        # a multi-arity `defn` was AOT-compiled.
        fixed =
          for d <- defs, elem(d, 0) == :fixed, do: {elem(d, 1), elem(d, 2)}

        variadic =
          Enum.find_value(defs, fn
            d when elem(d, 0) == :variadic -> {elem(d, 1), elem(d, 2)}
            _ -> nil
          end)

        # Replay the var's metadata (`%{doc:, private:, …}`). `compile_defn`
        # wrote it to the live Env during the emit VM's eval_form pass via
        # `Env.put_meta`, but nothing persisted it into the AOT module — so an
        # AOT-loaded `defn` had no docstring and `(doc foo)` printed "No doc
        # found" for every core fn. Read it here and replay it. `nil`/empty
        # meta emits nothing.
        meta_ops =
          case Env.meta(ns, name) do
            # is_map-ok: `meta` is a var's metadata map written by
            # `Env.put_meta` (%{doc:, private:, …}), a plain internal Elixir
            # map, never a beam-lisp struct.
            {:ok, meta} when is_map(meta) and map_size(meta) > 0 ->
              [quote do: BeamLisp.Env.put_meta(unquote(ns), unquote(name), unquote(Macro.escape(meta)))]

            _ ->
              []
          end

        [
          quote do
            BeamLisp.Env.intern(unquote(ns), unquote(name), unquote(fn_value_expr(mod, fixed, variadic)))
          end,
          quote do
            BeamLisp.Env.put_link(unquote(ns), unquote(name), unquote(Macro.escape({mod, Map.new(fixed), variadic})))
          end
        ] ++ meta_ops
      end)

    # Value defs, in first-definition order (a later def may build on
    # an earlier one, exactly as at runtime).
    #
    # A value initializer can CREATE A CLOSURE — a `defmacro`'s expander is
    # exactly this: `{:"$macro", {:"$blfn", _, closure}}`. That closure's code
    # belongs to whatever module the `fn` was compiled into. If we splice
    # these ops straight into `Ns.<Ns>.__bl_init__/0`, the closure belongs to
    # the NAMESPACE module — which every runtime `(def)` into this namespace
    # reloads. On the third reload the BEAM purges the version the closure
    # came from and using the macro raises BadFunctionError. Source-seeding is
    # immune because each top-level form is evaluated in its own throwaway
    # `BeamLisp.Eval.M<n>` module, which is never reloaded.
    #
    # So we mirror that: the value/macro ops live in a STABLE companion module
    # `BeamLisp.Ns.Init.<Ns>` (emitted once, never reloaded), and `__bl_init__`
    # merely CALLS it. Closures created inside it are anchored to that stable
    # module and survive namespace churn. When there are no value defs the
    # companion is omitted and no call is emitted.
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

    init_mod = init_module_for(ns)

    {value_call_ops, companion_quoted} =
      case value_ops do
        [] ->
          {[], nil}

        ops ->
          companion =
            quote do
              defmodule unquote(init_mod) do
                @moduledoc false
                # Runs this namespace's value/macro initializers. Lives in its
                # own never-reloaded module so the closures it creates (macro
                # expanders especially) are never stranded by namespace churn.
                def __bl_init_values__ do
                  unquote_splicing(ops)
                  :ok
                end
              end
            end

          {[quote(do: unquote(init_mod).__bl_init_values__())], companion}
      end

    ns_defs_escaped = Macro.escape(ns_defs)

    init_ast =
      quote do
        @doc "Re-populates this namespace's var registry; idempotent."
        def __bl_init__ do
          unquote_splicing(ns_ops)
          unquote_splicing(native_ops)
          unquote_splicing(fn_ops)
          unquote_splicing(value_call_ops)
          BeamLisp.Env.put_ns_defs(unquote(ns), unquote(ns_defs_escaped))
          :ok
        end
      end

    {init_ast, companion_quoted}
  end

  # The stable companion module that holds a namespace's value/macro
  # initializers: `BeamLisp.Ns.Init.<Ns>`, parallel to `BeamLisp.Ns.<Ns>`.
  defp init_module_for(ns) do
    segments = ns |> String.split(".") |> Enum.map(&Macro.camelize/1)
    Module.concat([BeamLisp.Ns, "Init" | segments])
  end

  # Rewrite every var's body module (tuple elem 4) to a SINGLE deterministic
  # body module shared by the whole namespace: `BeamLisp.Ns.Body.<Ns>`.
  #
  # Two goals meet here:
  #
  #   * Determinism — the runtime named each var's body module with a
  #     process-unique integer (`Ns.Fn.M<n>`), so two AOT builds of the same
  #     source emitted different names and `.beam`s accumulated. A name derived
  #     purely from the namespace is byte-stable across builds.
  #
  #   * Build cost — one body module per VAR meant ~600 compilation units for
  #     the prelude + libraries, and a full AOT build took minutes. One body
  #     module per NAMESPACE (~33 total) restores near-baseline build time.
  #
  # Churn safety is preserved: the shared body module holds all of a
  # namespace's real code and is NEVER reloaded. Only the shim namespace module
  # (`BeamLisp.Ns.<Ns>`) is rebuilt when a later runtime `(def)` adds a var —
  # and that new var gets its own fresh `Ns.Fn.M<n>` from `Link.defvar` while
  # the AOT-loaded fns keep forwarding to the stable `Ns.Body.<Ns>`. Neither
  # the shared body module nor any runtime per-var module is ever purged.
  defp stabilise_body_modules(ns, ns_defs) do
    body_mod = ns_body_module(ns)
    Map.new(ns_defs, fn {name, defs} ->
      {name, Enum.map(defs, fn d -> put_elem(d, 4, body_mod) end)}
    end)
  end

  # The single shared body module for a namespace: `BeamLisp.Ns.Body.<Ns>`,
  # parallel to the shim `BeamLisp.Ns.<Ns>` and the init `BeamLisp.Ns.Init.<Ns>`.
  defp ns_body_module(ns) do
    segments = ns |> String.split(".") |> Enum.map(&Macro.camelize/1)
    Module.concat([BeamLisp.Ns, "Body" | segments])
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

  # Compile a block of several `defmodule`s in ONE invocation and return every
  # `{module, beam}` pair, in the order the compiler emitted them. Emitting a
  # namespace's ~130 body modules with one `Code.compile_quoted/2` call each
  # spun the compiler up per module and made a full build take minutes; one
  # call for the whole block restores near-single-module cost.
  defp compile_block!(block, filename) do
    prev = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      case Code.compile_quoted(block, filename) do
        [] -> raise "AOT: compiling a namespace produced no module"
        mods -> mods
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
