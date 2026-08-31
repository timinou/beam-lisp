defmodule BeamLisp.Compiler do
  @moduledoc """
  Lowers reader forms to Elixir quoted expressions.

  This is the clever turn: Elixir's compiler is the backend. A
  beam-lisp `fn` becomes a real Elixir `fn`, a call becomes
  `apply/2`, and `Module/function` in call position becomes a real
  remote call — so beam-lisp code is BEAM bytecode calling BEAM
  bytecode, with no FFI in between.

  Rules:

    * `Mod/fun` with an uppercase prefix calls an Elixir module:
      `(IO/puts "hi")` → `apply(IO, :puts, ["hi"])`
    * `mod/fun` with a lowercase prefix calls an Erlang module:
      `(lists/reverse [1 2])` → `apply(:lists, :reverse, [[1 2]])`
    * every other call head resolves to a local or a var in
      `BeamLisp.Env` and is invoked with `apply/2`
    * a keyword in call position looks itself up: `(:a m)` → `Map.get(m, :a)`

  `loop`/`recur` compile to self-application, which the BEAM
  tail-call-optimizes; `recur` outside tail position is a
  compile-time error, as in jank and Clojure.

  Compile-time environment:

    * `:ns` — current namespace for var resolution
    * `:locals` — `%{name => Elixir AST var}`
    * `:recur` — `nil | %{self: var, arity: n}`, the innermost loop target
    * `:tail` — whether this position is a tail position

  Runtime values live in `BeamLisp.Env`.
  """

  import BeamLisp.Guards, only: [is_bl_map: 1]

  alias BeamLisp.Env
  alias BeamLisp.Reader

  @special_forms ~w(ns def fn defn defn- defmacro defmulti defmethod defnative defprotocol satisfies? extend-type extend-protocol defrecord deftype reify let loop recur if do quote syntax-quote receive throw try loop* let* fn* defserver)

  @doc "A fresh top-level compile-time environment."
  def new_env(ns \\ Env.current_ns()), do: %{ns: ns, locals: %{}, recur: nil, tail: true}

  @doc """
  Read, compile and evaluate every form in `source`. Returns the last value.

  `file` is the source path (or nil) attached to each form's position
  metadata, so generated modules and compile errors can name it. The
  position-aware reader entry is used deliberately: `read_all`/`read_one`
  deep-unwrap positions for callers that ignore them, and would strip the
  very information this path exists to carry.
  """
  def eval_string(source, env \\ new_env(), file \\ nil) do
    # Enter the env's namespace; from there, per-form re-reads track
    # any `ns` switches, exactly as defmacro side effects are seen.
    Env.in_ns(env.ns)

    source
    |> Reader.read_string(file)
    # `eval_form` wraps its OWN compile step in the diagnostic, so a compiler
    # crash on any form is already reported with file:line + source. Nothing
    # to wrap here — wrapping the whole `eval_form` (compile AND run) would
    # mislabel a runtime error as a compile error.
    |> Enum.map(&eval_form(&1, %{env | ns: Env.current_ns()}))
    |> List.last()
  end

  @doc """
  Compile one form to Elixir quoted and evaluate it.

  The form is compiled into a throwaway module rather than
  interpreted by `erl_eval` (which `Code.eval_quoted/3` uses):
  interpreted funs have no tail-call optimization, so `loop`/`recur`
  would grow the stack and turn quadratic. Compiled modules run at
  native speed with real TCO. Wave 3 gives these modules a managed
  lifecycle (purge/reuse) and an AOT counterpart.
  """
  def eval_form(form, env) do
    # Wrap ONLY compilation in the diagnostic — not evaluation. `eval_form`
    # both compiles the form and RUNS it; a failure while running (a `(throw
    # …)`, an arithmetic error, an undefined var resolved at run time) is the
    # program executing, and must keep its real type so callers can
    # `assert_raise` on it. Only a crash INSIDE `compile/2` is a compile error,
    # and that is what earns the located, source-quoted report.
    ast = BeamLisp.CompileDiagnostic.with_diagnostic(form, [file: env[:file]], fn -> compile(form, env) end)
    mod = Module.concat(BeamLisp.Eval, "M#{System.unique_integer([:positive])}")

    # Signature inference is disabled for the whole create+run scope: the
    # throwaway module itself, and any nested Module.create the form
    # performs at run time (defserver hosts, defn value modules). Elixir
    # 1.20's signature construction (Module.Types.Descr tuple intersections)
    # explodes on tuple-literal-dense generated code — one heavy defn
    # measured 93s with inference, 63ms without. There is no per-module
    # opt-out on <= 1.20; the `@compile no_type_check: true` previously
    # emitted here matches no known attribute and was silently ignored.
    prev_opts = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true, infer_signatures: false)

    try do
      Module.create(
        mod,
        quote do
          def run, do: unquote(ast)
        end,
        # Claim the form's own `.bl` file (and line) so the module's line
        # table points at the user's source, not beam-lisp's compiler. A
        # macro-built form with no position falls back to the old
        # behaviour.
        module_location(form, env) || Macro.Env.location(__ENV__)
      )

      mod.run()
    after
      Code.compiler_options(prev_opts)
    end
  end

  @doc "Compile one reader form to an Elixir quoted expression."

  # --- literals ---

  # Form metadata is the reader's source-location channel: unwrap the
  # wrapper, thread the position into the compile env, lower the bare form,
  # then stamp the form's line onto the resulting AST so Elixir propagates
  # it into the module's line table. The metadata never reaches a runtime
  # value (= and printing are unaffected); a form with no position compiles
  # identically to today, just without line attribution.
  def compile(form, env) do
    # THE CUTOVER SEAM. beam-lisp's compiler is written in beam-lisp
    # (priv/compiler.bl). Once that source is AOT-compiled into the
    # `BeamLisp.Ns.Compiler` module, THIS function delegates every form to it —
    # the language compiles itself. The Elixir `compile_elixir/2` below is the
    # GENESIS seed: the original hand-written lowering, kept for exactly two
    # jobs. (1) Bootstrap of last resort: on a fresh tree where the .bl seed is
    # not yet built, it compiles the first `Ns.Compiler` (after which each build
    # is compiled by the previous stage — the staged-bootstrap ladder). (2) The
    # differential oracle: `priv/self/oracle.bl` compiles a form with BOTH this
    # seed and the .bl compiler and asserts the ASTs are byte-identical, which
    # is the proof the two agree. So the seed is never dead code — it is the
    # floor the tower stands on and the yardstick it is measured against.
    #
    # Backend selection (`:beam_lisp, :compiler_backend`):
    #   :auto (default) — delegate to the .bl seed when it is loaded, else genesis
    #   :genesis        — always the Elixir seed (used to rebuild after a .bl
    #                     compiler change that an older seed cannot compile)
    #   :bl             — always the .bl seed (fail loudly if it is absent)
    if use_bl_compiler?() do
      apply(BeamLisp.Ns.Compiler, :compile, [form, env])
    else
      compile_elixir(form, env)
    end
  end

  # Whether to route `compile/2` through the self-hosted beam-lisp compiler.
  # `:auto` delegates whenever the AOT-built seed module is on the code path
  # and exports `compile/2`; on a fresh tree it is absent, so genesis runs and
  # builds it. The check is a cheap `function_exported?` (no Env work), so it
  # is fine on the hot compile path.
  defp use_bl_compiler? do
    case Application.get_env(:beam_lisp, :compiler_backend, :auto) do
      :genesis ->
        false

      :bl ->
        true

      :auto ->
        # Delegate only when the `compiler` namespace's vars are actually
        # INTERNED in this node's Env. The self-hosted `compile` reaches its
        # sibling vars (its own recursion, `macroexpand-1`, every `compile-*`
        # helper) through the Env var table, so they MUST exist before the
        # first delegated form or the fetch raises `undefined var`.
        #
        # Keying on the live interning state — not a persistent flag — is what
        # makes this self-consistent and leak-proof. `:persistent_term` is
        # node-global and `mix run`/`mix test` compile in the SAME node they
        # run in, so a flag set during the AOT compile phase would bleed into
        # the run phase where the ns may not be interned. `loaded_ns?` reflects
        # reality: interned ⇒ delegation resolves; not interned ⇒ genesis.
        Env.loaded_ns?("compiler")
    end
  end

  @doc """
  Ensure the self-hosted beam-lisp compiler is ready to serve `compile/2`.

  Interns the `compiler` namespace (runs its `__bl_init__`, which replays the
  compiler's own `def`s into the Env var table). Once interned, `compile/2`
  with the default `:auto` backend delegates every form to it — the language
  compiles itself. Idempotent and safe before the seed exists: if the compiler
  beam is not built (a fresh tree), loading is a no-op, the ns stays
  un-interned, and `compile/2` keeps running the genesis Elixir seed — which is
  exactly what compiles that seed in the first place. Returns `:bl` when the
  self-hosted compiler is now active, `:genesis` otherwise.
  """
  def enable_bl_backend do
    unless Env.loaded_ns?("compiler") do
      # Force genesis for the duration of this load: interning the compiler ns
      # replays its own forms, and until it is fully interned those forms must
      # be compiled by the seed, never by the half-built self-hosted compiler.
      prev = Application.get_env(:beam_lisp, :compiler_backend, :auto)
      Application.put_env(:beam_lisp, :compiler_backend, :genesis)

      try do
        BeamLisp.Loader.ensure_loaded("compiler")
      after
        Application.put_env(:beam_lisp, :compiler_backend, prev)
      end
    end

    if Env.loaded_ns?("compiler"), do: :bl, else: :genesis
  end

  @doc """
  The genesis (Elixir) compiler: lower one reader form to Elixir quoted AST.

  This is the original hand-written compiler. `compile/2` delegates to the
  self-hosted beam-lisp compiler once it is built; this stays as the bootstrap
  seed and as the differential oracle's yardstick. Callers that MUST have the
  Elixir lowering specifically (the oracle) call this directly.
  """
  def compile_elixir(form, env) do
    case form do
      {:meta, inner, m} ->
        # A form's metadata carries two kinds of key. Positional keys
        # (:line/:col/:file) are the reader's SOURCE-LOCATION channel: they
        # thread into the compile env and stamp the BEAM line table, never
        # reaching a runtime value. Author keys (everything else -- e.g. a
        # hiccup `^{:key (:slug t)}`) are USER DATA and MUST survive onto the
        # value, exactly as in Clojure. Split the two: compile the bare form
        # with the position threaded, then, if any author key remains, wrap
        # the result in a runtime `with-meta` whose map VALUES are themselves
        # compiled (so `^{:key (:slug t)}` evaluates rather than quotes).
        {pos, user} = Map.split(m, [:line, :col, :file])
        penv = pos_env(env, pos)
        ast = inner |> do_compile(penv) |> stamp_line(penv)

        if map_size(user) == 0 do
          ast
        else
          meta_ast =
            {:%{}, [], Enum.map(user, fn {k, v} -> {k, compile_elixir(v, notail(penv))} end)}

          {{:., [], [{:__aliases__, [], [:BeamLisp, :FormMeta]}, :with_meta]}, [],
           [ast, meta_ast]}
        end

      _ ->
        form
        |> do_compile(env)
        |> stamp_line(env)
    end
  end

  defp do_compile(form, _env)
      when is_number(form) or is_binary(form) or is_boolean(form) or is_nil(form),
      do: form

  defp do_compile({:keyword, name}, _env), do: BeamLisp.AtomGuard.to_atom(name)

  defp do_compile({:vector, items}, env) do
    tuple_ast = {:{}, [], Enum.map(items, &compile_elixir(&1, notail(env)))}
    {:%, [], [{:__aliases__, [], [:BeamLisp, :Vector]}, {:%{}, [], [items: tuple_ast]}]}
  end

  defp do_compile({:map, kvs}, env) do
    # Keys go through `RT.hash_key/1`: metadata is invisible to `=`, so it
    # must be invisible to hashing too. Without this, `(get {v :x} [1 2])`
    # is nil for a `v` that compares EQUAL to `[1 2]` — the equality/hash
    # contract broken in the direction that is hardest to debug, since
    # every printed representation looks identical.
    {:%{}, [],
     Enum.map(kvs, fn {k, v} ->
       {quote(do: BeamLisp.RT.hash_key(unquote(compile_elixir(k, notail(env))))),
        compile_elixir(v, notail(env))}
     end)}
  end

  # A `#Name{...}` (or `#ns/Name{...}`) record literal: the reader emits
  # `{:record, name, kvs}`. Resolve the name to its struct module at
  # runtime and build the record from the given (known) fields.
  defp do_compile({:record, name, kvs}, env) do
    map_ast = compile_elixir({:map, kvs}, notail(env))

    quote do
      BeamLisp.Record.literal(unquote(env.ns), unquote(name), unquote(map_ast))
    end
  end

  defp do_compile({:set, items}, env) do
    members = Enum.map(items, &compile_elixir(&1, notail(env)))

    quote do
      BeamLisp.Set.new(unquote(members))
    end
  end

  # --- symbols ---

  defp do_compile({:symbol, name}, env) do
    cond do
      local?(env, name) ->
        local(env, name)

      String.contains?(name, "/") ->
        case slash_target(env, name) do
          {:var, ns, var} -> private_fetch_quoted(env, ns, var)
          {:remote, module, fun} -> remote_value_quoted(module, fun)
        end

      true ->
        fetch_quoted(env.ns, name)
    end
  end

  # --- calls and special forms ---

  defp do_compile({:list, []}, _env), do: []

  # The reader wraps the head of a call form in FormMeta; peel it so
  # special-form / keyword / symbol dispatch sees the bare head. The list
  # form's own position (already in env) stands for the call site.
  defp do_compile({:list, [{:meta, head, _} | args]}, env) do
    do_compile({:list, [head | args]}, env)
  end

  defp do_compile({:list, [{:symbol, head} | args]}, env) when head in @special_forms do
    compile_special(head, args, env)
  end

  defp do_compile({:list, [{:keyword, kw} | args]}, env) do
    arg_asts = Enum.map(args, &compile_elixir(&1, notail(env)))

    quote do
      BeamLisp.RT.invoke(unquote(String.to_atom(kw)), unquote(arg_asts))
    end
  end

  # Deftype field access: `(.-x obj)` and `(.x obj)` both read field `x`.
  # Records deliberately have no field-access surface — keyword lookup is
  # their access path — so this reaches only deftype instances.
  defp do_compile({:list, [{:symbol, ".-" <> field} | args]}, env)
       when field != "" and length(args) == 1,
       do: compile_deftype_field(field, args, env)

  defp do_compile({:list, [{:symbol, "." <> field} | args]}, env)
       when field != "" and length(args) == 1,
       do: compile_deftype_field(field, args, env)

  defp do_compile({:list, [{:symbol, name} | args]}, env) do
    cond do
      local?(env, name) ->
        invoke_quoted(local(env, name), compile_args(args, env))

      true ->
        # Macros resolve at compile time against the live registry,
        # including through aliases (a/macro → target-ns/macro).
        # Macro args are DATA: they must not be compiled before
        # expansion (a `recur` or an unbound symbol inside them is
        # the macro's business, not ours).
        case macro_for(env.ns, name) do
          {:ok, macro_fn} ->
            compile_elixir(expand_macro(macro_fn, {:list, [{:symbol, name} | args]}, args, env), env)

          :error ->
            arg_asts = compile_args(args, env)

            linked =
              case Env.link(env.ns, core_qualified(name)) do
                {:ok, info} -> linked_call(info, arg_asts)
                :error -> nil
              end

            cond do
              linked ->
                reject_private_link(env, name)
                linked

              String.contains?(name, "/") ->
                case slash_target(env, name) do
                  {:var, ns, var} ->
                    invoke_quoted(private_fetch_quoted(env, ns, var), arg_asts)

                  {:remote, module, fun} ->
                    quote do
                      apply(unquote(module), unquote(fun), unquote(arg_asts))
                    end
                end

              true ->
                invoke_quoted(fetch_quoted(env.ns, name), arg_asts)
            end
        end
    end
  end

  defp do_compile({:list, [head | args]}, env) do
    arg_env = notail(env)
    invoke_quoted(compile_elixir(head, arg_env), Enum.map(args, &compile_elixir(&1, arg_env)))
  end

  defp compile_args(args, env) do
    arg_env = notail(env)
    Enum.map(args, &compile_elixir(&1, arg_env))
  end

  # Direct remote call to a linked fn var: fixed arity hits the def
  # itself; variadic splits args into fixed + a rest list for the
  # mangled def. Returns nil when no clause matches (caller falls
  # back to the invoke path).
  defp linked_call({mod, fixed, variadic}, arg_asts) do
    arity = length(arg_asts)

    case fixed do
      %{^arity => fname} ->
        {{:., [], [mod, fname]}, [], arg_asts}

      _ ->
        case variadic do
          {min, vfname} when arity >= min ->
            {fargs, rargs} = Enum.split(arg_asts, min)
            {{:., [], [mod, vfname]}, [], fargs ++ [rargs]}

          _ ->
            nil
        end
    end
  end

  # --- special forms ---

  defp compile_special("quote", [form], _env), do: Macro.escape(datum(form))

  # (ns foo.bar (:require [other.ns :as o] [third.ns :refer [x]]))
  # Emits runtime registry ops; the *next* form's compile then sees
  # the new ns via Env.current_ns (eval_string re-reads it per form).
  defp compile_special("ns", [name_form | clauses], env) do
    name = name_of(name_form)

    specs =
      Enum.flat_map(clauses, fn clause ->
        case unwrap_meta(clause) do
          {:list, [{:keyword, "require"} | require_specs]} -> require_specs
          other -> raise "ns supports only :require clauses, got: #{inspect(other)}"
        end
      end)

    {loads, aliases, refers} =
      Enum.reduce(specs, {[], [], []}, fn spec, {loads, aliases, refers} ->
        {target, as_alias, refer_syms} = parse_require_spec(spec)
        load = quote do: BeamLisp.Loader.ensure_loaded(unquote(target))

        alias_op =
          if as_alias do
            [quote do: BeamLisp.Env.add_alias(unquote(name), unquote(as_alias), unquote(target))]
          else
            []
          end

        refer_ops =
          if refer_syms == :all do
            # The blanket form has to wait for runtime: which names
            # exist is decided by the require emitted just above, and a
            # compile-time expansion would see the namespace as it was
            # before its file loaded. Privacy is enforced inside
            # add_refer_all/2 for the same reason.
            [quote do: BeamLisp.Env.add_refer_all(unquote(name), unquote(target))]
          else
            for sym <- refer_syms do
              # Clojure refuses to refer a private var (`var: #'a/f is not
              # public`); mirror that here so a referred name can never
              # smuggle a private var past the unqualified lookup path.
              if private_var?(target, sym) do
                compile_error(env, "var #{target}/#{sym} is not public")
              else
                quote do: BeamLisp.Env.add_refer(unquote(name), unquote(sym), unquote(target))
              end
            end
          end

        {[load | loads], alias_op ++ aliases, refer_ops ++ refers}
      end)

    quote do
      ns = unquote(name)
      # Declare before requiring. A namespace exists from the moment its
      # (ns …) form runs, not from its first def, so a required file that
      # circles back to this one finds it already present instead of
      # searching the disk for a file that is mid-load.
      BeamLisp.Env.declare_ns(ns)
      BeamLisp.Env.in_ns(ns)
      unquote(Enum.reverse(loads))
      unquote(block(aliases))
      unquote(block(refers))
      String.to_atom(ns)
    end
  end

  defp compile_special("def", [name_form, init], env),
    do: compile_def(name_of(name_form), compile_elixir(init, notail(env)), env, nil, name_meta(name_form))

  defp compile_special("def", [name_form, doc, init], env) when is_binary(doc),
    do: compile_def(name_of(name_form), compile_elixir(init, notail(env)), env, doc, name_meta(name_form))

  defp compile_special("fn", args, env) do
    case args do
      # A named fn binds its own name to the fn value inside its body, so
      # `(fn step [n] (step (- n 1)))` can recurse (doseq's builder does).
      [first | clauses] ->
        case unwrap_meta(first) do
          {:symbol, name} -> compile_fn(fn_clauses(clauses, env), env, name: name)
          _ -> compile_fn(fn_clauses(args, env), env)
        end

      clauses ->
        compile_fn(fn_clauses(clauses, env), env)
    end
  end

  defp compile_special("defn", [name_form | rest], env) do
    compile_def_special("defn", name_form, rest, env, false)
  end

  # `defn-` is `defn` with `^:private` metadata on the var, exactly as
  # in Clojure. The flag is threaded to compile_defn so it lands in the
  # var's metadata map (`%{private: true}`) alongside any docstring;
  # resolution then enforces it (see private_fetch_quoted/3).
  defp compile_special("defn-", [name_form | rest], env) do
    compile_def_special("defn-", name_form, rest, env, true)
  end

  # A macro is a fn stored under a tag; calls to it expand at
  # compile time (see macro_for/expand_macro below).
  defp compile_special("defmacro", [name_form | rest], env) do
    name = name_of(name_form)
    {doc, rest} = split_docstring(rest)

    cond do
      rest == [] ->
        compile_error(env, "defmacro #{name}: expected at least one parameter vector")

      match?([h | _] when is_binary(h), rest) ->
        compile_error(
          env,
          "defmacro #{name}: expected a parameter vector, got a string literal (a docstring must be followed by clauses)"
        )

      per_env_attr?(name_meta(name_form)) ->
        # A macro expands at COMPILE time; a per-env (runtime, per-consumer)
        # instance is meaningless for one. Reject explicitly.
        compile_error(env, "defmacro " <> name <> ": ^:per-env is only valid on a `def` value, not a macro")

      true ->
        compile_def(
          name,
          {:{}, [], [:"$macro", compile_fn(macro_clauses(fn_clauses(rest, env)), env, nil_rest: true)]},
          env,
          doc,
          name_meta(name_form)
        )
    end
  end

  # --- OTP servers ---
  #
  # `(defserver name (init [arg] body…) (handle-call PAT [from state] body…) …)`
  # compiles to a genuine `:gen_server` behaviour module: real callbacks, real
  # `{:reply, v, state}` returns, real supervision and `:observer` support —
  # never a lookalike. Each callback clause is a beam-lisp fn body;
  # `handle-call`/`handle-cast`/`handle-info` clauses carry a message pattern
  # that dispatches across multiple `handle_*/N` defs, emitted adjacently
  # (Elixir warns and the build breaks otherwise). The generated module is
  # named `BeamLisp.Server.<ns>.<name>` (see `BeamLisp.Server.module_for/2`),
  # and the client fns `start`/`start-link`/`call`/`cast`/`stop` make the
  # server usable without raw interop.
  defp compile_special("defserver", [name_form | clauses], env) do
    name = name_of(name_form)

    if clauses == [] do
      compile_error(env, "defserver #{name}: expected at least an (init …) clause")
    end

    mod = BeamLisp.Server.module_for(env.ns, name)

    def_line = if line = pos_line(env[:line]), do: [line: line], else: []
    # Module.create/3 requires a location; there is no "unknown" value it
    # accepts. A form read from a string (the REPL, eval_string with no
    # path) has no file, so fall back to this module rather than passing
    # nil and getting a FunctionClauseError at the create site.
    location =
      if env[:file],
        do: [file: env[:file], line: pos_line(env[:line]) || 1],
        else: [file: __ENV__.file, line: __ENV__.line]

    {defs, init?} =
      Enum.reduce(clauses, {[], false}, fn clause, {acc, init?} ->
        {fname, arity, clause_defs} = parse_server_clause(clause, env, def_line)
        tagged = Enum.map(clause_defs, &{fname, arity, &1})
        {acc ++ tagged, init? or {fname, arity} == {:init, 1}}
      end)

    unless init? do
      compile_error(env, "defserver #{name}: requires an (init …) clause")
    end

    module_body =
      {:__block__, [],
       [quote(do: @behaviour :gen_server)] ++ server_ordered_defs(group_server_defs(defs)) ++ server_client_defs()}

    quote do
      previous = Code.compiler_options()
      Code.compiler_options(ignore_module_conflict: true)

      try do
        # The body is escaped so its `@behaviour`/`def` nodes are reconstructed
        # at runtime as data and compiled by Module.create — never expanded in
        # this eval module's own body (Elixir would reject `@` outside module
        # scope if the nodes were inlined here).
        Module.create(unquote(mod), unquote(Macro.escape(module_body)), unquote(location))
      after
        Code.compiler_options(previous)
      end

      BeamLisp.Env.intern(unquote(env.ns), unquote(name), unquote(mod))
      unquote(mod)
    end
  end

  # --- open dispatch: multimethods ---
  #
  # `(defmulti name dispatch-fn)` interns `name` as a callable that
  # applies dispatch-fn to all args and runs the matching method.
  # Re-definition reuses the method table (only the dispatch fn
  # changes), mirroring Clojure's CLJ-1351. `(defmethod name val
  # [args] body…)` adds or replaces one entry; the dispatch value is
  # an ordinary expression evaluated at definition time.
  defp compile_special("defmulti", [name_form, dispatch], env) do
    name = name_of(name_form)
    dispatch_ast = compile_elixir(dispatch, notail(env))
    quote do: BeamLisp.Multi.define_multi(unquote(env.ns), unquote(name), unquote(dispatch_ast))
  end

  defp compile_special("defmulti", [name_form, doc, dispatch], env) when is_binary(doc) do
    name = name_of(name_form)
    dispatch_ast = compile_elixir(dispatch, notail(env))

    quote do
      value = BeamLisp.Multi.define_multi(unquote(env.ns), unquote(name), unquote(dispatch_ast))
      BeamLisp.Env.put_meta(unquote(env.ns), unquote(name), %{doc: unquote(doc)})
      value
    end
  end

  defp compile_special("defmulti", args, env),
    do: compile_error(env, "defmulti: expected (defmulti name dispatch-fn), got #{inspect(args)}")

  defp compile_special("defmethod", [name_form, dispatch_val | rest], env) do
    name = name_of(name_form)
    if rest == [], do: compile_error(env, "defmethod #{name}: expected a method body")

    {mns, mname} = multi_var_target(env, name)
    dispatch_ast = compile_elixir(dispatch_val, notail(env))
    method_ast = compile_fn(fn_clauses(rest, env), env)

    quote do
      BeamLisp.Multi.add_method(unquote(mns), unquote(mname), unquote(dispatch_ast), unquote(method_ast))
    end
  end

  # --- protocols ---
  #
  # `(defprotocol Name (m [this] …) …)` interns `Name` as a descriptor
  # var and each method as a callable var that dispatches on the type
  # tag of its first argument (see Multi.type_of/1).
  # `(extend-type Type Name (m [this] …) …)` fills in one type's
  # methods; `(extend-protocol Name Type (m …) Type2 (m2 …) …)` does
  # several at once. A type arg is a keyword tag (`:vector`, `:map`,
  # `:binary`…) or an Elixir struct module (`Foo.Bar`), resolved to a
  # tag at compile time.
  # `(defprotocol Name "docstring" (m [this] …) …)` accepts an optional
  # leading docstring between the name and the first method, and stores
  # it as the protocol's `:doc` var metadata rather than discarding it —
  # the same split defn/defmacro use, so a docstring is a string in the
  # same position a method list is not confused with one.
  # (defnative "crate_name" (fn-name arity) ...)
  #
  # Declares that this namespace's functions are implemented in NATIVE
  # code — a Rust NIF built from `native/<crate_name>`. The namespace's
  # own module becomes the NIF host, so beam-lisp reaches native code
  # without an Elixir module standing between them.
  #
  # This exists because the alternative was worse in a specific way: a
  # NIF must be loaded into a BEAM module, and before this the only way
  # to get one was to write an Elixir module of stub functions whose
  # bodies all read `:erlang.nif_error(:nif_not_loaded)`. That file
  # contained no logic — it was a DECLARATION that some names are native
  # — and yet it forced every native capability to enter through Elixir,
  # which contradicts the doctrine that Elixir keeps only substrate.
  #
  # A NIF *is* substrate. The declaration that one exists is not.
  defp compile_special("defnative", [crate_form | sig_forms], env) do
    # A NIF is arbitrary host code entering the VM; installing one is a
    # capability a restricted env must not hold. `Native.declare` stays
    # callable from host Elixir (the host is not sandboxed) — this gate is
    # the bl-language path.
    unless Env.caps() == :all do
      compile_error(
        env,
        "defnative is not available in a capability-restricted environment: " <>
          "a NIF is substrate, and only `:global`-capability code installs substrate"
      )
    end

    crate = string_of(crate_form)

    signatures =
      Enum.map(sig_forms, fn sf ->
        case unwrap_meta(sf) do
          {:list, [name_f, arity_f]} ->
            {name_of(name_f), literal_int(arity_f)}

          other ->
            raise "defnative: expected (fn-name arity), got #{inspect(other)}"
        end
      end)

    quote do
      BeamLisp.Native.declare(unquote(env.ns), unquote(crate), unquote(Macro.escape(signatures)))
    end
  end

  defp compile_special("defnative", args, env),
    do:
      compile_error(
        env,
        "defnative: expected (defnative \"crate\" (fn-name arity)…), got #{inspect(args)}"
      )

  defp compile_special("defprotocol", [name_form | method_forms], env) do
    name = name_of(name_form)
    {doc, method_forms} = split_docstring(method_forms)

    method_names =
      Enum.map(method_forms, fn mf ->
        case unwrap_meta(mf) do
          {:list, [head | _]} -> name_of(head)
          other -> raise "defprotocol #{name}: expected (method-name [args]…), got #{inspect(other)}"
        end
      end)

    define_ast =
      quote do
        BeamLisp.Multi.define_protocol(unquote(env.ns), unquote(name), unquote(method_names))
      end

    if doc do
      quote do
        value = unquote(define_ast)
        BeamLisp.Env.put_meta(unquote(env.ns), unquote(name), %{doc: unquote(doc)})
        value
      end
    else
      define_ast
    end
  end

  defp compile_special("defprotocol", args, env),
    do: compile_error(env, "defprotocol: expected (defprotocol Name (method [args]…)), got #{inspect(args)}")

  defp compile_special("extend-type", [type_form, protocol_form | method_forms], env) do
    protocol = name_of(protocol_form)
    {pns, pname} = multi_var_target(env, protocol)
    tag = type_tag(type_form, env)
    impls = {:%{}, [], Enum.map(method_forms, &protocol_impl(&1, env))}

    quote do
      BeamLisp.Multi.extend_type(unquote(pns), unquote(pname), unquote(tag), unquote(impls))
    end
  end

  # `(satisfies? Proto x)` — a special form for the same reason
  # `extend-type` is one: the protocol is named, not evaluated. Passing
  # `Proto` as a value would mean resolving a var whose contents are the
  # method table, when what is wanted is the protocol's identity.
  defp compile_special("satisfies?", [protocol_form, value_form], env) do
    {pns, pname} = multi_var_target(env, name_of(protocol_form))
    value_ast = compile_elixir(value_form, notail(env))

    quote do
      BeamLisp.Multi.satisfies?(unquote(pns), unquote(pname), unquote(value_ast))
    end
  end

  defp compile_special("extend-protocol", [protocol_form | forms], env) do
    protocol = name_of(protocol_form)
    {pns, pname} = multi_var_target(env, protocol)
    # Forms alternate type / method-forms; a type is a keyword or
    # symbol, a method form is a list — enough to split the groups
    # without consulting the protocol descriptor.
    {groups, cur_type, cur_methods} =
      Enum.reduce(forms, {[], nil, []}, fn mf, {groups, type, methods} ->
        case unwrap_meta(mf) do
          {:list, _} = bare -> {groups, type, methods ++ [bare]}
          type_form -> {groups ++ [{type, methods}], type_form, []}
        end
      end)

    calls =
      for {type_form, method_forms} <- groups ++ [{cur_type, cur_methods}],
          type_form != nil do
        tag = type_tag(type_form, env)
        impls = {:%{}, [], Enum.map(method_forms, &protocol_impl(&1, env))}

        quote do
          BeamLisp.Multi.extend_type(unquote(pns), unquote(pname), unquote(tag), unquote(impls))
        end
      end

    block(calls)
  end

  # `(defrecord Name [fields…] (Proto (m [this]…) …) …)` defines a
  # struct-backed type (see BeamLisp.Record) plus the `->Name`/`map->Name`
  # constructors, and interns `Name` as the struct module. Inline protocol
  # implementations reuse the same compile path as `extend-type`
  # (`protocol_impl`/`multi_var_target`), so a record implements a protocol
  # through the one dispatch machinery, not a parallel one. The struct
  # module is created at runtime, so everything below refers to `mod` (the
  # runtime value) rather than baking a module name.
  # One clause for the bare form and one for the form with inline
  # protocol blocks (`proto_forms` non-empty); the exact-arity clause
  # must precede the variadic one or it is shadowed.
  defp compile_special("defrecord", [name_form, fields_form], env) do
    record_define_ast(env, name_of(name_form), record_fields(fields_form), :record, [])
  end

  defp compile_special("defrecord", [name_form, fields_form | proto_forms], env) do
    record_define_ast(env, name_of(name_form), record_fields(fields_form), :record, proto_forms)
  end

  defp compile_special("defrecord", args, env),
    do: compile_error(env, "defrecord: expected (defrecord Name [fields…] & protocols), got #{inspect(args)}")

  # `(deftype Name [fields…] …)` is the leaner sibling: no map semantics,
  # no `map->Name`, just the `->Name` constructor and named-field access
  # (`.-x`/`.x`). Instances are tagged tuples, so they can never be
  # mistaken for a map. Inline protocol impls work exactly as for records.
  defp compile_special("deftype", [name_form, fields_form], env) do
    record_define_ast(env, name_of(name_form), record_fields(fields_form), :deftype, [])
  end

  defp compile_special("deftype", [name_form, fields_form | proto_forms], env) do
    record_define_ast(env, name_of(name_form), record_fields(fields_form), :deftype, proto_forms)
  end

  defp compile_special("deftype", args, env),
    do: compile_error(env, "deftype: expected (deftype Name [fields…] & protocols), got #{inspect(args)}")

  # `(reify Proto (m [this] …) …) Proto2 (n [this] …)` builds an
  # anonymous instance implementing one or more protocols, the whole
  # point being that it *closes over its lexical environment* — the
  # thing deftype deliberately cannot do (deftype fields are declared,
  # reify captures whatever locals are in scope at the form).
  #
  # Shape: an instance is a `{:bl_reify, ref, {}}` tuple — the same
  # tagged-tuple family deftype uses, but with a per-evaluation
  # reference in place of a module atom. It must be per-evaluation:
  # two instances built by one reify site capture different locals, so
  # they must dispatch to different method closures, and a compile-time
  # constant module atom would make them share one slot and all behave
  # like the last instance built. `make_ref()` is unique per evaluation,
  # costs no atom-table entries (a deftype's module atom is a
  # compile-time constant; a reify has no name and is created at
  # runtime), and still keys `Multi.type_of`/`extend_type` exactly like
  # a module tag — the one protocol machinery, no parallel path. Each
  # protocol's methods are registered with `Multi.extend_type` as
  # `extend-type` would; the method bodies compile in the enclosing
  # env, so each evaluation's closures capture that evaluation's local
  # values.
  #
  # `extend_type` already refuses an incomplete extension, so a reify
  # that names a protocol without covering every method is a compile
  # error, matching Clojure. Unlike deftype there is no type name or
  # `->Name` constructor: the value is the form's result.
  #
  # The cost of per-evaluation identity is that each instance leaves
  # its method entries in the dispatch table for the process lifetime.
  # That is bounded by how many reify evaluations a program performs
  # (Specter builds each navigator once, at var init), and is the same
  # trade-off the multimethod tables already document.
  defp compile_special("reify", forms, env) do
    groups = reify_protocol_groups(forms, env)
    tag_var = Macro.var(:tag, __MODULE__)

    extend_asts =
      for {proto, method_forms} <- groups do
        {pns, pname} = multi_var_target(env, proto)
        impls = {:%{}, [], Enum.map(method_forms, &protocol_impl(&1, env))}

        quote do
          BeamLisp.Multi.extend_type(unquote(pns), unquote(pname), unquote(tag_var), unquote(impls))
        end
      end

    quote do
      unquote(tag_var) = make_ref()
      unquote(block(extend_asts))
      {:bl_reify, unquote(tag_var), {}}
    end
  end

  # Thread a per-syntax-quote-form gensym map through synq so a `x#`
  # symbol is renamed once and reuses that name everywhere inside one
  # backquote — the auto-gensym that makes macros hygienic. Unquoted
  # (~ ~@) code compiles normally and never consults the map.
  defp compile_special("syntax-quote", [form], env) do
    {ast, _gensyms} = synq_data(form, env, %{})
    ast
  end

  defp compile_special("let", [bindings_form | body], env) do
    {:vector, bindings} = unwrap_meta(bindings_form)
    {steps, final_env} = compile_bindings(bindings, notail(env))
    body_ast = block_forms(body, %{final_env | tail: env.tail})
    nest_steps(steps, body_ast)
  end

  # loop = let + a recur target. Self-application is a tail call on
  # the BEAM, so (recur …) runs in constant stack. Destructured
  # bindings destructure at entry: the recur params are the pattern
  # values (the whole map/vector), so `recur` re-supplies them exactly
  # as in Clojure.
  defp compile_special("loop", [bindings_form | body], env) do
    {:vector, bindings} = unwrap_meta(bindings_form)
    {params, entry_binds, arg_asts, bound_env} = loop_bindings(bindings, notail(env))

    self = fresh_var("loop")
    loop_env = %{bound_env | recur: %{self: self, arity: length(params)}, tail: true}
    body_ast = nest_steps(entry_binds, block_forms(body, loop_env))

    inner_fn = {:fn, [], [{:->, [], [params, body_ast]}]}
    self_applied = self_apply(self, inner_fn)
    {{:., [], [self_applied]}, [], arg_asts}
  end


  # The star-suffixed primitives beneath loop/let/fn, which upstream
  # macros expand to (jank's threading macros use loop*, its head uses
  # fn*/let*). Each shares its unstarred sibling's semantics.
  defp compile_special("loop*", args, env), do: compile_special("loop", args, env)

  defp compile_special("let*", args, env), do: compile_special("let", args, env)

  defp compile_special("fn*", args, env), do: compile_special("fn", args, env)

  defp compile_special("recur", args, env) do
    case env.recur do
      nil ->
        compile_error(env, "recur used with no enclosing loop or fn")

      %{arity: arity} = target ->
        unless env.tail, do: compile_error(env, "recur must be in tail position")

        unless length(args) == arity,
          do: compile_error(env, "recur arity mismatch: target takes #{arity}, got #{length(args)}")

        arg_asts = Enum.map(args, &compile_elixir(&1, notail(env)))

        case target do
          # Anonymous fn / loop: re-enter via self-application.
          %{self: self} ->
            self_app = {{:., [], [self]}, [], [self]}
            {{:., [], [self_app]}, [], arg_asts}

          # Linked defn: a named self-call, TCO'd like any tail call.
          %{self_call: {mod, fname}} ->
            {{:., [], [mod, fname]}, [], arg_asts}
        end
    end
  end

  defp compile_special("if", [test, then], env), do: compile_if(test, then, nil, env)
  defp compile_special("if", [test, then, else_], env), do: compile_if(test, then, else_, env)

  defp compile_special("do", body, env), do: block_forms(body, env)

  # (throw x) — raise a value as an exception so try can catch it.
  # Values become ExInfo payloads (maps keep their data), so a thrown
  # value survives the round trip; an existing exception re-raises.
  defp compile_special("throw", [x], env) do
    quote do
      BeamLisp.ExInfo.raise_payload(unquote(compile_elixir(x, notail(env))))
    end
  end

  # (try body… (catch e handler…)… (finally f…))
  #
  # Catch clauses: `(catch e h…)` binds the raised value to `e` for
  # any kind; `(catch Module.Name e h…)` matches only that Elixir
  # exception. All clauses compile into one Elixir `catch kind, value`
  # clause that dispatches in source order (see compile_catches); body
  # is an implicit do. The try's value is the body's (or the matching
  # handler's); a finally's value is discarded.
  defp compile_special("try", forms, env) do
    {body, catches, finally_body} = split_try_forms(forms)

    # A try with no catch and no finally is just its body — Elixir's
    # `try` requires at least one of :rescue/:catch/:after.
    if catches == [] and finally_body == [] do
      block_forms(body, env)
    else
      body_ast = block_forms(body, env)
      # `do:` MUST stay first in the keyword list: the compiler
      # accepts any order, but Elixir's printer and the 1.20 type
      # checker only recognize the try special form when it leads
      # (Keyword.put prepends — append instead).
      opts = [do: body_ast]

      opts =
        case compile_catches(catches, env) do
          nil -> opts
          clause -> opts ++ [catch: [clause]]
        end

      opts =
        if finally_body != [],
          do: opts ++ [after: block_forms(finally_body, notail(env))],
          else: opts

      {:try, [], [opts]}
    end
  end

  # (receive pattern body… (after ms body…)) — Elixir's receive,
  # with beam-lisp pattern syntax: literals and keywords match
  # themselves, symbols bind, [p q] is a 2-or-more-tuple, {:k p} a
  # map match. Clause bodies see their pattern's bindings.
  #
  # A clause may carry a guard between its pattern and its body:
  # `(receive [:take n] :when (pos? n) …)`. That is not sugar for an `if`
  # — a message failing the guard is NOT received, so it stays in the
  # mailbox for a later clause or a later receive, which is the whole
  # reason selective receive exists.
  defp compile_special("receive", clauses, env) do
    {after_clauses, normal} =
      Enum.split_with(clauses, &match?({:list, [{:symbol, "after"} | _]}, unwrap_meta(&1)))

    do_clauses =
      normal
      |> receive_clauses(env)
      |> Enum.flat_map(fn {pattern_form, guard_form, body} ->
        {pat_asts, pat_env} = compile_pattern(pattern_form, env)
        guard_ast = compile_guard(guard_form, pat_env)
        body_ast = compile_elixir(body, pat_env)

        Enum.map(pat_asts, fn pat ->
          {:->, [], [[guarded(pat, guard_ast)], body_ast]}
        end)
      end)

    block =
      case after_clauses do
        [] ->
          [do: do_clauses]

        [after_form] ->
          {:list, [{:symbol, "after"}, timeout, body]} = unwrap_meta(after_form)
          after_clause = {:->, [], [[compile_elixir(timeout, notail(env))], compile_elixir(body, env)]}
          [do: do_clauses, after: [after_clause]]

        _ ->
          compile_error(env, "receive takes at most one (after ms body) clause")
      end

    {:receive, [], [block]}
  end

  # Split a receive's clause forms into `{pattern, guard | nil, body}`
  # triples. Written as an explicit walk rather than `chunk_every(2)`
  # because a guard makes a clause three forms instead of two, and a
  # fixed chunk silently re-pairs everything after the first guard:
  # the pattern of clause 2 would become the BODY of clause 1.
  defp receive_clauses([], _env), do: []

  defp receive_clauses([pattern_form | rest], env) do
    case split_guard(rest) do
      {:missing, _} ->
        compile_error(env, "a receive clause's `:when` must be followed by a guard expression")

      {guard_form, [body | tail]} ->
        [{pattern_form, guard_form, body} | receive_clauses(tail, env)]

      {_guard_form, []} ->
        compile_error(
          env,
          "receive clauses are pattern/body pairs (with an optional `:when` guard " <>
            "between them); the last clause has a pattern but no body"
        )
    end
  end

  # Attach a guard to a clause head, or leave the head bare when there is
  # none. One helper so `receive` and `defserver` cannot drift on how a
  # guard is spliced.
  defp guarded(pat, nil), do: pat
  defp guarded(pat, guard_ast), do: {:when, [], [pat, guard_ast]}

  # The same, for a head that is a LIST of parameters (an `fn` clause).
  # Elixir spells a guarded multi-parameter head as ONE `when` node whose
  # children are the params followed by the guard, so the args list
  # collapses to a single element — which is why this cannot just call
  # `guarded/2` per param.
  defp guarded_head(head_vars, nil), do: head_vars
  defp guarded_head(head_vars, guard_ast), do: [{:when, [], head_vars ++ [guard_ast]}]

  # A docstring is a string literal followed by more forms; anything
  # else keeps today's meaning (first form is a clause / the value).
  defp split_docstring([doc | rest]) when is_binary(doc) and rest != [], do: {doc, rest}
  defp split_docstring(rest), do: {nil, rest}

  # Split (try …) into body forms, catch clauses, and a finally body.
  # Catch/finally are classified by their head symbol; the caller
  # keeps the catch clauses in source order (first match wins).
  defp split_try_forms(forms) do
    {catches, rest} =
      Enum.split_with(forms, &match?({:list, [{:symbol, "catch"} | _]}, unwrap_meta(&1)))

    {finallies, body} =
      Enum.split_with(rest, &match?({:list, [{:symbol, "finally"} | _]}, unwrap_meta(&1)))

    finally_body =
      case finallies do
        [] -> []
        [finally_form] ->
          {:list, [{:symbol, "finally"} | fb]} = unwrap_meta(finally_form)
          fb

        _ -> raise "try takes at most one (finally …) clause"
      end

    {body, catches, finally_body}
  end

  # Compile all catch clauses into a single Elixir `catch kind, value`
  # clause. A bare-variable catch clause is used deliberately: Elixir's
  # signature inference crashes (deferred, at VM exit) on hand-built
  # `rescue ... in` and literal-kind `catch` patterns, so the dispatch
  # happens here instead. `e` is bound per kind — thrown value for
  # :throw, Exception.normalize for :error (users get structs), and
  # {:exit, reason} for :exit — then clauses are tried in source order
  # as nested if/else: a typed clause matches via is_struct, an untyped
  # clause is a catch-all, and a re-raise of the original kind/value is
  # the final fallback. Returns nil when there are no catch clauses.
  defp compile_catches([], _env), do: nil

  defp compile_catches(catches, env) do
    kind_var = fresh_var("kind")
    value_var = fresh_var("value")
    e_var = fresh_var("e")
    stack_var = fresh_var("stack")

    normalize =
      quote do
        case unquote(kind_var) do
          :throw -> unquote(value_var)
          :error -> Exception.normalize(:error, unquote(value_var), unquote(stack_var))
          :exit -> {:exit, unquote(value_var)}
        end
      end

    cond_clauses =
      Enum.map(catches, fn clause -> catch_branch(clause, e_var, env) end)

    # Nested if/else (not a cond): Elixir's parser chokes on the nested
    # `->` of a cond inside a catch clause body.
    fallback = reralse_ast(kind_var, value_var, stack_var)

    dispatch_body =
      Enum.reduce(Enum.reverse(cond_clauses), fallback, fn {:->, [], [[cond_ast], handler]}, else_ast ->
        {:if, [], [cond_ast, [do: handler, else: else_ast]]}
      end)

    # `__STACKTRACE__` is captured into a var first: Elixir mishandles it
    # when it appears directly inside a `case` within a catch handler.
    dispatch =
      quote do
        unquote(stack_var) = __STACKTRACE__
        unquote(e_var) = unquote(normalize)
        unquote(dispatch_body)
      end

    {:->, [], [[kind_var, value_var], dispatch]}
  end

  # One (catch …) clause → a `cond` clause `{:->, [], [[condition], handler]}`
  # for the dispatch. A capitalized first symbol names a typed module; any
  # other symbol is an untyped catch-all. The handler's `e` is bound to
  # the dispatched value before it runs.
  defp catch_branch(clause, e_var, env) do
    {:list, [{:symbol, "catch"}, first | rest]} = unwrap_meta(clause)

    case unwrap_meta(first) do
      {:symbol, name} ->
        if uppercase?(name) do
          case rest do
            [e_name_form | handler] ->
              typed_branch(name, name_of(e_name_form), handler, e_var, env)

            _ ->
              raise "typed catch requires (catch Module.Name e handler…)"
          end
        else
          untyped_branch(name, rest, e_var, env)
        end

      other ->
        raise "catch requires a variable or Module.Name, got: #{inspect(other)}"
    end
  end

  # (catch Module.Name e handler…) — match only that Elixir exception,
  # resolved from its dotted symbol via Module.concat.
  defp typed_branch(module_str, e_name, handler_forms, e_var, env) do
    module = Module.concat(String.split(module_str, "."))
    handler_var = fresh_var(e_name)
    segs = Module.split(module) |> Enum.map(&String.to_atom/1)
    mod_ast = {:__aliases__, [alias: false], segs}

    cond_ast = quote do: is_struct(unquote(e_var), unquote(mod_ast))
    handler = run_handler(handler_var, e_var, handler_forms, e_name, env)
    {:->, [], [[cond_ast], handler]}
  end

  # (catch e handler…) — untyped catch-all over every kind.
  defp untyped_branch(e_name, handler_forms, e_var, env) do
    handler_var = fresh_var(e_name)
    handler = run_handler(handler_var, e_var, handler_forms, e_name, env)
    {:->, [], [[true], handler]}
  end

  # Bind the handler's `e` to the dispatched value, then run its body.
  defp run_handler(handler_var, e_var, handler_forms, e_name, env) do
    handler_ast = block_forms(handler_forms, put_local(env, e_name, handler_var))
    {:__block__, [], [{:=, [], [handler_var, e_var]}, handler_ast]}
  end

  # Re-raise the original kind/value when no clause matches (only
  # reachable when every clause is typed and none matched).
  defp reralse_ast(kind_var, value_var, stack_var) do
    quote do
      :erlang.raise(unquote(kind_var), unquote(value_var), unquote(stack_var))
    end
  end

  # A message pattern, compiled with its bindings added to the env.
  # Shared by `receive` and by `defserver`'s dispatching callbacks.
  #
  # Returns one or more pattern ASTs — ALTERNATIVES, all binding the same
  # variables, which the caller emits as sibling clauses with one body.
  # A vector pattern is the reason there is ever more than one: `[p q]`
  # matches an Erlang tuple AND a beam-lisp vector, and those are two
  # different BEAM shapes, so each needs its own clause.
  #
  # Alternatives MULTIPLY through nesting: `[:a [:b n]]` is two shapes for
  # the outer times two for the inner. That product is what the callers
  # need and what compile_alternatives/2 computes; the previous code
  # assumed every sub-pattern yielded exactly one AST and crashed with a
  # raw MatchError from inside the compiler the moment a vector held a
  # vector (BUG-002).
  #
  # A pattern may carry a reader position wrapper; unwrap it for the shape
  # clauses below while nested items stay wrapped so their own positions
  # re-capture when compiled.

  # The product is bounded: each nested vector doubles the clause count,
  # and past a ceiling this refuses BY NAME rather than quietly emitting
  # hundreds of identical bodies. Checked HERE, the one place every
  # pattern node passes through, so the number in the message is the
  # number of clauses that would really be emitted.
  @max_pattern_alternatives 64

  defp compile_pattern(form, env) do
    {alts, env} = compile_pattern_bare(unwrap_meta(form), env)

    if length(alts) > @max_pattern_alternatives do
      too_many_alternatives(env, length(alts))
    end

    {alts, env}
  end

  # Compile sub-patterns left to right, threading the env, and return the
  # product of their alternatives: `[[a1, b1], [a1, b2], [a2, b1], …]`.
  #
  # Every alternative of one sub-pattern binds the SAME fresh vars (they
  # are generated once, before the shapes are built), so the env threads
  # linearly even though the shapes multiply — which is exactly why one
  # body can serve every clause.
  defp compile_alternatives(forms, env) do
    {alt_lists, env} =
      Enum.map_reduce(forms, env, fn form, acc_env ->
        compile_pattern(form, acc_env)
      end)

    # The product is counted BEFORE it is built. Each child is individually
    # under the ceiling (compile_pattern/2 enforces that), but the product
    # of several such children is not: six items at 16 alternatives each is
    # 16^6 ≈ 17 million combinations, which would exhaust the compiler while
    # building the very list whose length was going to be rejected.
    #
    # Multiplying the lengths answers the same question for the cost of a
    # few integers, so an over-large pattern is refused instantly.
    count = Enum.reduce(alt_lists, 1, fn alts, acc -> acc * length(alts) end)

    if count > @max_pattern_alternatives do
      too_many_alternatives(env, count)
    end

    combos =
      Enum.reduce(alt_lists, [[]], fn alts, acc ->
        for prefix <- acc, alt <- alts, do: prefix ++ [alt]
      end)

    {combos, env}
  end

  defp too_many_alternatives(env, count) do
    compile_error(
      env,
      "this pattern nests too deeply: a vector pattern matches both a tuple and a " <>
        "beam-lisp vector, and those alternatives multiply through nesting, so " <>
        "#{count} clauses would be generated (the ceiling is " <>
        "#{@max_pattern_alternatives}). Match the outer shape and destructure the " <>
        "rest in the body with `let`."
    )
  end

  defp compile_pattern_bare({:symbol, "_"}, env), do: {[{:_, [], __MODULE__}], env}

  defp compile_pattern_bare({:symbol, name}, env) do
    var = fresh_var(name)
    {[var], put_local(env, name, var)}
  end

  defp compile_pattern_bare({:keyword, name}, env), do: {[BeamLisp.AtomGuard.to_atom(name)], env}

  # `[p q]` matches an Erlang tuple and a beam-lisp vector alike, because
  # a small vector IS an element tuple wrapped in a struct. Both shapes
  # are emitted for every combination of the items' own alternatives, so
  # a nested `[:a [:b n]]` names all four and the body is written once.
  defp compile_pattern_bare({:vector, items}, env) do
    {combos, env} = compile_alternatives(items, env)

    pats =
      Enum.flat_map(combos, fn pats ->
        tuple_pat = {:{}, [], pats}

        vector_pat =
          {:%, [],
           [{:__aliases__, [], [:BeamLisp, :Vector]}, {:%{}, [], [items: tuple_pat]}]}

        [tuple_pat, vector_pat]
      end)

    {pats, env}
  end

  defp compile_pattern_bare({:map, kvs}, env) do
    keys =
      Enum.map(kvs, fn {k, _v} ->
        case unwrap_meta(k) do
          {:keyword, name} -> BeamLisp.AtomGuard.to_atom(name)
          lit when is_number(lit) or is_binary(lit) -> lit
          other -> compile_error(env, "unsupported map pattern key: #{inspect(other)}")
        end
      end)

    {combos, env} = compile_alternatives(Enum.map(kvs, &elem(&1, 1)), env)

    pats = Enum.map(combos, fn vals -> {:%{}, [], Enum.zip(keys, vals)} end)

    {pats, env}
  end

  defp compile_pattern_bare({:list, [{:symbol, "quote"}, form]}, env) do
    {[Macro.escape(datum(form))], env}
  end

  defp compile_pattern_bare(lit, env)
       when is_number(lit) or is_binary(lit) or is_boolean(lit) or is_nil(lit),
       do: {[lit], env}

  defp compile_pattern_bare(other, env),
    do:
      compile_error(
        env,
        "unsupported message pattern: #{inspect(other)} " <>
          "(a pattern is a literal, a keyword, a symbol, `[p q]`, `{:k p}` or `(quote datum)`)"
      )

  # Shared expansion for `defn` and `defn-`: peel the optional leading
  # docstring, then hand the clauses to compile_defn with the private
  # flag. Kept out of the compile_special clause chain so it cannot
  # split that (Elixir requires same-name/arity clauses to be adjacent).
  defp compile_def_special(kind, name_form, rest, env, private) do
    name = name_of(name_form)
    {doc, rest} = split_docstring(rest)
    {attr, rest} = split_defn_attr(rest, name_meta(name_form))

    cond do
      rest == [] ->
        compile_error(env, kind <> " " <> name <> ": expected at least one parameter vector")

      match?([h | _] when is_binary(h), rest) ->
        compile_error(
          env,
          kind <> " " <> name <> ": expected a parameter vector, got a string literal (a docstring must be followed by clauses)"
        )

      true ->
        compile_defn(name, fn_clauses(rest, env), env, doc, private, attr)
    end
  end

  # `(defn name "doc" {:attr-map} [params] …)` — Clojure's defn takes an
  # optional metadata-map literal between the docstring and the clauses.
  # It merges into any `^{...}` metadata that rode on the name symbol
  # (the `:inline` on jank's bit-not is written this way).
  defp split_defn_attr([{:map, kvs} | rest], attr), do: {merge_attr(attr, kvs), rest}
  defp split_defn_attr(rest, attr), do: {attr, rest}

  defp merge_attr(nil, kvs), do: attr_map(kvs)
  defp merge_attr(attr, kvs), do: Map.merge(attr, attr_map(kvs))
  defp attr_map(kvs), do: Map.new(kvs, fn {k, v} -> {attr_key(k), v} end)
  defp attr_key({:keyword, name}), do: BeamLisp.AtomGuard.to_atom(name)

  # One defn into a per-ns body module. The `defn` form's own line
  # stamps each generated `:def` node, so the namespace module's line
  # table names the definition site (not the default module line). The
  # location rides to Link.defvar so its Module.create claims the same
  # file.
  #
  # Clauses are split by arity: fixed-arity clauses become same-named
  # defs; a variadic clause is emitted under a mangled name taking the
  # rest as its last parameter (split_variadic/1). The var's value is a
  # capture, and later call sites compile to direct remote calls (see
  # BeamLisp.Link). The `private` flag and any `^{...}`/attr-map metadata
  # land in the var's metadata.
  defp compile_defn(name, clauses, env, doc, private, attr) do
    if per_env_attr?(attr) do
      # `^:per-env` only means something for a stateful VALUE def — a function is
      # already re-entrant and interns one global fn value (the PLAN-047
      # invariant). Reject rather than silently ignore, so the marker never
      # reads as "isolated" where it does nothing.
      compile_error(env, "defn " <> name <> ": ^:per-env is only valid on a `def` value, not a function")
    end

    mod = BeamLisp.Link.module_for(env.ns)

    # The defn form's own line stamps each generated `:def` node, so the
    # namespace module's line table names the definition site (not the
    # default module line). The location rides to Link.defvar so its
    # Module.create claims the same file.
    def_line = if line = pos_line(env[:line]), do: [line: line], else: []
    # Module.create/3 requires a location; there is no "unknown" value it
    # accepts. A form read from a string (the REPL, eval_string with no
    # path) has no file, so fall back to this module rather than passing
    # nil and getting a FunctionClauseError at the create site.
    location =
      if env[:file],
        do: [file: env[:file], line: pos_line(env[:line]) || 1],
        else: [file: __ENV__.file, line: __ENV__.line]

    # Compiled in SOURCE order, then EMITTED grouped by shape.
    #
    # Same-name/arity `def` clauses must be adjacent in an Elixir module —
    # interleaving arities (`[x]`, `[x y]`, `[x]`) still compiles correctly
    # but earns a "clauses with the same name should be grouped together"
    # warning per clause, blaming generated code for the author's ordering.
    #
    # The two orders are separated deliberately. Compiling a body EXPANDS
    # ITS MACROS, which is observable (a macro may gensym or carry state),
    # so compilation follows the source. Only the emitted list is
    # rearranged, and within each shape the clauses keep their written
    # order — which is the order their guards are tried in.
    entries =
      clauses
      |> Enum.map(fn {params, guard, body} ->
        {_fixed, rest} = split_variadic(params)

        {kind, fname} =
          case rest do
            nil -> {:fixed, String.to_atom(name)}
            _ -> {:variadic, String.to_atom(name <> "__bl_v")}
          end

        {head_vars, guard_ast, body_ast, fixed_count, _v?} =
          compile_clause(env, params, guard, body, %{self_call: {mod, fname}})

        def_ast =
          {:def, def_line, [guarded({fname, [], head_vars}, guard_ast), [do: body_ast]]}

        {kind, fixed_count, fname, def_ast}
      end)
      |> group_by_shape(fn {kind, fixed_count, _fname, _def} -> {kind, fixed_count} end)
      |> Enum.concat()

    defvar_ast =
      quote do
        BeamLisp.Link.defvar(
          unquote(env.ns),
          unquote(name),
          unquote(Macro.escape(entries)),
          unquote(location)
        )
      end

    if meta = var_meta_ast(doc, private, attr, env) do
      # defn returns the interned value (Clojure's def returns the var
      # root); the meta write is a side effect after it. The private
      # flag and the `^{...}`/attr-map metadata land in the same map
      # (Env.put_meta merges, so a later public redefinition keeps a
      # private flag — faithful to Clojure, where var metadata sticks).
      quote do
        value = unquote(defvar_ast)
        BeamLisp.Env.put_meta(unquote(env.ns), unquote(name), unquote(meta))
        value
      end
    else
      defvar_ast
    end
  end

  # One defserver clause into OTP callback defs. Pattern clauses may expand to
  # several defs: a vector message pattern matches both a tuple and a
  # `%Vector{}` struct, so both are emitted with an identical body.
  defp parse_server_clause(clause, env, def_line) do
    cb_name =
      case unwrap_meta(clause) do
        {:list, [head | _]} -> name_of(head)
        other -> raise "defserver: expected a (callback …) clause, got #{inspect(other)}"
      end

    case BeamLisp.Server.callback(cb_name) do
      nil ->
        raise(
          "defserver: unknown callback #{cb_name} " <>
            "(expected init, handle-call, handle-cast, handle-info, handle-continue or terminate)"
        )

      {fname, arity, shape} ->
        {fname, arity, server_clause_defs(unwrap_meta(clause), fname, shape, env, def_line)}
    end
  end

  # A `:vector` callback (`init`, `terminate`, `handle-continue`) binds a plain
  # param vector like a fn clause.
  defp server_clause_defs({:list, [_head | rest]}, fname, :vector, env, def_line) do
    [{:vector, params} | body] = rest
    {head_vars, preludes, clause_env} = bind_params(env, params)
    body_ast = compile_server_body(preludes ++ body, clause_env)
    [{:def, def_line, [{fname, [], head_vars}, [do: body_ast]]}]
  end

  # A `:pattern` callback (`handle-call`, `handle-cast`, `handle-info`) carries
  # a message pattern before the param vector; the pattern lands in the def
  # head so OTP dispatches on it, and the remaining params bind like a fn.
  #
  # An optional `:when` guard sits between the pattern and the param
  # vector: `(handle-call [:take n] :when (pos? n) [_from state] …)`. It
  # compiles into the def head, so OTP's own dispatch rejects the clause
  # and a later one answers — a validity test that lives in the CONTRACT
  # rather than in the body, which is what lets a server reply differently
  # to a bad request without a nested `if` in every handler.
  #
  # The guard is compiled against the message env only: the param vector
  # binds `from`/`state` AFTER it, and a guard cannot see a variable bound
  # to its right in the head anyway.
  defp server_clause_defs({:list, [_head | rest]}, fname, :pattern, env, def_line) do
    [pat_form | rest] = rest

    {guard_form, rest} =
      case split_guard(rest) do
        {:missing, _} ->
          compile_error(env, "defserver: `:when` must be followed by a guard expression")

        pair ->
          pair
      end

    case rest do
      [params_form | body] ->
        {params, body} = server_params(params_form, body)
        {pat_asts, msg_env} = compile_pattern(pat_form, env)
        guard_ast = compile_guard(guard_form, msg_env)
        {head_vars, preludes, clause_env} = bind_params(msg_env, params)
        body_ast = compile_server_body(preludes ++ body, clause_env)

        Enum.map(pat_asts, fn pat ->
          head = {fname, [], [pat | head_vars]}
          {:def, def_line, [guarded(head, guard_ast), [do: body_ast]]}
        end)

      [] ->
        compile_error(
          env,
          "defserver: a #{fname} clause is `(#{String.replace(to_string(fname), "_", "-")} " <>
            "PATTERN [params…] body…)` — this one has a pattern but no parameter vector"
        )
    end
  end

  defp server_params({:vector, params}, body), do: {params, body}
  defp server_params(other, _body), do: raise("defserver: expected a param vector, got #{inspect(other)}")

  # Compile a callback body with the return constructors (ok/reply/noreply/
  # stop/ignore/hibernate/continue) bound as locals, so they resolve anywhere
  # in the body — nested in if/let/fn included — and lower to the exact OTP
  # return tuple via `RT.invoke/2` on the arity-dispatching `$blfn` values.
  defp compile_server_body(forms, env) do
    ret_env =
      Enum.reduce(BeamLisp.Server.return_constructors(), env, fn {cname, _ctor}, acc ->
        put_local(acc, cname, server_return_local(cname))
      end)

    block_forms(forms, ret_env)
  end

  defp server_return_local(name) do
    quote do
      Map.fetch!(BeamLisp.Server.return_constructors(), unquote(name))
    end
  end

  # Group callback defs by their OTP fn/arity, then emit every callback in a
  # fixed order (BeamLisp.Server.callback_order/0) with its clauses adjacent
  # and its user clauses first. A callback's default is added only when the
  # user provided no clause, so a user catch-all is never shadowed by dead code.
  defp group_server_defs(defs) do
    Enum.reduce(defs, %{}, fn {fname, _arity, def_ast}, acc ->
      Map.update(acc, fname, [def_ast], &(&1 ++ [def_ast]))
    end)
  end

  defp server_ordered_defs(grouped) do
    Enum.flat_map(BeamLisp.Server.callback_order(), fn cb ->
      user = Map.get(grouped, cb, [])
      user ++ if(user == [], do: server_defaults(cb), else: [])
    end)
  end

  # Default clauses keep the generated module a well-formed gen_server even
  # when the user omits a callback: unknown messages stop the server (so a
  # supervisor can restart it), terminate/code_change behave as OTP expects.
  defp server_defaults(:handle_call),
    do: [default_def(:handle_call, [:msg, :_from, :state], stuple([:stop, stuple([:bad_call, {:var, :msg}]), {:var, :state}]))]

  defp server_defaults(:handle_cast),
    do: [default_def(:handle_cast, [:msg, :state], stuple([:stop, stuple([:bad_cast, {:var, :msg}]), {:var, :state}]))]

  # `_msg`, not `msg`: this default DISCARDS the message (an unexpected
  # info is not an error — OTP delivers monitor and system messages here),
  # and naming a variable it never reads made every server that omitted
  # `handle-info` emit an "unused variable" warning pointing at the user's
  # `defserver` line, blaming their code for the compiler's default.
  defp server_defaults(:handle_info),
    do: [default_def(:handle_info, [:_msg, :state], stuple([:noreply, {:var, :state}]))]

  defp server_defaults(:terminate), do: [default_def(:terminate, [:_reason, :_state], :ok)]
  defp server_defaults(:code_change), do: [default_def(:code_change, [:_old_vsn, :state, :_extra], stuple([:ok, {:var, :state}]))]
  defp server_defaults(_), do: []

  # A `def` whose head/body vars carry nil context, so the node is safe to
  # splice into a generated module (the vars stay locals there).
  defp default_def(fname, arg_names, body_ast) do
    vars = for n <- arg_names, do: {n, [], nil}
    {:def, [], [{fname, [], vars}, [do: body_ast]]}
  end

  # A tiny AST builder for default bodies: `stuple([:reply, {:var, :r}, {:var, :s}])`
  # makes the tuple `{:reply, r, s}` where `{:var, n}` is a nil-context var and
  # a bare atom is a literal tag.
  defp stuple(elems) do
    {:{}, [], Enum.map(elems, fn
      {:var, n} -> {n, [], nil}
      {:{}, [], _} = t -> t
      atom when is_atom(atom) -> atom
    end)}
  end

  # Client fns so a server is usable without raw interop: `start`/`start-link`
  # (with OTP options incl. `:name` registration), `call` (with timeout),
  # `cast`, and `stop`. All reference `__MODULE__` so they work on whatever
  # generated module they are spliced into.
  defp server_client_defs do
    gs = quote(do: GenServer)
    m = quote(do: __MODULE__)

    [
      client_def(:start, [:init_arg, :opts], %{opts: []}, {{:., [], [gs, :start]}, [], [m, svar(:init_arg), svar(:opts)]}),
      client_def(:start_link, [:init_arg, :opts], %{opts: []},
        {{:., [], [gs, :start_link]}, [], [m, svar(:init_arg), svar(:opts)]}
      ),
      client_def(:call, [:server, :request, :timeout], %{timeout: 5000},
        {{:., [], [gs, :call]}, [], [svar(:server), svar(:request), svar(:timeout)]}
      ),
      client_def(:cast, [:server, :request], %{},
        {{:., [], [gs, :cast]}, [], [svar(:server), svar(:request)]}
      ),
      client_def(:stop, [:server, :reason, :timeout], %{reason: :normal, timeout: :infinity},
        {{:., [], [gs, :stop]}, [], [svar(:server), svar(:reason), svar(:timeout)]}
      )
    ]
  end

  defp client_def(fname, arg_names, defaults, body_ast) do
    args =
      Enum.map(arg_names, fn n ->
        case Map.get(defaults, n) do
          nil -> svar(n)
          d -> {:\\, [], [svar(n), d]}
        end
      end)

    {:def, [], [{fname, [], args}, [do: body_ast]]}
  end

  defp svar(n), do: {n, [], nil}

  # [other.ns :as o] / [other.ns :refer [x y]] / other.ns — and both
  # flags at once, as Clojure allows.
  defp parse_require_spec({:symbol, target}), do: {target, nil, []}

  defp parse_require_spec({:vector, [{:symbol, target} | flags]}) do
    {as_alias, refer_syms} =
      Enum.reduce(flags, {nil, []}, fn
        {:keyword, "as"}, {_prev, refers} -> {{:expecting, "as"}, refers}
        {:keyword, "refer"}, {as_alias, _prev} -> {as_alias, {:expecting, "refer"}}
        {:symbol, a}, {{:expecting, "as"}, refers} -> {a, refers}
        # `:refer :all` — the blanket form. Kept as an atom rather than
        # expanded here: which names exist is only knowable once the
        # require has actually loaded the target.
        {:keyword, "all"}, {as_alias, {:expecting, "refer"}} -> {as_alias, :all}
        {:vector, syms}, {as_alias, {:expecting, "refer"}} ->
          {as_alias, Enum.map(syms, fn {:symbol, s} -> s end)}
        other, _acc -> raise "invalid :require spec for #{target}: #{inspect(other)}"
      end)

    {target, as_alias, refer_syms}
  end

  defp parse_require_spec(other), do: raise("invalid :require spec: #{inspect(other)}")

  # --- macros ---

  @doc """
  One top-level macroexpansion step: if `form` is a call to a macro
  visible in `ns`, expand it once; otherwise return it unchanged.

  AOT's value-def capture uses this to see through defining macros —
  `(defsmell …)`, `(defrule …)` and any user macro that EXPANDS TO a
  `def`. Without it the capture classified the unexpanded call (not a
  `def`), the definition was never replayed by `__bl_init__`, and the
  var simply did not exist after an AOT load.
  """
  def macroexpand_1({:list, [{:symbol, name} | args]} = form, ns) do
    if name in @special_forms do
      form
    else
      case macro_for(ns, name) do
        {:ok, m} -> expand_macro(m, form, args, new_env(ns))
        :error -> form
      end
    end
  end

  def macroexpand_1(form, _ns), do: form

  # Macros resolve at compile time against the live registry, so a
  # defmacro must precede its callers in the same session.
  defp macro_for(ns, name) do
    # `peek`, not `fetch`: probing whether a name is a macro at COMPILE time must
    # not materialize a `^:per-env` value. A per-env descriptor is never a macro,
    # so it correctly falls through to `:error`.
    case Env.peek(ns, core_qualified(name)) do
      {:ok, {:"$macro", m}} -> {:ok, m}
      _ -> :error
    end
  end

  # jank names its core `clojure.core` for Clojure compatibility; beam-lisp's
  # core ns is `core`. Rewrite the qualified prefix so upstream
  # `clojure.core/…` references resolve unchanged. Compiler-side, because
  # Env.candidates/2 (which owns the resolution rules) lives in env.ex.
  defp core_alias("clojure.core"), do: "core"
  defp core_alias(ns), do: ns

  defp core_qualified(name) do
    case String.split(name, "/", parts: 2) do
      ["clojure.core", var] -> "core/" <> var
      _ -> name
    end
  end

  # Call the macro with the *unevaluated* argument forms as data,
  # then reinterpret the data it returns as a form to compile.
  # Vectors-as-data round-trip as `%BeamLisp.Vector{}`, which is why
  # macros needed a real vector type: `(fn [x] …)` and `[x]` must
  # not collapse into each other.
  defp expand_macro(macro_fn, form, args, env) do
    [datum(form), macro_env(env) | Enum.map(args, &datum/1)]
    |> then(&BeamLisp.RT.invoke(macro_fn, &1))
    |> data_to_form()
  end

  # `&env`: the call site's locals as a map of symbol => name. beam-lisp
  # locals are compiler AST vars (not inspectable data), so the NAMES are
  # the useful surface — `(contains? &env 'x)` sees the call site's locals.
  defp macro_env(env) do
    Map.new(env.locals, fn {name, _var} -> {{:symbol, name}, name} end)
  end

  defp data_to_form({:symbol, _name} = sym), do: sym

  defp data_to_form(%BeamLisp.Vector{meta: m} = v) do
    vform = {:vector, Enum.map(BeamLisp.Vector.to_list(v), &data_to_form/1)}
    # A vector produced/returned by a macro may carry AUTHOR metadata
    # (`^{:key …}`); re-wrap it so `compile/2` lowers the key back onto the
    # value. `nil`/empty meta round-trips as a bare vector form, unchanged.
    # is_map-ok: `m` is the reader's author-metadata map (a plain internal
    # Elixir map), never a beam-lisp map value.
    if is_map(m) and map_size(m) > 0, do: {:meta, vform, m}, else: vform
  end

  defp data_to_form(%BeamLisp.Set{} = s),
    do: {:set, Enum.map(BeamLisp.Set.to_list(s), &data_to_form/1)}

  defp data_to_form(items) when is_list(items),
    do: {:list, Enum.map(items, &data_to_form/1)}

  # Only a *plain* map is map data. Every other struct-backed beam-lisp value
  # (a record, a lazy seq, an atom-ref) is a value in its own right and falls
  # through to the literal clause below -- mangling one into `{:map, ...}` here
  # would hand a macro a map where the author passed a record.
  defp data_to_form(m) when is_bl_map(m),
    do: {:map, Enum.map(m, fn {k, v} -> {data_to_form(k), data_to_form(v)} end)}

  defp data_to_form(a) when is_atom(a) and a not in [nil, true, false],
    do: {:keyword, Atom.to_string(a)}

  # A `{:meta, form, m}` datum wrapper survives the boundary as a form
  # node; nil metadata is cleared (the bare form).
  defp data_to_form({:meta, form, nil}), do: data_to_form(form)
  defp data_to_form({:meta, form, m}), do: {:meta, data_to_form(form), m}

  defp data_to_form(lit), do: lit

  # --- syntax-quote ---

  # Emits AST that *builds* the datum at runtime, with ~ and ~@
  # punching holes back into evaluated code. The third arg is the
  # per-syntax-quote gensym map; every clause passes it back so a
  # `x#` rename seen in an earlier sibling is visible to later ones.
  #
  # A syntax-quoted list may carry a reader position (only lists do under
  # the narrowed design); unwrap it so the shape clauses see the bare
  # form, while the nested items stay wrapped so their own positions
  # re-capture when compiled.
  defp synq_data({:meta, _inner, _m} = form, env, g), do: synq_data(unwrap_meta(form), env, g)

  defp synq_data({:list, [{:symbol, "unquote"}, x]}, env, g),
    do: {compile_elixir(x, notail(env)), g}

  defp synq_data({:list, [{:symbol, "unquote-splicing"}, _]}, _env, _g),
    do: raise("~@ is only valid inside a syntax-quoted list or vector")

  # A nested syntax-quote gets its own fresh map: its `#` symbols must
  # not collide with the enclosing quote's gensyms.
  defp synq_data({:list, [{:symbol, "syntax-quote"}, inner]}, env, g) do
    {inner_ast, _} = synq_data(inner, env, %{})
    {[{:|, [], [{:symbol, "syntax-quote"}, [{:|, [], [inner_ast, []]}]]}], g}
  end

  defp synq_data({:list, items}, env, g), do: synq_list(items, env, g)

  defp synq_data({:vector, items}, env, g) do
    {items_ast, g2} = synq_list(items, env, g)

    {quote do
       BeamLisp.Vector.new(unquote(items_ast))
     end, g2}
  end

  defp synq_data({:map, kvs}, env, g) do
    {pairs, g2} =
      Enum.reduce(kvs, {[], g}, fn {k, v}, {acc, gacc} ->
        {kast, g1} = synq_data(k, env, gacc)
        {vast, g2} = synq_data(v, env, g1)
        {[{kast, vast} | acc], g2}
      end)

    {{:%{}, [], Enum.reverse(pairs)}, g2}
  end

  # A symbol inside a syntax-quote is resolved IN THE NAMESPACE THAT WROTE IT,
  # as Clojure does, and emitted qualified. Without this a macro cannot call
  # its own helper: expanding `(helper x)` at a call site in another namespace
  # produced a bare `helper`, which resolved against the CALLER and failed with
  # "undefined var: caller-ns/helper". That is the ordinary shape of every
  # library macro, so the gap was reachable by anyone writing one.
  #
  # Only names that actually resolve where the macro was written are qualified.
  # A gensym (`x#`), a name that resolves to nothing (a fresh binding the
  # template introduces), and a name already carrying a `/` are all left alone --
  # qualifying those would break templates that legitimately bind new locals.
  defp synq_data({:symbol, name}, env, g) do
    {resolved, g2} = resolve_gensym(name, g)
    {Macro.escape({:symbol, qualify_synq(resolved, env)}), g2}
  end

  defp synq_data({:keyword, name}, _env, g), do: {BeamLisp.AtomGuard.to_atom(name), g}
  defp synq_data(lit, _env, g), do: {lit, g}

  defp qualify_synq(name, env) do
    cond do
      String.contains?(name, "/") -> name
      String.ends_with?(name, "__auto") -> name
      special_or_local?(name, env) -> name
      true -> qualified_or_bare(name, env)
    end
  end

  # Where a var visible from `ns` actually lives: `ns` itself when it is
  # defined there, otherwise whichever namespace referred it in.
  defp owner_ns(ns, name) do
    if Env.local_var?(ns, name), do: ns, else: Env.refer_source(ns, name) || ns
  end

  # Special forms and the template's own locals must stay bare: they are not
  # vars and have no namespace to belong to.
  defp special_or_local?(name, env),
    do: name in @special_forms or Map.has_key?(env.locals, name)

  defp qualified_or_bare(name, env) do
    ns = env.ns

    cond do
      # A MACRO stays bare. Macros are expanded by `macro_for/2`, which already
      # searches the writing namespace and core, so qualification buys nothing --
      # and it actively broke `(when …)` inside a template, because a qualified
      # macro name reached the call path as an ordinary var and was invoked as a
      # function. Every vendored jank macro that nests `when`/`let` hit this.
      macro?(name, ns) -> name
      # A var the writing namespace defines or refers. A referred var is
      # qualified with the namespace that OWNS it, not the one doing the
      # referring — `p/RichNavigator` referred into `navs` and then
      # syntax-quoted must expand to `protocols/RichNavigator`, because
      # that is where the var lives and where the expansion site will
      # look. Qualifying it to the writer invented a name resolving
      # nowhere.
      Env.bound?(ns, name) -> owner_ns(ns, name) <> "/" <> name
      # Anything else is a name the template introduces (a `let` binding, a fn
      # parameter, a var defined later). Leave it bare so it resolves at the
      # expansion site, which is what those templates mean.
      true -> name
    end
  end

  defp macro?(name, ns), do: match?({:ok, _}, macro_for(ns, name))

  defp synq_list(items, env, g) do
    Enum.reduce(Enum.reverse(items), {[], g}, fn item, {acc, gacc} ->
      case unwrap_meta(item) do
        # `~@` splices any seqable, not just a list — jank's own macros
        # splice binding *vectors*, and `++` demands a list.
        {:list, [{:symbol, "unquote-splicing"}, x]} ->
          {quote(do: BeamLisp.RT.splice(unquote(compile_elixir(x, notail(env))), unquote(acc))), gacc}

        _ ->
          {item_ast, g2} = synq_data(item, env, gacc)
          {[{:|, [], [item_ast, acc]}], g2}
      end
    end)
  end

  # `x#` (longer than one char) auto-gensyms to `x__N__auto`, stably
  # within one syntax-quote. A `#` anywhere else in a symbol is kept.
  defp resolve_gensym(name, g) do
    if gensym?(name) do
      case Map.fetch(g, name) do
        {:ok, gen} -> {gen, g}
        :error -> gen = gensym_name(name); {gen, Map.put(g, name, gen)}
      end
    else
      {name, g}
    end
  end

  defp gensym?(name), do: byte_size(name) > 1 and String.ends_with?(name, "#")

  defp gensym_name(name) do
    base = binary_part(name, 0, byte_size(name) - 1)
    base <> "__" <> Integer.to_string(System.unique_integer([:positive])) <> "__auto"
  end

  # --- special form helpers ---

  # The var's metadata map as an Elixir AST, or nil when there is nothing
  # to write. The docstring and `private` flag are literals; each `^{...}` /
  # attr-map value is a reader FORM lowered to a runtime value, so `meta`
  # reads real data (a string, a fn, a quoted list), not reader data. A
  # bare symbol value (`^String` on a name) is NOT compiled — that would
  # resolve it as a var — it is kept as the symbol datum Clojure stores,
  # matching datum/1.
  defp var_meta_ast(doc, private, attr, env) do
    entries =
      (if doc, do: [doc: doc], else: []) ++
        (if private, do: [private: true], else: []) ++
        Enum.map(attr || %{}, fn {k, v} -> {k, attr_value_ast(v, env)} end)

    case entries do
      [] -> nil
      entries -> {:%{}, [], entries}
    end
  end

  # Metadata values are DATA, not code. `^{:args [int]}` stores the
  # vector [int] of SYMBOLS — exactly what Clojure's reader metadata does.
  # The earlier behaviour compiled each value as a form: `[int]` became a
  # runtime fn capture (&Core.int/1), bare symbols stayed raw reader
  # tuples, and type-expression metadata (unions, fn types, holes) was
  # impossible because storing it meant CALLING it. `datum/1` is quote's
  # own form → data bridge; macro-attached values arrive as runtime data
  # already (vary-meta), so they escape directly.
  defp attr_value_ast(form, _env) do
    data = if bl_form?(form), do: datum(form), else: form
    Macro.escape(unquote_data(data))
  end

  # `'(…)` written in source and `(list 'quote …)` built by a macro (the
  # defnav :arglists stamp) both use one quote layer to MEAN "the datum,
  # literally". Now that metadata is stored as data rather than evaluated,
  # that layer is intent, not content — strip exactly one.
  defp unquote_data([{:symbol, "quote"}, x]), do: x
  defp unquote_data(x), do: x

  # Reader forms are tagged tuples; anything else reaching a metadata value is
  # runtime data a macro put there.
  defp bl_form?({tag, _}) when is_atom(tag), do: true
  defp bl_form?({:meta, _, _}), do: true
  defp bl_form?(_), do: false

  # The user-metadata map a `^{...}` reader form attached to a def/defn
  # name symbol. The name form is `{:meta, {:symbol, name}, m}` where `m`
  # holds exactly the author's `^` metadata — positions never attach to
  # symbols, so there is no `:line`/`:file` to filter out.
  # is_map-ok: reader metadata is a plain internal Elixir map, never a
  # beam-lisp value -- a struct can never reach this position.
  defp name_meta({:meta, _form, m}) when is_map(m), do: m
  defp name_meta(_), do: nil

  defp compile_def(name, init_ast, env, doc, attr) do
    if per_env_attr?(attr) do
      compile_per_env_def(name, init_ast, env, doc, attr)
    else
      intern_ast =
        quote do
          BeamLisp.Env.intern(unquote(env.ns), unquote(name), unquote(init_ast))
        end

      if meta = var_meta_ast(doc, false, attr, env) do
        # def returns the interned value; the meta write is a side effect.
        quote do
          value = unquote(intern_ast)
          BeamLisp.Env.put_meta(unquote(env.ns), unquote(name), unquote(meta))
          value
        end
      else
        intern_ast
      end
    end
  end

  # `^:per-env` metadata on a def name (reader lowers `^:per-env` to the atom key
  # `:"per-env"` => true in the name-meta map).
  defp per_env_attr?(attr) when is_map(attr), do: attr[:"per-env"] == true
  defp per_env_attr?(_), do: false

  # A `^:per-env` value def: register a re-runnable init THUNK (not a value) so
  # each consuming env materializes its own instance on first read. The thunk is
  # `fn -> init_ast end`; wrapping the already-compiled initializer in a
  # zero-arity Elixir fn anchors any closure it builds to THIS form's throwaway
  # eval module (source path) or the stable Init companion (AOT path) — neither
  # is reloaded, so the thunk stays callable across namespace churn.
  defp compile_per_env_def(name, init_ast, env, doc, attr) do
    define_ast =
      quote do
        BeamLisp.Env.define_per_env(unquote(env.ns), unquote(name), fn -> unquote(init_ast) end)
      end

    if meta = var_meta_ast(doc, false, attr, env) do
      quote do
        _ = unquote(define_ast)
        BeamLisp.Env.put_meta(unquote(env.ns), unquote(name), unquote(meta))
        # A marked def is opt-in and returns :ok, NOT the value — returning the
        # value would force eager materialization at definition time.
        :ok
      end
    else
      define_ast
    end
  end

  defp compile_if(test, then, else_, env) do
    {:if, [],
     [compile_elixir(test, notail(env)), [do: compile_elixir(then, env), else: compile_elixir(else_, env)]]}
  end

  # Like compile_bindings, but split for loop: `params` are the recur
  # params (one per binding; a destructure's param is its whole value),
  # `entry_binds` destructure those at loop entry, and `arg_asts` are
  # the initial values passed on the first call.
  defp loop_bindings(bindings, env) do
    pairs = Enum.chunk_every(bindings, 2)

    unless Enum.all?(pairs, &(length(&1) == 2)) do
      compile_error(env, "binding forms must be even, each a pattern and a value")
    end

    Enum.reduce(pairs, {[], [], [], env}, fn [pattern_form, init], {params, entry, arg_asts, acc_env} ->
      init_ast = compile_elixir(init, acc_env)

      case peel_hint(pattern_form) do
        {:symbol, name} ->
          var = fresh_var(name)
          {params ++ [var], entry, arg_asts ++ [init_ast], put_local(acc_env, name, var)}

        destructure ->
          whole = fresh_var("whole")
          {sub_steps, new_env} = destructure_steps(destructure, acc_env, whole)
          {params ++ [whole], entry ++ sub_steps, arg_asts ++ [init_ast], new_env}
      end
    end)
  end

  # Sequential destructuring bindings, shared by let and loop.
  # Returns `{steps, env'}` where steps are `{param_pattern, arg_ast}`
  # pairs; a destructured binding becomes a whole-value step followed
  # by a pattern-match step (and an `:as` step for maps).
  defp compile_bindings(bindings, env) do
    pairs = Enum.chunk_every(bindings, 2)

    unless Enum.all?(pairs, &(length(&1) == 2)) do
      compile_error(env, "binding forms must be even, each a pattern and a value")
    end

    Enum.reduce(pairs, {[], env}, fn [pattern_form, init], {steps, acc_env} ->
      init_ast = compile_elixir(init, acc_env)

      case peel_hint(pattern_form) do
        {:symbol, name} ->
          var = fresh_var(name)
          {steps ++ [{var, init_ast}], put_local(acc_env, name, var)}

        destructure ->
          whole = fresh_var("whole")
          {sub_steps, new_env} = destructure_steps(destructure, acc_env, whole)
          {steps ++ [{whole, init_ast}] ++ sub_steps, new_env}
      end
    end)
  end

  # `(fn [p…] body…)` and `(fn ([p…] body…) ([p q…] body…))` both
  # normalize to a list of `{params, guard, body}` clauses; the same
  # normalization covers single- and multi-arity `defn`.
  #
  # A clause may carry a `:when` guard between its parameter vector and
  # its body. That keyword was previously READ AS A BODY FORM — it
  # evaluated to itself and was discarded, so `(defn f [x] :when (number? x)
  # …)` compiled, ran, and applied no guard whatsoever. Silence on a
  # construct the author clearly meant is the worst of the three options
  # (guard / error / ignore), so it now means what it looks like.
  defp fn_clauses([{:vector, params} | body], env) do
    {guard, body} = clause_guard(body, env)
    [{params, guard, body}]
  end

  defp fn_clauses(clauses, env) do
    Enum.map(clauses, fn clause ->
      case unwrap_meta(clause) do
        {:list, [{:vector, params} | body]} ->
          {guard, body} = clause_guard(body, env)
          {params, guard, body}

        other ->
          compile_error(
            env,
            "invalid fn clause: #{inspect(other)} (a clause is `([params…] body…)`)"
          )
      end
    end)
  end

  defp clause_guard(body, env) do
    case split_guard(body) do
      {:missing, _} ->
        compile_error(env, "`:when` must be followed by a guard expression")

      {guard, []} when guard != nil ->
        compile_error(env, "a guarded clause still needs a body after its `:when` guard")

      pair ->
        pair
    end
  end

  # Every macro fn receives `&form`/`&env` as its first two params — the
  # whole call form and the compile-time env — whether or not the body
  # names them. Inject them so `&form`/`&env` resolve as locals;
  # expand_macro always prepends the matching values.
  defp macro_clauses([{params, guard, body} | rest]),
    do: [{macro_params(params), guard, body} | macro_clauses(rest)]

  defp macro_clauses([]), do: []

  defp macro_params([{:symbol, "&form"}, {:symbol, "&env"} | _] = p), do: p
  defp macro_params(p), do: [{:symbol, "&form"}, {:symbol, "&env"} | p]

  # A single-arity fn compiles to a real Elixir fn — passable to
  # `Enum`, storable in a var, callable via `apply/2`. Elixir fns are
  # fixed-arity, so multi-clause and variadic fns get a tag that
  # `RT.invoke/2` dispatches on.
  #
  # Every clause is also a recur target (as in Clojure): the clause
  # fn is wrapped in self-application, and `recur` in tail position
  # re-enters it in constant stack. Inner fns shadow outer targets,
  # so recur never crosses a fn boundary.
  #
  # Clauses of the SAME arity are grouped into ONE Elixir fn with several
  # `->` clauses, which is how a guard earns its keep here: the BEAM picks
  # the first whose guard holds. Before grouping, `$blfn`'s dispatch map
  # was keyed by arity alone, so a second same-arity clause silently
  # replaced the first — dead code that looked live.
  #
  # `recur` inside a grouped fn re-enters the DISPATCHER, not the clause it
  # was written in, so a recur whose new arguments fail this clause's guard
  # lands in the next one. That is the useful reading (it is what makes a
  # guarded loop able to change mode) and the only one available: the
  # clauses share a self-application wrapper, because they share one fn.
  defp compile_fn(clauses, env, opts \\ []) do
    nil_rest = Keyword.get(opts, :nil_rest, false)
    fn_name = Keyword.get(opts, :name)

    # One `self` var per SHAPE, allocated before anything is compiled: the
    # shape is readable from the params alone, and every clause of a shape
    # must recur into the same dispatcher.
    selves =
      clauses
      |> Enum.map(fn {params, _, _} -> clause_shape(params) end)
      |> Enum.uniq()
      |> Map.new(fn shape -> {shape, fresh_var("fnself")} end)

    # Compiled in SOURCE order (macro expansion is observable), then grouped
    # for emission.
    compiled_clauses =
      Enum.map(clauses, fn {params, guard, body} ->
        shape = clause_shape(params)
        self = Map.fetch!(selves, shape)

        {head_vars, guard_ast, body_ast, _n, _v?} =
          compile_clause(env, params, guard, body, %{self: self}, nil_rest, fn_name)

        {shape, self, guard_ast, {head_vars, body_ast}}
      end)

    compiled =
      compiled_clauses
      |> group_by_shape(fn {shape, _, _, _} -> shape end)
      |> Enum.map(&compile_fn_group/1)

    case compiled do
      [{:fixed, _arity, fn_ast}] ->
        fn_ast

      clauses ->
        fixed = for {:fixed, arity, ast} <- clauses, do: {arity, ast}
        variadic = Enum.find_value(clauses, fn
          {:variadic, min, ast} -> {min, ast}
          _ -> nil
        end)

        variadic_ast =
          case variadic do
            nil -> nil
            {min, ast} -> {:{}, [], [min, ast]}
          end

        {:{}, [], [:"$blfn", {:%{}, [], fixed}, variadic_ast]}
    end
  end

  # The dispatch identity of a clause: `{:fixed, n}` or `{:variadic, n}`.
  # Two clauses share an Elixir fn exactly when they share this.
  defp clause_shape(params) do
    {fixed, rest} = split_variadic(params)
    if rest == nil, do: {:fixed, length(fixed)}, else: {:variadic, length(fixed)}
  end

  # Group ALREADY-COMPILED items by shape, keeping source order within each
  # group and ordering groups by first appearance.
  #
  # Grouping is by shape, NOT by adjacency: Clojure conventionally writes
  # arities in ascending order, but nothing enforces it, and a chunk of
  # adjacent clauses would put two non-adjacent same-arity clauses in two
  # groups — reintroducing the silent-overwrite bug for exactly the
  # authors who interleaved.
  #
  # It takes COMPILED items rather than source clauses because compiling a
  # body EXPANDS ITS MACROS, and macro expansion is observable: a macro
  # that gensyms, counts, or otherwise carries state would see clauses in
  # grouped order rather than the order they were written. Compilation
  # order is the author's; emission order is the BEAM's requirement. Only
  # the second one gets rearranged.
  defp group_by_shape(items, shape_of) do
    items
    |> Enum.group_by(shape_of)
    |> Enum.sort_by(fn {shape, _} ->
      Enum.find_index(items, fn item -> shape_of.(item) == shape end)
    end)
    |> Enum.map(fn {_shape, group} -> group end)
  end

  # One arity's clauses → one self-applied Elixir fn. The `self` var is
  # created ONCE for the group, because every clause recurs into the same
  # dispatcher.
  defp compile_fn_group([{shape, self, _, _} | _] = group) do
    fn_clause_asts =
      Enum.map(group, fn {_shape, _self, guard_ast, {head_vars, body_ast}} ->
        {:->, [], [guarded_head(head_vars, guard_ast), body_ast]}
      end)

    fn_ast = self_apply(self, {:fn, [], fn_clause_asts})

    case shape do
      {:fixed, n} -> {:fixed, n, fn_ast}
      {:variadic, n} -> {:variadic, n, fn_ast}
    end
  end

  # `(fn s -> fn … -> body end end).(itself)` — self-application,
  # tail-call-optimized on the BEAM; shared by loop and fn recur.
  defp self_apply(self, inner_fn) do
    outer_fn = {:fn, [], [{:->, [], [[self], inner_fn]}]}
    {{:., [], [outer_fn]}, [], [outer_fn]}
  end

  # Compile one `{params, guard, body}` fn clause. Returns
  # `{head_vars, guard_ast, body_ast, fixed_param_count, variadic?}`; the
  # caller picks the recur target via `recur_spec` (`%{self: var}`
  # for anonymous fns, `%{self_call: {mod, fname}}` for linked
  # defns) and decides how to wrap the result.
  #
  # The guard is compiled against the env AFTER the params bind, so it
  # sees every name the head established — including destructured ones,
  # whose bindings are body preludes rather than head vars. A guard over
  # a destructured name would therefore reference a variable that is not
  # yet bound when the BEAM evaluates the head, which is why
  # `guardable_env/2` narrows what a guard may see to the head vars.
  defp compile_clause(env, params, guard, body, recur_spec, nil_rest \\ false, fn_name \\ nil) do
    {fixed, rest} = split_variadic(params)
    {head_vars, preludes, clause_env} = bind_params(env, fixed)

    {head_vars, rest_prelude, clause_env} =
      case rest do
        nil ->
          {head_vars, [], clause_env}

        {:symbol, name} ->
          rest_var = fresh_var(name)

          if nil_rest do
            # jank binds a macro's trailing `& rest` to nil when there are
            # no extra args (`(variadic)` == nil in jank's own test); the
            # if-let/when-let assert-macro-args checks `(nil? oldform)`.
            # beam-lisp fns keep Clojure's `()` for an empty rest (tested
            # in wave2); only macros normalize to nil.
            raw = fresh_var("rest")
            norm = quote do: (if unquote(raw) == [], do: nil, else: unquote(raw))
            {head_vars ++ [raw], [{:=, [], [rest_var, norm]}], put_local(clause_env, name, rest_var)}
          else
            {head_vars ++ [rest_var], [], put_local(clause_env, name, rest_var)}
          end

        pattern ->
          # A destructuring pattern in the rest position: bind the
          # trailing args to a fresh var, then run the same destructuring
          # as a fixed param. The rest is always a positional seq, so an
          # empty rest arrives as `()`; normalize it to nil first, because
          # Clojure's `&` binds an exhausted rest to nil and jank's
          # variadic recursion relies on the base case seeing nil: an
          # empty list is truthy, so `(when more ...)` would loop forever
          # instead of terminating. The pattern then destructures nil
          # leniently (every name nil); `:as` in the pattern binds nil too.
          rest_var = fresh_var("rest")
          raw = fresh_var("rest_raw")
          norm = quote do: (if unquote(raw) == [], do: nil, else: unquote(raw))
          {sub_steps, clause_env} = rest_destructure(pattern, clause_env, rest_var)

          rest_prelude =
            [{:=, [], [rest_var, norm]} |
               Enum.map(sub_steps, fn {var, expr} -> {:=, [], [var, expr]} end)]

          {head_vars ++ [raw], rest_prelude, clause_env}
      end

    recur = Map.put(recur_spec, :arity, length(head_vars))
    fn_env = %{clause_env | recur: recur, tail: true}

    # A named fn sees its own name bound to the fn itself (`self.(self)`
    # recovers the real clause fn from the self-application wrapper),
    # enabling self-recursion. Only anonymous `(fn name …)` sets fn_name.
    fn_env =
      if fn_name do
        self = recur_spec[:self]
        self_app = {{:., [], [self]}, [], [self]}
        put_local(fn_env, fn_name, self_app)
      else
        fn_env
      end

    # A guard runs BEFORE the body, so it can only see the head's own
    # variables — a destructured name is bound by a body prelude that has
    # not run yet. Compiling against the narrowed env turns what would be
    # an "undefined variable" from generated Elixir into this language's
    # own message, naming the parameter and the reason.
    guard_ast = compile_guard(guard, guardable_env(clause_env, head_vars))

    body_ast = block(preludes ++ rest_prelude ++ [block_forms(body, fn_env)])
    {head_vars, guard_ast, body_ast, length(fixed), rest != nil}
  end

  # The env a guard may read: only the locals bound to a variable that is
  # actually in the clause head. Everything else — destructured names,
  # outer closure locals — is out of scope for a BEAM guard.
  defp guardable_env(env, head_vars) do
    in_head = MapSet.new(head_vars)
    %{env | locals: Map.filter(env.locals, fn {_name, ast} -> MapSet.member?(in_head, ast) end)}
  end

  defp split_variadic(params) do
    case Enum.split_while(params, &(&1 != {:symbol, "&"})) do
      {fixed, []} ->
        {fixed, nil}

      # The rest position may hold a bare symbol OR a destructuring
      # pattern (`& [a b]`, `& {:keys [x]}`). Clojure treats the rest
      # as the collection to destructure; the destructuring sites decide
      # which shapes they accept. split_variadic's only contract is
      # "exactly one form follows &".
      {fixed, [{:symbol, "&"}, rest]} ->
        {fixed, rest}

      _ ->
        raise "& in params must be followed by exactly one parameter"
    end
  end

  # Clojure binds an exhausted `& rest` to nil, not to an empty
  # collection. Upstream code loops on `(when more …)`, and `[]` is
  # truthy — binding `[]` here made jank's assoc-in/update-in recurse
  # forever rather than fail visibly. A rest PATTERN then destructures
  # that nil leniently (every name nil) instead of crashing at the base.
  defp rest_drop_ast(whole_ast, fixed_count) do
    quote do
      case BeamLisp.RT.drop(unquote(whole_ast), unquote(fixed_count)) do
        [] -> nil
        dropped -> dropped
      end
    end
  end

  # A rest pattern destructures a positional SEQ, so only sequential
  # shapes are meaningful there. Clojure compiles `& {:keys [x]}` but it
  # silently binds every key to nil (a seq is not a map) — a footgun,
  # not a feature — so beam-lisp refuses a map rest loudly instead.
  defp rest_destructure({:map, _}, _env, _rest_var) do
    raise "& rest pattern cannot be a map: the rest is a positional seq; use a vector pattern (& [a b]) or destructure the map as a fixed param"
  end

  defp rest_destructure(pattern, env, rest_var) do
    destructure_steps(pattern, env, rest_var)
  end

  # Simple symbol params go straight into the fn head; destructured
  # params bind a fresh var there and destructure in a body prelude.
  defp bind_params(env, params) do
    {vars, preludes, acc_env} =
      Enum.reduce(params, {[], [], env}, fn param, {vars, preludes, acc_env} ->
        case peel_hint(param) do
          {:symbol, name} ->
            var = fresh_var(name)
            {vars ++ [var], preludes, put_local(acc_env, name, var)}

          destructure ->
            whole = fresh_var("whole")
            {sub_steps, acc_env} = destructure_steps(destructure, acc_env, whole)
            prelude = Enum.map(sub_steps, fn {var, expr_ast} -> {:=, [], [var, expr_ast]} end)
            {vars ++ [whole], preludes ++ prelude, acc_env}
        end
      end)

    {vars, preludes, acc_env}
  end

  # Destructuring, Clojure-style: lenient. `[a b & rest]` compiles
  # to nth/drop lookups (extra elements ignored, missing ones nil);
  # `{:keys [a] :as m}` compiles to `get` lookups (missing keys nil).
  # Returns `{steps, env'}` where steps are `{var, expr_ast}` pairs
  # whose exprs read from `whole_ast`.
  # `^Tag x` arrives as `{:meta, {:symbol, x}, %{tag: ...}}`, and `^:a ^Tag x`
  # merges into one wrapper. A type hint on a binding target is a no-op
  # optimization hint in Clojure, so peel it and bind exactly as the bare
  # target would. The clause recurses so even stacked wrappers collapse to
  # the underlying pattern (the wave-20 contract: LEADING peel clause).
  defp destructure_steps({:meta, _inner, _m} = form, env, whole_ast),
    do: destructure_steps(unwrap_meta(form), env, whole_ast)

  defp destructure_steps({:symbol, name}, env, whole_ast) do
    var = fresh_var(name)
    {[{var, whole_ast}], put_local(env, name, var)}
  end

  defp destructure_steps({:vector, elems}, env, whole_ast) do
    {elems, as_name} = peel_as_bind(elems)
    {fixed, rest} = split_variadic(elems)

    {steps, env} =
      fixed
      |> Enum.with_index()
      |> Enum.map_reduce(env, fn {elem, i}, acc_env ->
        nth_ast =
          quote do
            BeamLisp.RT.nth(unquote(whole_ast), unquote(i))
          end

        destructure_steps(elem, acc_env, nth_ast)
      end)

    {rest_steps, env} =
      case rest do
        nil ->
          {[], env}

        {:symbol, name} ->
          rest_var = fresh_var(name)
          {[{rest_var, rest_drop_ast(whole_ast, length(fixed))}], put_local(env, name, rest_var)}

        pattern ->
          # A pattern in the rest position destructures the trailing seq
          # exactly like a fixed param, against the same nil-normalized
          # rest (`:as` binds the whole rest, nested vectors recurse).
          rest_var = fresh_var("rest")
          {sub_steps, env} = rest_destructure(pattern, env, rest_var)
          {[{rest_var, rest_drop_ast(whole_ast, length(fixed))}] ++ sub_steps, env}
      end

    # `:as` mirrors the map clause: bind the ENTIRE original collection
    # to the name, untouched — a vector stays a vector, a lazy seq stays
    # lazy. Clojure binds the whole collection, not the remainder, and
    # it does so even when the `& rest` is exhausted to nil.
    {as_steps, env} =
      case as_name do
        nil ->
          {[], env}

        name ->
          as_var = fresh_var(name)
          {[{as_var, whole_ast}], put_local(env, name, as_var)}
      end

    {Enum.concat(steps) ++ rest_steps ++ as_steps, env}
  end

  defp destructure_steps({:map, kvs}, env, whole_ast) do
    # Collect the binds and the `:or` defaults in one pass, so any
    # default can apply to a symbol bound by the same map. Clojure
    # compiles each to `(get m key default)`: the default applies when
    # the key is absent (or the map is nil), while a present nil stays
    # nil — exactly `Map.get/3` semantics.
    {binds, ors} =
      Enum.reduce(kvs, {[], %{}}, fn
        {{:keyword, "or"}, {:map, or_kvs}}, {binds, ors} ->
          defaults =
            Map.new(or_kvs, fn
              {key_form, default} ->
                case peel_hint(key_form) do
                  {:symbol, k} -> {k, default}
                  other -> raise "unsupported :or binding: #{inspect(other)}"
                end

              other -> raise "unsupported :or binding: #{inspect(other)}"
            end)

          {binds, Map.merge(ors, defaults)}

        {{:keyword, "keys"}, {:vector, syms}}, {binds, ors} ->
          key_binds =
            Enum.map(syms, fn
              sym_form ->
                case peel_hint(sym_form) do
                  {:symbol, name} -> {:get, {:symbol, name}, String.to_atom(name)}
                  other -> raise "unsupported :keys binding: #{inspect(other)}"
                end
            end)

          {binds ++ key_binds, ors}

        {{:keyword, "strs"}, {:vector, syms}}, {binds, ors} ->
          str_binds =
            Enum.map(syms, fn
              sym_form ->
                case peel_hint(sym_form) do
                  {:symbol, name} -> {:get, {:symbol, name}, name}
                  other -> raise "unsupported :strs binding: #{inspect(other)}"
                end
            end)

          {binds ++ str_binds, ors}

        {{:keyword, "as"}, as_form}, {binds, ors} ->
          case peel_hint(as_form) do
            {:symbol, name} -> {binds ++ [{:as, name}], ors}
            other -> raise "unsupported :as binding: #{inspect(other)}"
          end

        # `{local :key}` / `{[a b] :pair}`: the binding form sits in
        # the map's key slot, the lookup key in its value slot. The
        # codebase's established `{:key local}` spelling (keyword in
        # the key slot) means the same thing, so both are accepted.
        {pattern, key_form}, {binds, ors} ->
          bind =
            case {pattern, key_form} do
              {{:keyword, k}, {:symbol, local}} ->
                {:get, {:symbol, local}, String.to_atom(k)}

              {pattern, key_form} ->
                key =
                  case quoted_symbol_key(key_form) do
                    {:ok, name} -> {:symbol, name}
                    :error -> plain_map_key(key_form)
                  end

                {:get, pattern, key}
            end

          {binds ++ [bind], ors}

        {other, _}, _ ->
          raise "unsupported map binding: #{inspect(other)}"
      end)

    # Compile the :or defaults in the entering scope (before any bind
    # in this map), as Clojure does.
    ors_asts = Map.new(ors, fn {k, default} -> {k, compile_elixir(default, env)} end)

    {steps, env} =
      Enum.reduce(binds, {[], env}, fn bind, {steps, acc_env} ->
        case bind do
          {:as, name} ->
            var = fresh_var(name)
            {steps ++ [{var, whole_ast}], put_local(acc_env, name, var)}

          {:get, {:symbol, name}, key} ->
            var = fresh_var(name)
            default = Map.get(ors_asts, name)

            get_ast =
              quote do
                BeamLisp.RT.get(unquote(whole_ast), unquote(key), unquote(default))
              end

            {steps ++ [{var, get_ast}], put_local(acc_env, name, var)}

          # A non-symbol pattern under a key destructures recursively,
          # so maps and vectors nest inside each other.
          {:get, pattern, key} ->
            get_ast =
              quote do
                BeamLisp.RT.get(unquote(whole_ast), unquote(key))
              end

            {sub_steps, nested_env} = destructure_steps(pattern, acc_env, get_ast)
            {steps ++ sub_steps, nested_env}
        end
      end)

    {steps, env}
  end

  defp destructure_steps(other, _env, _whole_ast) do
    raise "unsupported binding pattern: #{inspect(other)}"
  end

  # A quoted-symbol map key, `{local 'k}` / `{local (quote k)}`: the
  # reader emits the shorthand as the expanded list, so both forms reach
  # here as `{:list, [{:symbol, "quote"}, {:symbol, name}]}` — and because
  # it is a LIST it carries a reader position, so peel `{:meta, _, _}`
  # before matching (the wave-20 contract: positions ride on lists). The
  # runtime key is the tagged `{:symbol, name}` tuple that a quoted symbol
  # evaluates to — the same shape the reader's `datum/1` preserves.
  defp quoted_symbol_key({:meta, form, _m}), do: quoted_symbol_key(form)
  defp quoted_symbol_key({:list, [{:symbol, "quote"}, {:symbol, name}]}), do: {:ok, name}
  defp quoted_symbol_key(_), do: :error

  # Non-quoted map keys: a keyword and a string stay literal. A quoted
  # `'keys`/`'as`/`'or` is deliberately NOT a directive — the directive
  # clauses above match only the bare keyword, so a quoted symbol in the
  # key slot always means "look up by this symbol", never "switch mode".
  defp plain_map_key({:keyword, k}), do: String.to_atom(k)
  defp plain_map_key(k) when is_binary(k), do: k
  defp plain_map_key(other), do: raise("unsupported map key in binding: #{inspect(other)}")

  # `[a b & rest :as whole]` peels the trailing `:as name` off the
  # binding vector so split_variadic still sees `[a b & rest]`. `:as` is
  # positional at the END: anywhere else, or a missing name after it,
  # is a loud error rather than a silent mis-bind.
  defp peel_as_bind(elems) do
    case Enum.reverse(elems) do
      [name_form, {:keyword, "as"} | rest_rev] ->
        case peel_hint(name_form) do
          {:symbol, name} -> {Enum.reverse(rest_rev), name}
          other -> raise "\":as\" in a vector binding must name a symbol, got #{inspect(other)}"
        end

      [{:keyword, "as"} | _] ->
        raise "\":as\" in a vector binding must be followed by a name"

      _ ->
        if {:keyword, "as"} in elems do
          raise "\":as\" in a vector binding must be its last two elements ([... :as name])"
        else
          {elems, nil}
        end
    end
  end

  defp nest_steps(steps, body_ast) do
    Enum.reduce(Enum.reverse(steps), body_ast, fn {param, arg_ast}, inner ->
      fn_ast = {:fn, [], [{:->, [], [[param], inner]}]}
      {{:., [], [fn_ast]}, [], [arg_ast]}
    end)
  end

  # --- data ---

  # A quoted form becomes data: symbols stay tagged so tooling can
  # recognize them, keywords become atoms, everything else is itself.
  defp datum({:symbol, name}), do: {:symbol, name}
  defp datum({:keyword, name}), do: BeamLisp.AtomGuard.to_atom(name)
  # Source positions are a COMPILER channel, not data. A macro receives
  # its arguments as data and walks them with `first`/`rest`/`seq?` —
  # runtime fns that know lists, not `{:meta, form, m}` wrappers. Leaving
  # the wrapper on made `(-> 5 (+ 3) (* 2))` compile `(* 2)` as a
  # one-argument call, because `->`'s `rest` saw a wrapper where a list
  # was promised. Positions are read off the form BEFORE it becomes a
  # datum (see `compile/2`); past this boundary they are dropped.
  # Source positions are a COMPILER channel, not data; but AUTHOR metadata
  # (`^{:key …}`) IS data and must survive the macro-argument boundary, the
  # same as it survives `compile/2`. Split the two: positions are dropped
  # (a `{:meta, list, m}` wrapper would break `rest`-based macros like `->`,
  # the reason this clause existed), while author keys re-attach to the
  # datum'd VALUE. Only a vector carries them: it holds metadata in a struct
  # field, so `first`/`rest`/`seq`/`count` still work (BUG-009) — a list has
  # no such field, so list metadata stays dropped and `->` is unaffected.
  defp datum({:meta, form, m}) do
    {_pos, user} = Map.split(m, [:line, :col, :file])
    base = datum(form)

    case base do
      %BeamLisp.Vector{} when map_size(user) > 0 -> %BeamLisp.Vector{base | meta: user}
      _ -> base
    end
  end
  defp datum({:list, items}), do: Enum.map(items, &datum/1)
  defp datum({:vector, items}), do: BeamLisp.Vector.new(Enum.map(items, &datum/1))
  defp datum({:set, items}), do: BeamLisp.Set.new(Enum.map(items, &datum/1))
  defp datum({:map, kvs}), do: Map.new(kvs, fn {k, v} -> {datum(k), datum(v)} end)
  # A record literal inside `quote` becomes a tagged `{:record, name, map}`
  # datum: the type name plus its field map as data, never evaluated.
  defp datum({:record, name, kvs}), do: {:record, name, datum({:map, kvs})}
  defp datum(lit), do: lit

  @doc """
  Read ONE form of source as a runtime VALUE — the same conversion `quote`
  compiles to (`datum/1`), without compiling or evaluating anything.

  This is the only safe way model-written text crosses into the image
  (`spell.run`): the reader's atom guard bounds what can be interned, and no
  form is ever called. A malformed form raises `BeamLisp.Reader.SyntaxError`.
  """
  def read_data(source) when is_binary(source) do
    # An EAGER table check, not the reader's sampled one: the reader resets
    # its sampling counter per `read_string`, so a caller that reads many
    # small hostile sources — exactly the model-tool shape — would never
    # reach a sample. This entry point is that caller; one system_info pair
    # per read is nothing next to the network turn that produced the source.
    BeamLisp.AtomGuard.check!(source)
    source |> BeamLisp.Reader.read_one() |> datum()
  end

  @doc """
  Read EVERY top-level form of a source file as runtime data — the plural of
  `read_data/1`, for files we ourselves wrote (the persist journal). Same
  rule: never evaluated, atom-guarded.
  """
  def read_all_data(source) when is_binary(source) do
    BeamLisp.AtomGuard.check!(source)
    source |> BeamLisp.Reader.read_all() |> Enum.map(&datum/1)
  end

  # One protocol method implementation: `(m [args] body…)` compiles to
  # a method-name => fn-value map entry. The method form may carry a
  # reader position (it is a list); unwrap it so the shape matches.
  defp protocol_impl(form, env) do
    case unwrap_meta(form) do
      {:list, [{:symbol, m} | rest]} ->
        if rest == [], do: raise("defprotocol method #{m}: expected a body")
        {m, compile_fn(fn_clauses(rest, env), env)}

      other ->
        raise("expected (method-name [args]…) implementation, got #{inspect(other)}")
    end
  end

  # Group reify's alternating protocol-name / method-impl forms, the
  # same split `extend-protocol` and `record_protocol_extends` use.
  # Kept here, away from the compile_special clauses, so it cannot split
  # that contiguous chain (Elixir needs same-name/arity clauses adjacent).
  defp reify_protocol_groups(forms, env) do
    {groups, cur_proto, cur_methods} =
      Enum.reduce(forms, {[], nil, []}, fn f, {groups, proto, methods} ->
        case unwrap_meta(f) do
          {:list, _} = bare -> {groups, proto, methods ++ [bare]}
          proto_form -> {groups ++ [{proto, methods}], proto_form, []}
        end
      end)

    groups =
      for {proto, method_forms} <- groups ++ [{cur_proto, cur_methods}], proto != nil do
        {name_of(proto), method_forms}
      end

    if groups == [] do
      compile_error(env, "reify: expected at least one protocol with methods")
    end

    groups
  end

  # Deftype field access lowers to a lookup against the tagged tuple.
  defp compile_deftype_field(field, [obj], env) do
    [obj_ast] = compile_args([obj], env)

    quote do
      BeamLisp.Record.deftype_field(unquote(obj_ast), unquote(String.to_atom(field)))
    end
  end

  # Shared expansion for defrecord/deftype. `kind` picks the record
  # (struct) or deftype (tuple) representation and whether `map->Name` is
  # defined. `proto_forms` are the inline `(Proto (method …) …)` blocks.
  defp record_define_ast(env, name, fields, kind, proto_forms) do
    mod = Macro.var(:mod, __MODULE__)
    define_fn = if kind == :record, do: :define, else: :define_type
    map_ctor = if kind == :record, do: map_ctor_intern(env, name, mod), else: nil
    extend_asts = record_protocol_extends(proto_forms, mod, env)

    quote do
      unquote(mod) =
        BeamLisp.Record.unquote(define_fn)(unquote(env.ns), unquote(name), unquote(fields))

      # The type name itself is a var whose value is the module — that is
      # what `(extend-type Point …)`, `type_of`, and record literals resolve.
      BeamLisp.Env.intern(unquote(env.ns), unquote(name), unquote(mod))

      BeamLisp.Env.intern(
        unquote(env.ns),
        unquote("->" <> name),
        BeamLisp.Record.positional_ctor(unquote(mod))
      )

      unquote(map_ctor)
      unquote(block(extend_asts))
      unquote(mod)
    end
  end

  defp map_ctor_intern(env, name, mod) do
    quote do
      BeamLisp.Env.intern(
        unquote(env.ns),
        unquote("map->" <> name),
        BeamLisp.Record.map_ctor(unquote(mod))
      )
    end
  end

  # A record's inline protocol blocks: the flat form `(defrecord Name
  # [f…] Proto (m [args]…) … Proto2 (m2…) …)` alternates a protocol name
  # (a bare symbol) with its method impls (lists). Group them exactly as
  # `extend-protocol` does, then emit a `Multi.extend_type` call per
  # protocol keyed on the runtime `mod`. Method bodies go through
  # `protocol_impl/2` — the same fn `extend-type`/`extend-protocol` use —
  # so inline impls and separate `extend-type` impls are interchangeable.
  defp record_protocol_extends(proto_forms, mod, env) do
    {groups, cur_proto, cur_methods} =
      Enum.reduce(proto_forms, {[], nil, []}, fn pf, {groups, proto, methods} ->
        case unwrap_meta(pf) do
          {:list, _} = bare -> {groups, proto, methods ++ [bare]}
          proto_form -> {groups ++ [{proto, methods}], proto_form, []}
        end
      end)

    for {proto, method_forms} <- groups ++ [{cur_proto, cur_methods}], proto != nil do
      {pns, pname} = multi_var_target(env, name_of(proto))
      impls = {:%{}, [], Enum.map(method_forms, &protocol_impl(&1, env))}

      quote do
        BeamLisp.Multi.extend_type(unquote(pns), unquote(pname), unquote(mod), unquote(impls))
      end
    end
  end

  # The declared field names of a record/deftype, from the `[x y …]`
  # vector. Fields are symbols (metadata permitted, as in destructuring).
  defp record_fields(form) do
    case unwrap_meta(form) do
      {:vector, items} -> Enum.map(items, &record_field_name/1)
      other -> raise "defrecord/deftype: expected a field vector, got #{inspect(other)}"
    end
  end

  defp record_field_name(form), do: name_of(form)

  # Resolve a type argument to the tag `Multi.type_of/1` would produce
  # for values of that type: keywords are the builtin tags themselves,
  # an uppercase symbol names an Elixir struct module, a lowercase
  # symbol is a bare tag name. A record/deftype symbol resolves against
  # the current namespace first: `Point` refers to the struct module the
  # `defrecord`/`deftype` interned, so `(extend-type Point …)` keys the
  # same tag `type_of/1` yields for a record instance.
  defp type_tag(form, env) do
    case unwrap_meta(form) do
      {:keyword, name} ->
        String.to_atom(name)

      {:symbol, name} ->
        # `peek`: resolving a type-tag symbol at compile time must not materialize
        # a per-env value. A descriptor is not an atom module, so it falls through.
        case Env.peek(env.ns, name) do
          {:ok, mod} when is_atom(mod) ->
            if BeamLisp.Record.record_module?(mod) or BeamLisp.Record.deftype_module?(mod),
              do: mod,
              else: plain_type_tag(name)

          _ ->
            plain_type_tag(name)
        end

      other ->
        raise "expected a type tag (keyword) or struct module, got #{inspect(other)}"
    end
  end

  defp plain_type_tag(name) do
    if uppercase?(name), do: Module.concat([name]), else: String.to_atom(name)
  end

  # Resolve a var name (possibly `alias/name` or `ns/name`) to a
  # `{ns, name}` pair for defmethod / protocol targets.
  #
  # A bare name is not necessarily local. `(:require [p :refer :all])`
  # followed by `(extend-type T Shape …)` is the ordinary Clojure
  # spelling, and assuming `env.ns` there invented a second, empty
  # protocol under the extending namespace's name — so the extension
  # registered against a protocol nobody dispatches on, and the call
  # failed later with "no implementation", far from the cause. A refer
  # is checked only when the name is not defined locally, so a local
  # definition still shadows a referred one.
  defp multi_var_target(env, name) do
    case String.split(name, "/", parts: 2) do
      ["", _rest] ->
        {env.ns, name}

      [prefix, var] ->
        {Env.alias_target(env.ns, prefix) || core_alias(prefix), var}

      [plain] ->
        if Env.local_var?(env.ns, plain) do
          {env.ns, plain}
        else
          {Env.refer_source(env.ns, plain) || env.ns, plain}
        end
    end
  end

  # --- quoted builders ---

  defp remote_value_quoted(module, fun) do
    quote do
      BeamLisp.RT.remote_fun(unquote(module), unquote(fun))
    end
  end

  # Decide what a slash-named symbol refers to: an alias or explicit
  # namespace (a var), or an Elixir/Erlang module (a remote call).
  # Order: alias wins, then Elixir (uppercase), then an existing
  # namespace, then Erlang. An ns named like an Erlang module
  # shadows it — explicit user intent beats the heuristic.
  defp slash_target(env, name) do
    case String.split(name, "/", parts: 2) do
      # `/` (and `/x`) is a var name, not a qualified reference.
      ["" | _] ->
        {:var, env.ns, name}

      [prefix, fun] ->
        prefix = core_alias(prefix)

        cond do
          target = Env.alias_target(env.ns, prefix) -> {:var, target, fun}
          uppercase?(prefix) -> gate_remote!(env, Module.concat([prefix]), String.to_atom(fun))
          Env.ns_exists?(prefix) -> {:var, prefix, fun}
          true -> gate_remote!(env, String.to_atom(prefix), String.to_atom(fun))
        end
    end
  end

  # The capability gate at COMPILE time: a qualified name resolving to a
  # host module (Elixir `Foo/bar`, Erlang `:erlang/atom_to_binary`, …) is
  # a remote call into the host — allowed only when the current env's caps
  # grant that module. Rejecting HERE means denied code never exists as
  # bytecode at all: the strongest form of the gate, and zero runtime cost
  # for static calls. Dynamic paths are gated in `RT.remote_fun/2` and
  # `RT.invoke/2`.
  defp gate_remote!(env, module, fun) do
    if Env.caps_allowed?(module, Env.op_of(module, fun)) do
      {:remote, module, fun}
    else
      compile_error(
        env,
        "module #{inspect(module)} is not granted in this environment " <>
          "(env #{inspect(Process.get(:bl_env, :global))} holds caps: #{caps_description()})"
      )
    end
  end

  defp caps_description do
    case Env.caps() do
      :all -> "all"
      set -> set |> Enum.map(&inspect/1) |> Enum.sort() |> Enum.join(", ")
    end
  end

  defp fetch_quoted(ns, name) do
    quote do
      BeamLisp.Env.fetch!(unquote(ns), unquote(name))
    end
  end

  # A qualified reference to a var in another namespace must not reach a
  # private var, matching Clojure's compile-time "var: #'ns/name is not
  # public". This is checked in the *resolving* namespace (env.ns) at
  # compile time; same-ns qualified access stays legal. It precedes the
  # direct-call link in the call path so a private linked fn cannot slip
  # through the remote-call shortcut either.
  defp private_fetch_quoted(env, target_ns, var) do
    if target_ns != env.ns and private_var?(target_ns, var) do
      compile_error(env, "var #{target_ns}/#{var} is not public")
    else
      fetch_quoted(target_ns, var)
    end
  end

  # Refuse the same privacy violation when the call path would otherwise
  # take the linked direct-call shortcut (link metadata bypasses
  # fetch_quoted). Harmless no-op for unqualified or remote targets.
  defp reject_private_link(env, name) do
    if String.contains?(name, "/") do
      case slash_target(env, name) do
        {:var, ns, var} ->
          if ns != env.ns and private_var?(ns, var) do
            compile_error(env, "var #{ns}/#{var} is not public")
          end

        _ ->
          :ok
      end
    end
  end

  defp private_var?(ns, name) do
    match?({:ok, %{private: true}}, Env.meta(ns, name))
  end

  defp invoke_quoted(f_ast, arg_asts) do
    quote do
      BeamLisp.RT.invoke(unquote(f_ast), unquote(arg_asts))
    end
  end

  defp block([single]), do: single
  defp block(forms), do: {:__block__, [], forms}

  # Compile a body: every form but the last leaves tail position.
  defp block_forms([], _env), do: nil

  defp block_forms(forms, env) do
    {inits, [last]} = Enum.split(forms, -1)
    block(Enum.map(inits, &compile_elixir(&1, notail(env))) ++ [compile_elixir(last, env)])
  end

  # --- compile-time env ---

  defp notail(env), do: %{env | tail: false}

  # Thread a form's position (from its FormMeta wrapper) into the compile
  # env so the emitters below can stamp `line:` onto the AST. Positions are
  # best-effort: a form with no metadata keeps the env's current position.
  # is_map-ok: `m` is the reader's own position map (:line/:col/:file), an
  # internal Elixir map -- not user data.
  defp pos_env(env, m) when is_map(m) do
    env
    |> maybe_put(:line, m[:line], &(is_integer(&1) and &1 > 0))
    |> maybe_put(:file, m[:file], &is_binary/1)
  end

  defp pos_env(env, _m), do: env

  defp maybe_put(env, _key, nil, _ok?), do: env
  defp maybe_put(env, key, value, ok?) do
    if ok?.(value), do: Map.put(env, key, value), else: env
  end

  # The `[file:, line:]` location for a generated module, from the form's
  # own position metadata (only lists carry it) then the compile env,
  # else nil — the caller falls back to `Macro.Env.location(__ENV__)`.
  defp module_location(form, env) do
    case form do
      {:meta, _inner, m} ->
        pos_loc(m[:file] || env[:file], pos_line(m[:line]) || pos_line(env[:line]))

      _ ->
        pos_loc(env[:file], pos_line(env[:line]))
    end
  end

  defp pos_loc(file, line) when is_binary(file), do: [file: file, line: line || 1]
  defp pos_loc(_file, _line), do: nil

  defp pos_line(line) when is_integer(line) and line > 0, do: line
  defp pos_line(_), do: nil

  # Stamp the form's line onto the outermost AST node. A literal (a bare
  # number/string/atom) carries no call site, so it is left alone; a call
  # form's outermost node is the call itself, which is what the BEAM line
  # table records.
  defp stamp_line(ast, env) do
    case env[:line] do
      line when is_integer(line) and line > 0 -> stamp_node(ast, line)
      _ -> ast
    end
  end

  defp stamp_node({node, meta, args}, line) when is_list(meta) do
    {node, Keyword.put(meta, :line, line), args}
  end

  defp stamp_node(ast, _line), do: ast

  # Drop one FormMeta wrapper so a shape clause matches the bare form; a
  # form with no wrapper passes through. Shape tokens (names, params,
  # patterns) are unwrapped before matching, while the forms a helper
  # recurses into stay wrapped so compile/2 re-captures their positions.
  defp unwrap_meta({:meta, form, _m}), do: form
  defp unwrap_meta(other), do: other

  # `^Tag x` lands as `{:meta, {:symbol, x}, %{tag: ...}}`, and `^:a ^Tag x`
  # merges into one wrapper. A binding's type hint is a no-op optimization
  # hint in Clojure, so peel it off a direct binding target before routing
  # to the symbol/destructure shapes. Recursive so stacked wrappers collapse;
  # `unwrap_meta/1` drops just one layer.
  defp peel_hint({:meta, form, _m}), do: peel_hint(form)
  defp peel_hint(form), do: form

  # The name of a `{:symbol, name}` token, possibly position-wrapped.
  defp name_of(form), do: name_of_unwrapped(unwrap_meta(form))
  defp name_of_unwrapped({:symbol, name}), do: name

  # A literal string in a form (reader-produced literals are bare terms).
  defp string_of(form) do
    case unwrap_meta(form) do
      s when is_binary(s) -> s
      other -> raise "expected a string literal, got #{inspect(other)}"
    end
  end

  defp literal_int(form) do
    case unwrap_meta(form) do
      n when is_integer(n) -> n
      other -> raise "expected an integer literal, got #{inspect(other)}"
    end
  end

  # ── guards ─────────────────────────────────────────────────────────
  #
  # A pattern says what SHAPE a message has; a guard says what must be
  # TRUE of the values it bound. The BEAM tests both before committing to
  # a clause, which is what makes `(handle-call [:take n] :when (> n 0) …)`
  # different from an `if` in the body: a message that fails the guard was
  # never received by that clause, so a later clause — or the mailbox —
  # still gets it.
  #
  # Guards are a RESTRICTED dialect on every BEAM language, not a subset
  # anyone chose here: the VM evaluates them without calling user code, so
  # only BIFs it can prove side-effect-free are allowed. A guard that
  # reaches outside that set is refused BY NAME, at compile time, with the
  # allowed set named — the alternative is `illegal guard expression` from
  # deep inside Elixir, pointing at generated AST rather than at the
  # source line the user wrote.

  # beam-lisp name -> the guard-safe test it emits. The type predicates
  # are the language's own spellings (`int?`, `keyword?`, `vector?`),
  # mapped onto the BIF or the `defguard` that means the same thing, so a
  # guard reads like the rest of the language rather than like Erlang.
  # Two kinds of entry, tagged so they cannot be confused: `{:bif, mod,
  # fun, arity}` emits a direct BIF call, `{:expand, tag, arity}` expands
  # through guard_special/2 because no single BIF means the same thing.
  # (Discriminating on the module being an atom does NOT work — `:guard_nil`
  # is an atom too, and Elixir's type checker caught exactly that.)
  @guard_bifs %{
    "=" => {:bif, :erlang, :==, 2},
    "==" => {:bif, :erlang, :==, 2},
    "not=" => {:bif, :erlang, :"/=", 2},
    "<" => {:bif, :erlang, :<, 2},
    ">" => {:bif, :erlang, :>, 2},
    "<=" => {:bif, :erlang, :"=<", 2},
    ">=" => {:bif, :erlang, :>=, 2},
    "+" => {:bif, :erlang, :+, 2},
    "-" => {:bif, :erlang, :-, 2},
    "*" => {:bif, :erlang, :*, 2},
    "rem" => {:bif, :erlang, :rem, 2},
    "tuple-size" => {:bif, :erlang, :tuple_size, 1},
    "int?" => {:bif, :erlang, :is_integer, 1},
    "float?" => {:bif, :erlang, :is_float, 1},
    "number?" => {:bif, :erlang, :is_number, 1},
    "string?" => {:bif, :erlang, :is_binary, 1},
    "fn?" => {:expand, :guard_fn, 1},
    "tuple?" => {:bif, :erlang, :is_tuple, 1},
    "list?" => {:bif, :erlang, :is_list, 1},
    "pid?" => {:bif, :erlang, :is_pid, 1},
    "ref?" => {:bif, :erlang, :is_reference, 1},
    "port?" => {:bif, :erlang, :is_port, 1},
    "nil?" => {:expand, :guard_nil, 1},
    "some?" => {:expand, :guard_some, 1},
    "true?" => {:expand, :guard_true, 1},
    "keyword?" => {:expand, :guard_keyword, 1},
    "map?" => {:expand, :guard_map, 1},
    "vector?" => {:expand, :guard_vector, 1},
    "zero?" => {:expand, :guard_zero, 1},
    "pos?" => {:expand, :guard_pos, 1},
    "neg?" => {:expand, :guard_neg, 1}
  }

  # `(when guard)` peeled off a clause: `{guard_form | nil, rest}`.
  # `:when` is a KEYWORD in the clause, not a symbol, so it can never
  # collide with a user's var and it reads the way Elixir's `when` does.
  defp split_guard([{:keyword, "when"}, guard | rest]), do: {guard, rest}

  defp split_guard([form | rest] = all) do
    case unwrap_meta(form) do
      {:keyword, "when"} ->
        case rest do
          [guard | tail] -> {guard, tail}
          [] -> {:missing, all}
        end

      _ ->
        {nil, all}
    end
  end

  defp split_guard([]), do: {nil, []}

  # Compile a guard expression in the restricted dialect. `nil` in means
  # no guard, so callers can pass the result straight through.
  defp compile_guard(nil, _env), do: nil
  defp compile_guard(form, env), do: compile_guard_form(unwrap_meta(form), env)

  # `and`/`or`/`not` are guard-legal as the short-circuit operators
  # (`andalso`/`orelse`), which is what beam-lisp's macros mean anyway.
  defp compile_guard_form({:list, [{:symbol, "and"} | args]}, env),
    do: guard_fold(:andalso, args, env, true)

  defp compile_guard_form({:list, [{:symbol, "or"} | args]}, env),
    do: guard_fold(:orelse, args, env, false)

  defp compile_guard_form({:list, [{:symbol, "not"}, arg]}, env),
    do: {{:., [], [:erlang, :not]}, [], [compile_guard(arg, env)]}

  defp compile_guard_form({:list, [head | args]} = form, env) do
    name = name_of_guard_head(head, env, form)

    case Map.fetch(@guard_bifs, name) do
      {:ok, {:bif, mod, fun, arity}} ->
        check_guard_arity(name, arity, args, env, form)
        {{:., [], [mod, fun]}, [], Enum.map(args, &compile_guard(&1, env))}

      {:ok, {:expand, tag, arity}} ->
        check_guard_arity(name, arity, args, env, form)
        guard_special(tag, Enum.map(args, &compile_guard(&1, env)))

      :error ->
        compile_error(
          env,
          "`#{name}` is not allowed in a guard. The BEAM evaluates guards without " <>
            "calling user code, so only side-effect-free tests are permitted: " <>
            "#{guard_vocabulary()}. Move the rest into the clause body.",
          form
        )
    end
  end

  # A bare symbol in a guard is a variable the pattern bound (or a local);
  # anything else has no meaning there. `local?` is the check because a
  # guard can only see what the clause head established.
  defp compile_guard_form({:symbol, name} = form, env) do
    if local?(env, name) do
      local(env, name)
    else
      compile_error(
        env,
        "`#{name}` is not bound by this clause's pattern, so it cannot appear in its " <>
          "guard — a guard sees only the variables the head binds.",
        form
      )
    end
  end

  defp compile_guard_form({:keyword, name}, _env), do: BeamLisp.AtomGuard.to_atom(name)

  defp compile_guard_form(lit, _env)
       when is_number(lit) or is_binary(lit) or is_boolean(lit) or is_nil(lit),
       do: lit

  defp compile_guard_form(other, env),
    do:
      compile_error(
        env,
        "a guard is a test over the variables the pattern bound, built from " <>
          "#{guard_vocabulary()} — got #{inspect(other)}.",
        other
      )

  defp name_of_guard_head(head, env, form) do
    case unwrap_meta(head) do
      {:symbol, name} ->
        name

      other ->
        compile_error(
          env,
          "a guard call needs a named test in head position, got #{inspect(other)}.",
          form
        )
    end
  end

  defp check_guard_arity(name, arity, args, env, form) do
    unless length(args) == arity do
      compile_error(
        env,
        "`#{name}` takes #{arity} argument(s) in a guard, got #{length(args)}.",
        form
      )
    end
  end

  # Variadic `and`/`or` fold into nested short-circuit pairs; the empty
  # case is the identity, matching the macros in core.bl.
  defp guard_fold(_op, [], _env, identity), do: identity
  defp guard_fold(_op, [one], env, _identity), do: compile_guard(one, env)

  defp guard_fold(op, [h | t], env, identity),
    do: {{:., [], [:erlang, op]}, [], [compile_guard(h, env), guard_fold(op, t, env, identity)]}

  # The predicates with no single BIF behind them. Each expands to the
  # guard an author would hand-write, so the emitted guard is exactly as
  # cheap as the hand-written one — `defguard`'s whole point.
  defp guard_special(:guard_nil, [x]), do: {{:., [], [:erlang, :"=:="]}, [], [x, nil]}
  defp guard_special(:guard_some, [x]), do: {{:., [], [:erlang, :"=/="]}, [], [x, nil]}
  defp guard_special(:guard_true, [x]), do: {{:., [], [:erlang, :"=:="]}, [], [x, true]}

  # `fn?` is TRUE for a tagged multi-arity fn and a remote handle, not just
  # a bare BEAM function — `RT.fn?/1` says so, and a guard that answered
  # differently would make `(fn? f)` and `:when (fn? f)` disagree about the
  # same value. A predicate whose guard form means something narrower than
  # its function form is a trap, not an optimization.
  defp guard_special(:guard_fn, [x]) do
    quote do
      :erlang.is_function(unquote(x)) or
        (:erlang.is_tuple(unquote(x)) and :erlang.tuple_size(unquote(x)) == 3 and
           :erlang.element(1, unquote(x)) in [:"$blfn", :"$remote"])
    end
  end

  # A keyword IS an atom here, minus the three atoms that are not
  # keywords in this language — the same rule `RT.keyword?/1` applies.
  defp guard_special(:guard_keyword, [x]) do
    quote do
      :erlang.is_atom(unquote(x)) and unquote(x) !== true and unquote(x) !== false and
        unquote(x) !== nil
    end
  end

  # `map?` must mean here exactly what `RT.map?/1` means, which is NOT
  # "a plain map": a RECORD is a user-facing map in this language (`count`,
  # `seq`, `get`, `assoc` all treat it as one), and a sorted map is a map
  # too. Only the non-map structs — vectors, sets, lazy seqs, refs — are
  # excluded.
  #
  # An earlier version of this guard excluded EVERY struct. It was the
  # `is_bl_map/1` invariant misapplied: that guard exists for RT's internal
  # clause dispatch, where records are routed by a separate earlier clause.
  # Copying it here dropped the records that clause would have caught, so
  # `(map? rec)` was true while `:when (map? rec)` fell through.
  #
  # Records cannot be recognised in a guard by name (the registry is a
  # runtime lookup), so the test is structural and matches RT's clause
  # order: a plain map, a SortedMap, or a struct that is NOT one of the
  # known non-map struct kinds.
  # is_map-ok (below): emitted AST for a USER module, where is_bl_map/1 is
  # unavailable — and this is deliberately the "any map, then discriminate"
  # case, since records and sorted maps must be ACCEPTED. The struct kinds
  # to exclude are listed inline right after.
  defp guard_special(:guard_map, [x]) do
    quote do
      # is_map-ok: any map, discriminated by the struct list below.
      :erlang.is_map(unquote(x)) and
        (not :erlang.is_map_key(:__struct__, unquote(x)) or
           not (:erlang.map_get(:__struct__, unquote(x)) in [
                  BeamLisp.Vector,
                  BeamLisp.Set,
                  BeamLisp.LazySeq,
                  BeamLisp.Sorted.SortedSet,
                  BeamLisp.Atom,
                  BeamLisp.Volatile,
                  BeamLisp.Promise,
                  BeamLisp.Future,
                  BeamLisp.Reduced
                ]))
    end
  end

  # The OPPOSITE case to `map?`: this guard WANTS a struct, and one
  # specific struct at that (`BeamLisp.Vector`), so `is_bl_map/1` — which
  # exists to EXCLUDE structs — would be exactly wrong here.
  defp guard_special(:guard_vector, [x]) do
    quote do
      # is_map-ok: a struct test, not a map test — the is_map is the BEAM's
      # precondition for reading :__struct__, and the very next term
      # requires that key to be present.
      :erlang.is_map(unquote(x)) and :erlang.is_map_key(:__struct__, unquote(x)) and
        :erlang.map_get(:__struct__, unquote(x)) === BeamLisp.Vector
    end
  end

  # `zero?`/`pos?`/`neg?` are BARE comparisons, exactly as `RT.zero?/1` and
  # friends are (`def pos?(x), do: x > 0`). On the BEAM `>` is a total order
  # over every term, so `(pos? :a)` is TRUE — surprising, but it is the
  # language's existing answer, and a guard that said otherwise would make
  # `(pos? x)` and `:when (pos? x)` disagree.
  #
  # An earlier version added an `is_number` conjunct here "so a guard never
  # raises". It cannot raise either way (comparison is total), so the
  # conjunct bought nothing and cost agreement with the function of the same
  # name. Where a numeric test is what is meant, `(and (number? x) (pos? x))`
  # says so — and says it identically in a guard and in a body.
  defp guard_special(:guard_zero, [x]), do: {{:., [], [:erlang, :==]}, [], [x, 0]}
  defp guard_special(:guard_pos, [x]), do: {{:., [], [:erlang, :>]}, [], [x, 0]}
  defp guard_special(:guard_neg, [x]), do: {{:., [], [:erlang, :<]}, [], [x, 0]}

  defp guard_vocabulary do
    (Map.keys(@guard_bifs) ++ ["and", "or", "not"])
    |> Enum.sort()
    |> Enum.map_join(", ", &"`#{&1}`")
  end

  # Raise a compile error carrying the current position and offending form.
  defp compile_error(env, message, form \\ nil) do
    raise BeamLisp.CompileError,
      message: message,
      file: env[:file],
      line: env[:line],
      form: form
  end

  defp local?(env, name), do: Map.has_key?(env.locals, name)
  defp local(env, name), do: Map.fetch!(env.locals, name)
  defp put_local(env, name, var), do: %{env | locals: Map.put(env.locals, name, var)}

  defp fresh_var(name) do
    clean = String.replace(name, ~r/[^a-zA-Z0-9_]/, "_")
    Macro.var(String.to_atom("#{clean}_#{System.unique_integer([:positive])}"), __MODULE__)
  end

  defp uppercase?(<<c, _::binary>>), do: c in ?A..?Z
  defp uppercase?(_), do: false
end
