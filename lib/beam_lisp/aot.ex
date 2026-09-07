defmodule BeamLisp.AOT do
  @moduledoc """
  Ahead-of-time compilation of beam-lisp source into real BEAM modules.

  Interactive `defn` builds its per-namespace module at runtime via
  the legacy host module builder (see `BeamLisp.Link`); that needs a live compiler in
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
      path |> BeamLisp.Loader.read_source() |> compile_source(Keyword.put_new(opts, :file, path))
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

    # A compilation unit starts its fresh-name counter at zero, so the beams
    # it emits are a function of its source alone (reproducible across runs
    # and across serial/parallel builds). Both compilers share the counter.
    Compiler.reset_fresh!()

    # The source path rides along so an AOT-compiled module's line table
    # names the .bl file. These .beam files persist and are what a
    # production stack trace hits, so this is the attribution that
    # matters most — an eval module is transient, this is not.
    file = Keyword.get(opts, :file)

    forms = Reader.read_string(source, file)

    # PRE-LINK every top-level defn in the unit before compiling any form.
    # A call to a defn defined LATER in the same file would otherwise compile
    # to a slow `RT.invoke(fetch …)` in a fresh VM but a direct call in a VM
    # that had compiled the file before (the link survives): same source, two
    # beams, and the first build the slower. The ns of a form is the ns the
    # preceding `(ns …)` declared, tracked here exactly as the compile pass
    # will track it. Both compilers implement `prelink_defn`; genesis is
    # called because the seam (`Compiler.compile/2`) is per-form and this is
    # per-unit — the two are byte-parity anyway (the oracle pins it).
    Enum.reduce(forms, "user", fn form, ns ->
      case ns_decl(form) do
        nil -> Compiler.prelink_defn(form, ns); ns
        declared -> declared
      end
    end)

    {value_defs, touched, ns_meta} =
      forms
      |> Enum.reduce({%{}, MapSet.new(), %{}}, fn form, {vdefs, nss, nsmeta} ->
        ns = Env.current_ns()
        vdefs = capture_value_def(vdefs, form, ns)
        nsmeta = capture_ns_decl(nsmeta, form)
        # `eval_form` wraps its own compile step in the diagnostic. Thread the
        # source `file` into the env so a compiler crash on this form is
        # reported with file:line + the offending form, instead of a bare
        # Erlang `badarg` ("not a tuple") that names nothing.
        _ = Compiler.eval_form(form, Map.put(%{Compiler.new_env() | ns: Env.current_ns()}, :file, file))
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

  # The namespaces the drift gate itself runs on (`ns_closure_hash/1` →
  # `BuildPlan.key_for/3` → `build-plan` and its requires). Vetting one of
  # THESE by closure hash would ask the gate to load what it is vetting, and
  # the loader's cycle guard turns that into `undefined var: build-plan/…`.
  # They are boot-tier by construction; naming them here keeps that true
  # even where `Tiers.boot_namespaces/0` cannot see the source tree.
  @gate_namespaces ~w(build-plan source-graph ns-interface reader-node)

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

    # `Code.ensure_loaded?/1` is authoritative: it loads the module from the
    # code path (or confirms it in memory) and answers true/false. The older
    # `code_path_module?/1` (`:code.which/1`) pre-check is dropped: after a fresh
    # `Bootstrap.install!/1` copies a seed beam into ebin, `:code.which/1` can
    # still answer `:non_existing` from a cache populated before the copy, which
    # false-negatived the whole AOT branch and dropped a valid seed beam to the
    # (now genesis-less) SOURCE path. `Code.ensure_loaded?/1` reflects reality.
    if Code.ensure_loaded?(mod) and
         function_exported?(mod, :__bl_init__, 0) do
      # Fast path BEFORE the lock: require cycles (A's __bl_init__ requires
      # A) are cut by the mark-first protocol below, and that cut must not
      # depend on re-acquiring the same trans lock from the same process.
      cond do
        # Already interned in THIS VM. It was drift-vetted when first loaded
        # (the `stale?` branch below), so trust it — no per-call re-hash.
        Env.loaded_ns?(ns) ->
          :loaded

        # DRIFT GATE (Wave 1 / L2): the on-disk beam no longer matches its
        # source (or a different toolchain built it). Return `:no_module` so
        # `Loader` falls to the SOURCE path, which reinterns via `Link.defvar`
        # — an in-place hot swap that shadows the stale beam and closes the
        # `undefined var` window it caused. Strict mode raises inside `stale?/2`.
        stale?(ns, mod) ->
          :no_module

        true ->
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
        #
        # The lock + `:global` wrap are the async-fork fixes (PLAN-047 W1):
        # two forks requiring the same AOT namespace concurrently raced the
        # replay, and the replay's interns landed in the CALLER's fork — every
        # other process then missed the vars (`undefined var: relay.keys/create`
        # under BL_ASYNC=1). A required namespace is LIBRARY code: it interns
        # at `:global`, once, VM-wide — same rule as the source path.
        :global.trans({{:bl_load, mod}, self()}, fn ->
          if Env.loaded_ns?(ns) do
            :loaded
          else
            BeamLisp.Loader.Server.run(fn ->
              Env.with_env(:global, fn ->
                mod.__bl_init__()
                # Mark AFTER the replay — see Loader.do_load; cycle safety
                # is the :bl_loading set, not the mark.
                Env.mark_loaded(ns)
              end)
            end)

            :loaded
          end
        end)
      end
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
      # the legacy host module builder, and `:code.which/1` reports it loaded — it returns
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

    unless Process.whereis(BeamLisp.Loader.Server) do
      {:ok, _} = BeamLisp.Loader.Server.start_link([])
    end

    BeamLisp.init()
    maybe_load_core_backend()
    :ok
  end
  # Canonical AOT has one backend. Loading `lower` also loads its `anf`
  # dependency; readiness failures remain explicit at the descriptor boundary.
  defp maybe_load_core_backend do
    BeamLisp.Loader.ensure_loaded("lower")
    :ok
  end
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
  defp capture_value_def(vdefs, {:list, [{:symbol, "def"}, {:meta, name_form, m} | rest]}, ns) do
    # A `^:per-env` marked value def must replay as a per-env descriptor, not an
    # eager intern — carry the flag past the name-meta peel (which otherwise
    # discards `m`). Every other marker (e.g. `^:private`) is metadata only and
    # does not change how the value is registered.
    # is_map-ok: reader metadata is a plain map by construction, never a struct
    if is_map(m) and m[:"per-env"] == true do
      case rest do
        [init] -> put_value_def(vdefs, ns, bare_name(name_form), nil, init, per_env: true)
        [doc, init] when is_binary(doc) -> put_value_def(vdefs, ns, bare_name(name_form), doc, init, per_env: true)
        _ -> vdefs
      end
    else
      capture_value_def(vdefs, {:list, [{:symbol, "def"}, name_form | rest]}, ns)
    end
  end

  # DEFINE-BY-INTERNING forms, replayed whole.
  #
  # `defn`/`defmacro` become real functions in the emitted module, so the
  # `fn_ops` above reconstruct them. These do not: each one builds something
  # at EVAL time — a gen_server module via the legacy host module builder, a record's
  # constructor and accessors, a protocol's dispatch table — and interns the
  # result. An AOT build wrote none of it to disk and nothing recreated it,
  # so the namespace loaded cleanly and then failed at first use:
  # "undefined var: reel.store/store", "undefined var:
  # datom.store-fjall/->FjallStore". The same shape as the `defnative` hole
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

  defp capture_value_def(vdefs, {:list, [{:symbol, head} | _]} = form, ns)
       when is_binary(head) do
    # See through defining macros: `(defsmell …)`, `(defrule …)` expand
    # to `def` — capture the EXPANSION, so a macro-produced definition
    # replays at `__bl_init__` exactly like a literal one.
    case BeamLisp.Compiler.macroexpand_1(form, ns) do
      ^form -> vdefs
      expanded -> capture_value_def(vdefs, expanded, ns)
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
  # The namespace a top-level `(ns NAME …)` form declares, else nil.
  defp ns_decl({:meta, inner, _}), do: ns_decl(inner)
  defp ns_decl({:list, [{:symbol, "ns"}, name_form | _]}) do
    case name_form do
      {:meta, {:symbol, n}, _} -> n
      {:symbol, n} -> n
      _ -> nil
    end
  end
  defp ns_decl(_), do: nil

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


  defp put_value_def(vdefs, ns, name, doc, init, opts \\ []) do
    per_env? = Keyword.get(opts, :per_env, false)

    entries =
      vdefs
      |> Map.get(ns, [])
      |> Enum.reject(fn {n, _, _, _} -> n == name end)

    Map.put(vdefs, ns, entries ++ [{name, doc, init, per_env?}])
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
    ns_defs = stabilise_body_modules(ns, Env.ns_defs(ns))
    source_hash = if file, do: ns_closure_hash(ns, file), else: nil
    compiler_key = BeamLisp.AOTCache.compiler_key()

    {init_clause, companion_descriptor} = build_init_ast(ns, mod, ns_defs, value_defs, ns_meta)

    provenance_clause =
      Emit.function_clause(
        :__bl_provenance__,
        %{op: :tuple, elems: [Emit.lit(source_hash), Emit.lit(compiler_key)], ann: %{}}
      )

    namespace_clauses =
      (Emit.shim_clauses(ns_defs) ++ [provenance_clause, init_clause])
      |> Enum.map(fn clause ->
        ann = Map.merge(%{file: filename, line: 1}, Map.get(clause.body, :ann, %{}))
        %{clause | body: Map.put(clause.body, :ann, ann)}
      end)
    namespace_descriptor =
      Emit.descriptor_for(mod, namespace_clauses, [bl_source_hash: source_hash, bl_compiler_key: compiler_key], %{file: filename})

    body_descriptors =
      for {body_mod, clauses} <- Emit.body_modules(ns_defs) do
        Emit.descriptor_for(body_mod, clauses, [], %{file: filename})
      end

    companion_descriptor = if companion_descriptor,
      do: Map.put(companion_descriptor, :ann, %{file: filename}), else: nil

    # Compile and validate every byte before the first code load or disk write.
    # This is the pre-publication failure boundary: Env and the stable namespace
    # module still describe the previous successful generation.
    beams =
      (body_descriptors ++ List.wrap(companion_descriptor) ++ [namespace_descriptor])
      |> Enum.map(&Emit.compile_descriptor/1)

    body_mods = MapSet.new(body_descriptors, & &1.name)
    {body_beams, public_beams} = Enum.split_with(beams, fn {m, _} -> MapSet.member?(body_mods, m) end)

    Enum.each(body_beams, &Emit.load_binary!(&1, filename))

    try do
      Enum.each(public_beams, &Emit.load_binary!(&1, filename))
    rescue
      error ->
        affected = Enum.map(public_beams, &elem(&1, 0))
        raise "AOT publication failed for #{inspect(affected)}: #{Exception.message(error)}"
    end

    # Public API returns the namespace first; write its bodies afterwards so
    # bootstrap's companion freshness check cannot mistake them for seed code.
    beams
    |> Enum.sort_by(fn {emitted_mod, _} -> if emitted_mod == mod, do: 0, else: 1 end)
    |> Enum.map(fn {emitted_mod, beam} -> write_beam(emitted_mod, beam, output_dir) end)
  end

  # The canonical emitter is mandatory after bootstrap; no Elixir fallback exists.

  # Compile-to-disk for one module; replacement preserves cache-linked inodes.
  defp write_beam(mod, beam, output_dir) do
    path = Path.join(output_dir, Atom.to_string(mod) <> ".beam")
    File.mkdir_p!(output_dir)
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(tmp, beam)
      File.rename!(tmp, path)
      {mod, path}
    after
      File.rm(tmp)
    end
  end

  @doc """
  The per-namespace freshness hash (FEAT-030, tier-2): a digest over `ns` and
  the content of its transitive `:require` closure, resolved against the LIVE
  source path. This is the value stamped into a beam at emit and recomputed by
  the runtime drift gate — they match iff neither `ns` nor anything it requires
  has changed since the beam was built.

  Returns `nil` when `ns` has no resolvable source (a packaged release ships no
  `.bl`) — the loader trusts an unstampable/unresolvable beam rather than
  judging it stale. Requires OUTSIDE the source set (the ambient `core`/`sugar`
  prelude, the reader providers) are deliberately NOT walked here: they are
  covered by `BeamLisp.AOTCache.compiler_key/0` (tier-1), so a change there
  moves the toolchain key and invalidates every beam regardless of this hash.
  """
  @spec ns_closure_hash(binary) :: binary | nil
  def ns_closure_hash(ns) when is_binary(ns), do: ns_closure_hash(ns, nil)

  @doc """
  `ns_closure_hash/1` with an explicit source `file` for `ns` (the emit path).

  At emit the compiling file's path is known, but `ns` may NOT resolve by name
  through the ambient search dirs yet — an isolated `--out` build compiles
  `<dir>/drift/fixture.bl` with only `<dir>/drift` on the load path, so the ns
  `drift.fixture` (which resolves against `<dir>`) is unreachable and the hash
  would come back `nil` (an unstampable beam). Seeding `ns`'s own
  `{hash, requires}` directly from `file` removes that dependency on name
  resolution for the primary ns; its transitive requires still resolve by name
  the ordinary way (they are siblings on the load path). The runtime gate calls
  the `/1` form (no file) and resolves the same ns to the same bytes, so the two
  hashes agree.
  """
  @spec ns_closure_hash(binary, binary | nil) :: binary | nil
  def ns_closure_hash(ns, file) when is_binary(ns) do
    # Fresh per-call resolution cache: a namespace's source is read at most
    # once WITHIN this computation, never carried ACROSS calls (that would
    # serve a stale key after an edit — the exact false-fresh the drift gate
    # exists to prevent). Cleared on entry, dropped on exit.
    Process.put(:bl_source_info_cache, %{})

    try do
      resolve = fn n -> source_content_cached(n) end
      seed = if file && File.exists?(file), do: {ns, BeamLisp.Loader.read_source(file)}
      BeamLisp.BuildPlan.key_for(ns, resolve, seed)
    after
      Process.delete(:bl_source_info_cache)
    end
  end

  # Resolve a namespace's source CONTENT at most once per key computation.
  defp source_content_cached(ns) do
    cache = Process.get(:bl_source_info_cache, %{})

    case Map.fetch(cache, ns) do
      {:ok, v} ->
        v

      :error ->
        v = BeamLisp.Loader.source_content(ns)
        Process.put(:bl_source_info_cache, Map.put(cache, ns, v))
        v
    end
  end

  # `ns_meta` is the per-namespace map captured from the `(ns …)` form:
  # `%{aliases:, refers:, requires:}`.
  defp build_init_ast(ns, mod, ns_defs, value_defs, ns_meta) do
    aliases = Map.get(ns_meta, :aliases, [])
    refers = Map.get(ns_meta, :refers, [])
    refer_alls = Map.get(ns_meta, :refer_alls, [])
    requires = Map.get(ns_meta, :requires, [])

    ns_ops =
      Enum.map(requires, &Emit.remote(BeamLisp.Loader, :ensure_loaded, [Emit.lit(&1)])) ++
        Enum.map(aliases, fn {alias_, target} ->
          Emit.remote(Env, :add_alias, Enum.map([ns, alias_, target], &Emit.lit/1))
        end) ++
        Enum.map(refers, fn {sym, target} ->
          Emit.remote(Env, :add_refer, Enum.map([ns, sym, target], &Emit.lit/1))
        end) ++
        Enum.map(refer_alls, fn target ->
          Emit.remote(Env, :add_refer_all, [Emit.lit(ns), Emit.lit(target)])
        end)

    native_ops =
      case BeamLisp.Native.declaration(ns) do
        nil -> []
        {crate, signatures} ->
          [Emit.remote(BeamLisp.Native, :declare, Enum.map([ns, crate, signatures], &Emit.lit/1))]
      end

    fn_ops =
      Enum.flat_map(ns_defs, fn {name, defs} ->
        fixed = for d <- defs, elem(d, 0) == :fixed, do: {elem(d, 1), elem(d, 2)}
        variadic = Enum.find_value(defs, fn d -> if elem(d, 0) == :variadic, do: {elem(d, 1), elem(d, 2)} end)

        ops = [
          Emit.remote(Env, :intern, [Emit.lit(ns), Emit.lit(name),
            Emit.remote(Emit, :fn_value, Enum.map([mod, fixed, variadic], &Emit.lit/1))]),
          Emit.remote(Env, :put_link, Enum.map([ns, name, {mod, Map.new(fixed), variadic}], &Emit.lit/1))
        ]

        case Env.meta(ns, name) do
          # is_map-ok: Env metadata is structural host data, not a language collection.
          {:ok, meta} when is_map(meta) and map_size(meta) > 0 ->
            ops ++ [Emit.remote(Env, :put_meta, Enum.map([ns, name, meta], &Emit.lit/1))]
          _ -> ops
        end
      end)

    compiler_env = Compiler.new_env(ns)

    value_ops =
      Enum.flat_map(value_defs, fn {name, doc, init_form, per_env?} ->
        init_node = compile_initializer(init_form, compiler_env)

        register =
          if per_env? do
            Emit.remote(Env, :define_per_env, [Emit.lit(ns), Emit.lit(name), Emit.closure(init_node)])
          else
            Emit.remote(Env, :intern, [Emit.lit(ns), Emit.lit(name), init_node])
          end

        if doc do
          [register, Emit.remote(Env, :put_meta, [Emit.lit(ns), Emit.lit(name), Emit.lit(%{doc: doc})])]
        else
          [register]
        end
      end)

    init_mod = init_module_for(ns)

    companion_descriptor =
      case value_ops do
        [] -> nil
        ops -> Emit.descriptor_for(init_mod, [Emit.function_clause(:__bl_init_values__, Emit.sequence(ops ++ [Emit.lit(:ok)]))])
      end

    value_call_ops =
      if companion_descriptor,
        do: [Emit.remote(init_mod, :__bl_init_values__, [])],
        else: []

    body =
      Emit.sequence(
        ns_ops ++ native_ops ++ fn_ops ++ value_call_ops ++
          [Emit.remote(Env, :put_ns_defs, [Emit.lit(ns), Emit.lit(ns_defs)]), Emit.lit(:ok)]
      )

    {Emit.function_clause(:__bl_init__, body), companion_descriptor}
  end

  defp compile_initializer(form, env) do
    unless Code.ensure_loaded?(BeamLisp.Ns.Compiler) and
             function_exported?(BeamLisp.Ns.Compiler, :"compile-node", 2) do
      raise "initializer compiler unavailable: BeamLisp.Ns.Compiler.compile-node/2 is not ready"
    end

    apply(BeamLisp.Ns.Compiler, :"compile-node", [form, env])
  end
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


  # DRIFT GATE (Wave 1 / L2). A compiled beam is trusted only when it still
  # matches the source it was built from. Reads the beam's `__bl_provenance__/0`
  # stamp (source hash + toolchain key) and compares to the LIVE source.
  #
  #   source absent (prod release: no `.bl` ships)  -> NOT stale (trust the beam;
  #                                                    nothing to compare against)
  #   beam unstampable (older emitter, in-memory)    -> NOT stale (trust; a beam
  #                                                    with no stamp predates this
  #                                                    gate and has no claim to check)
  #   hash + compiler_key match                       -> NOT stale (fresh)
  #   mismatch, dev/source present                    -> STALE
  #
  # A `true` return routes the caller to `:no_module`, i.e. the SOURCE path,
  # which reloads via `Link.defvar` — an in-place hot swap that shadows the
  # stale beam immediately, closing the exact `undefined var` window the stale
  # beam caused. Set `BEAM_LISP_AOT_STRICT=1` to REFUSE LOUD instead of healing
  # (for a packaged build that must never silently fall back to source).
  #
  # Content hash ONLY, never mtime: mtime is scrambled by git checkout, worktrees,
  # tar, and hardlinks; the content hash survives all of them and equals the Mix
  # manifest's own hash for the same bytes.
  defp stale?(ns, mod) do
    cond do
      # BOOTSTRAP STAGING: a mismatched committed seed was installed as a
      # previous-generation bootstrap stage (BeamLisp.Bootstrap.install!/1 sets
      # `:bootstrap_staging` to the namespaces it provides). Those staged beams
      # are a VALID compiler even though their key differs from the current
      # toolchain — interning replays def VALUES, it does not recompile — so
      # trust them for interning. Without this the gate would route `compiler`/
      # `reader-node` to the SOURCE path, which, with genesis deleted, has no
      # compiler to build them. Once the build re-emits these under the current
      # key the staged copies are superseded and a matching install clears the
      # flag; so the trust is scoped to exactly the staged namespaces and only
      # while staging is in effect.
      ns in staging_namespaces() ->
        false

      true ->
        stale_by_provenance?(ns, mod)
    end
  end

  defp staging_namespaces do
    case Application.get_env(:beam_lisp, :bootstrap_staging, nil) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp stale_by_provenance?(ns, mod) do
    case beam_provenance(mod) do
      nil ->
        false

      {beam_hash, beam_key} ->
        cond do
          # A BOOT-tier namespace's freshness IS the toolchain key: every file
          # under `priv/boot/` hashes into `compiler_key/0`, so a key match
          # means the source it was built from is byte-for-byte the source on
          # disk. No closure hash to compute — and none MAY be computed here:
          # the closure hash is answered by `source-graph`, itself a boot
          # namespace, so asking would recurse into the load this gate vets.
          ns in BeamLisp.Tiers.boot_namespaces() or ns in @gate_namespaces ->
            # No toolchain sources on disk (an escript or release away from
            # its checkout) ⇒ nothing to compare against: trust the beam, as
            # the closure branch does when no source resolves.
            BeamLisp.Tiers.boot_namespaces() != [] and
              beam_key != BeamLisp.AOTCache.compiler_key()

          true ->
            # The live tier-2 closure hash: this ns plus its transitive
            # `:require` closure. `nil` when no source resolves (packaged
            # release) — trust the beam. Computed the SAME way emit stamped it
            # (`ns_closure_hash/1` in both), so a fresh beam compares equal.
            src_hash = ns_closure_hash(ns)

            cond do
              is_nil(src_hash) -> false
              beam_hash == src_hash and beam_key == BeamLisp.AOTCache.compiler_key() -> false
              strict_aot?() -> raise stale_beam_error(ns, mod, beam_hash, src_hash)
              true -> true
            end
        end
    end
  end

  # `{source_hash, compiler_key}` from a compiled shim, or `nil` when the module
  # carries no stamp (predates L1) or its code cannot be loaded. `ensure_loaded/1`
  # already made the module code-loadable, so this is a plain call — NO
  # `__bl_init__/0`, no eval.
  defp beam_provenance(mod) do
    if function_exported?(mod, :__bl_provenance__, 0) do
      case mod.__bl_provenance__() do
        {nil, _} -> nil
        {_, _} = prov -> prov
        _ -> nil
      end
    else
      nil
    end
  end

  defp strict_aot?, do: System.get_env("BEAM_LISP_AOT_STRICT") in ["1", "true"]

  defp stale_beam_error(ns, mod, beam_hash, src_hash) do
    "stale AOT beam for #{ns} (#{inspect(mod)}): compiled from source " <>
      "#{short(beam_hash)}, current source hashes #{short(src_hash)}. " <>
      "Run `mix compile.beam_lisp --force` (or `mix clean`) to rebuild."
  end

  defp short(nil), do: "<none>"
  defp short(h), do: String.slice(h, 0, 12)

  defp default_output_dir do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix.Project, :compile_path, 0) do
      Mix.Project.compile_path()
    else
      raise ArgumentError,
            "BeamLisp.AOT needs an :output_dir (no Mix project loaded to default to compile_path)"
    end
  end
end
