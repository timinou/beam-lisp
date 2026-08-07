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

  alias BeamLisp.Env
  alias BeamLisp.Reader

  @special_forms ~w(ns def fn defn defmacro defmulti defmethod defprotocol extend-type extend-protocol let loop recur if do quote syntax-quote receive throw try loop* let* fn* defserver)

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
    ast = compile(form, env)
    mod = Module.concat(BeamLisp.Eval, "M#{System.unique_integer([:positive])}")

    Module.create(
      mod,
      quote do
        # Generated eval modules are throwaway codegen; signature
        # inference would type-check their try/catch AST, so it is
        # disabled for the module regardless of the session option.
        @compile no_type_check: true
        def run, do: unquote(ast)
      end,
      # Claim the form's own `.bl` file (and line) so the module's line
      # table points at the user's source, not beam-lisp's compiler. A
      # macro-built form with no position falls back to the old
      # behaviour.
      module_location(form, env) || Macro.Env.location(__ENV__)
    )

    mod.run()
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
    {inner, env} =
      case form do
        {:meta, inner, m} -> {inner, pos_env(env, m)}
        _ -> {form, env}
      end

    inner
    |> do_compile(env)
    |> stamp_line(env)
  end

  defp do_compile(form, _env)
      when is_number(form) or is_binary(form) or is_boolean(form) or is_nil(form),
      do: form

  defp do_compile({:keyword, name}, _env), do: String.to_atom(name)

  defp do_compile({:vector, items}, env) do
    tuple_ast = {:{}, [], Enum.map(items, &compile(&1, notail(env)))}
    {:%, [], [{:__aliases__, [], [:BeamLisp, :Vector]}, {:%{}, [], [items: tuple_ast]}]}
  end

  defp do_compile({:map, kvs}, env) do
    {:%{}, [], Enum.map(kvs, fn {k, v} -> {compile(k, notail(env)), compile(v, notail(env))} end)}
  end

  defp do_compile({:set, items}, env) do
    members = Enum.map(items, &compile(&1, notail(env)))

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
          {:var, ns, var} -> fetch_quoted(ns, var)
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
    arg_asts = Enum.map(args, &compile(&1, notail(env)))

    quote do
      BeamLisp.RT.invoke(unquote(String.to_atom(kw)), unquote(arg_asts))
    end
  end

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
            compile(expand_macro(macro_fn, {:list, [{:symbol, name} | args]}, args, env), env)

          :error ->
            arg_asts = compile_args(args, env)

            linked =
              case Env.link(env.ns, core_qualified(name)) do
                {:ok, info} -> linked_call(info, arg_asts)
                :error -> nil
              end

            cond do
              linked ->
                linked

              String.contains?(name, "/") ->
                case slash_target(env, name) do
                  {:var, ns, var} ->
                    invoke_quoted(fetch_quoted(ns, var), arg_asts)

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
    invoke_quoted(compile(head, arg_env), Enum.map(args, &compile(&1, arg_env)))
  end

  defp compile_args(args, env) do
    arg_env = notail(env)
    Enum.map(args, &compile(&1, arg_env))
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
  defp compile_special("ns", [name_form | clauses], _env) do
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
          for sym <- refer_syms do
            quote do: BeamLisp.Env.add_refer(unquote(name), unquote(sym), unquote(target))
          end

        {[load | loads], alias_op ++ aliases, refer_ops ++ refers}
      end)

    quote do
      ns = unquote(name)
      BeamLisp.Env.in_ns(ns)
      unquote(Enum.reverse(loads))
      unquote(block(aliases))
      unquote(block(refers))
      String.to_atom(ns)
    end
  end

  defp compile_special("def", [name_form, init], env),
    do: compile_def(name_of(name_form), compile(init, notail(env)), env)

  defp compile_special("def", [name_form, doc, init], env) when is_binary(doc),
    do: compile_def(name_of(name_form), compile(init, notail(env)), env, doc)

  defp compile_special("fn", args, env) do
    case args do
      # A named fn binds its own name to the fn value inside its body, so
      # `(fn step [n] (step (- n 1)))` can recurse (doseq's builder does).
      [first | clauses] ->
        case unwrap_meta(first) do
          {:symbol, name} -> compile_fn(fn_clauses(clauses), env, name: name)
          _ -> compile_fn(fn_clauses(args), env)
        end

      clauses ->
        compile_fn(fn_clauses(clauses), env)
    end
  end

  defp compile_special("defn", [name_form | rest], env) do
    name = name_of(name_form)
    {doc, rest} = split_docstring(rest)

    cond do
      rest == [] ->
        compile_error(env, "defn #{name}: expected at least one parameter vector")

      match?([h | _] when is_binary(h), rest) ->
        compile_error(
          env,
          "defn #{name}: expected a parameter vector, got a string literal (a docstring must be followed by clauses)"
        )

      true ->
        compile_defn(name, fn_clauses(rest), env, doc)
    end
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

      true ->
        compile_def(
          name,
          {:{}, [], [:"$macro", compile_fn(macro_clauses(fn_clauses(rest)), env, nil_rest: true)]},
          env,
          doc
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
    dispatch_ast = compile(dispatch, notail(env))
    quote do: BeamLisp.Multi.define_multi(unquote(env.ns), unquote(name), unquote(dispatch_ast))
  end

  defp compile_special("defmulti", [name_form, doc, dispatch], env) when is_binary(doc) do
    name = name_of(name_form)
    dispatch_ast = compile(dispatch, notail(env))

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
    dispatch_ast = compile(dispatch_val, notail(env))
    method_ast = compile_fn(fn_clauses(rest), env)

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
  defp compile_special("defprotocol", [name_form | method_forms], env) do
    name = name_of(name_form)

    method_names =
      Enum.map(method_forms, fn mf ->
        case unwrap_meta(mf) do
          {:list, [head | _]} -> name_of(head)
          other -> raise "defprotocol #{name}: expected (method-name [args]…), got #{inspect(other)}"
        end
      end)

    quote do
      BeamLisp.Multi.define_protocol(unquote(env.ns), unquote(name), unquote(method_names))
    end
  end

  defp compile_special("defprotocol", args, env),
    do: compile_error(env, "defprotocol: expected (defprotocol Name (method [args]…)), got #{inspect(args)}")

  defp compile_special("extend-type", [type_form, protocol_form | method_forms], env) do
    protocol = name_of(protocol_form)
    {pns, pname} = multi_var_target(env, protocol)
    tag = type_tag(type_form)
    impls = {:%{}, [], Enum.map(method_forms, &protocol_impl(&1, env))}

    quote do
      BeamLisp.Multi.extend_type(unquote(pns), unquote(pname), unquote(tag), unquote(impls))
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
        tag = type_tag(type_form)
        impls = {:%{}, [], Enum.map(method_forms, &protocol_impl(&1, env))}

        quote do
          BeamLisp.Multi.extend_type(unquote(pns), unquote(pname), unquote(tag), unquote(impls))
        end
      end

    block(calls)
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

        arg_asts = Enum.map(args, &compile(&1, notail(env)))

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
      BeamLisp.ExInfo.raise_payload(unquote(compile(x, notail(env))))
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
  defp compile_special("receive", clauses, env) do
    {after_clauses, normal} =
      Enum.split_with(clauses, &match?({:list, [{:symbol, "after"} | _]}, unwrap_meta(&1)))

    pairs = Enum.chunk_every(normal, 2)

    unless Enum.all?(pairs, &(length(&1) == 2)) do
      compile_error(env, "receive clauses must be pattern/body pairs")
    end

    do_clauses =
      Enum.flat_map(pairs, fn [pattern_form, body] ->
        {pat_asts, pat_env} = compile_pattern(pattern_form, env)
        body_ast = compile(body, pat_env)
        Enum.map(pat_asts, &{:->, [], [[&1], body_ast]})
      end)

    block =
      case after_clauses do
        [] ->
          [do: do_clauses]

        [after_form] ->
          {:list, [{:symbol, "after"}, timeout, body]} = unwrap_meta(after_form)
          after_clause = {:->, [], [[compile(timeout, notail(env))], compile(body, env)]}
          [do: do_clauses, after: [after_clause]]

        _ ->
          compile_error(env, "receive takes at most one (after ms body) clause")
      end

    {:receive, [], [block]}
  end

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

  # A receive pattern, compiled with its bindings added to the env.
  # Returns one or more pattern ASTs (a vector pattern matches both
  # Erlang tuples and beam-lisp vectors — one clause each).
  # A receive pattern may carry a reader position wrapper; unwrap it for
  # the shape clauses below while nested items stay wrapped so their own
  # positions re-capture when compiled.
  defp compile_pattern(form, env), do: compile_pattern_bare(unwrap_meta(form), env)

  defp compile_pattern_bare({:symbol, "_"}, env), do: {[{:_, [], __MODULE__}], env}

  defp compile_pattern_bare({:symbol, name}, env) do
    var = fresh_var(name)
    {[var], put_local(env, name, var)}
  end

  defp compile_pattern_bare({:keyword, name}, env), do: {[String.to_atom(name)], env}

  defp compile_pattern_bare({:vector, items}, env) do
    {pats, env} =
      Enum.map_reduce(items, env, fn item, acc_env ->
        {[pat], acc_env} = compile_pattern(item, acc_env)
        {pat, acc_env}
      end)

    tuple_pat = {:{}, [], pats}

    vector_pat =
      {:%, [],
       [{:__aliases__, [], [:BeamLisp, :Vector]}, {:%{}, [], [items: tuple_pat]}]}

    {[tuple_pat, vector_pat], env}
  end

  defp compile_pattern_bare({:map, kvs}, env) do
    {pairs, env} =
      Enum.map_reduce(kvs, env, fn {k, v}, acc_env ->
        key =
          case unwrap_meta(k) do
            {:keyword, name} -> String.to_atom(name)
            lit when is_number(lit) or is_binary(lit) -> lit
            other -> raise "unsupported map pattern key: #{inspect(other)}"
          end

        {[pat], acc_env} = compile_pattern(v, acc_env)
        {{key, pat}, acc_env}
      end)

    {[{:%{}, [], pairs}], env}
  end

  defp compile_pattern_bare({:list, [{:symbol, "quote"}, form]}, env) do
    {[Macro.escape(datum(form))], env}
  end

  defp compile_pattern_bare(lit, env)
       when is_number(lit) or is_binary(lit) or is_boolean(lit) or is_nil(lit),
       do: {[lit], env}

  defp compile_pattern_bare(other, _env),
    do: raise("unsupported receive pattern: #{inspect(other)}")

  # A defn links: its clauses become named defs in the namespace
  # module (variadic under a mangled name, rest as the last param),
  # the var's value is a capture, and later call sites compile to
  # direct remote calls. See BeamLisp.Link.
  defp compile_defn(name, clauses, env, doc) do
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

    entries =
      Enum.map(clauses, fn {params, body} ->
        {_fixed, rest} = split_variadic(params)

        {kind, fname} =
          case rest do
            nil -> {:fixed, String.to_atom(name)}
            _ -> {:variadic, String.to_atom(name <> "__bl_v")}
          end

        {head_vars, body_ast, fixed_count, _v?} =
          compile_clause(env, params, body, %{self_call: {mod, fname}})

        def_ast = {:def, def_line, [{fname, [], head_vars}, [do: body_ast]]}
        {kind, fixed_count, fname, def_ast}
      end)

    defvar_ast =
      quote do
        BeamLisp.Link.defvar(
          unquote(env.ns),
          unquote(name),
          unquote(Macro.escape(entries)),
          unquote(location)
        )
      end

    if doc do
      # defn returns the interned value (Clojure's def returns the var
      # root); the meta write is a side effect after it.
      quote do
        value = unquote(defvar_ast)
        BeamLisp.Env.put_meta(unquote(env.ns), unquote(name), %{doc: unquote(doc)})
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
  defp server_clause_defs({:list, [_head | rest]}, fname, :pattern, env, def_line) do
    [pat_form, params_form | body] = rest
    {params, body} = server_params(params_form, body)
    {pat_asts, msg_env} = compile_pattern(pat_form, env)
    {head_vars, preludes, clause_env} = bind_params(msg_env, params)
    body_ast = compile_server_body(preludes ++ body, clause_env)
    Enum.map(pat_asts, &{:def, def_line, [{fname, [], [&1 | head_vars]}, [do: body_ast]]})
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

  defp server_defaults(:handle_info),
    do: [default_def(:handle_info, [:msg, :state], stuple([:noreply, {:var, :state}]))]

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
        {:vector, syms}, {as_alias, {:expecting, "refer"}} ->
          {as_alias, Enum.map(syms, fn {:symbol, s} -> s end)}
        other, _acc -> raise "invalid :require spec for #{target}: #{inspect(other)}"
      end)

    {target, as_alias, refer_syms}
  end

  defp parse_require_spec(other), do: raise("invalid :require spec: #{inspect(other)}")

  # --- macros ---

  # Macros resolve at compile time against the live registry, so a
  # defmacro must precede its callers in the same session.
  defp macro_for(ns, name) do
    case Env.fetch(ns, core_qualified(name)) do
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

  defp data_to_form(%BeamLisp.Vector{} = v),
    do: {:vector, Enum.map(BeamLisp.Vector.to_list(v), &data_to_form/1)}

  defp data_to_form(%BeamLisp.Set{} = s),
    do: {:set, Enum.map(BeamLisp.Set.to_list(s), &data_to_form/1)}

  defp data_to_form(items) when is_list(items),
    do: {:list, Enum.map(items, &data_to_form/1)}

  defp data_to_form(m) when is_map(m),
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
    do: {compile(x, notail(env)), g}

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

  defp synq_data({:symbol, name}, _env, g) do
    {resolved, g2} = resolve_gensym(name, g)
    {Macro.escape({:symbol, resolved}), g2}
  end

  defp synq_data({:keyword, name}, _env, g), do: {String.to_atom(name), g}
  defp synq_data(lit, _env, g), do: {lit, g}

  defp synq_list(items, env, g) do
    Enum.reduce(Enum.reverse(items), {[], g}, fn item, {acc, gacc} ->
      case unwrap_meta(item) do
        # `~@` splices any seqable, not just a list — jank's own macros
        # splice binding *vectors*, and `++` demands a list.
        {:list, [{:symbol, "unquote-splicing"}, x]} ->
          {quote(do: BeamLisp.RT.splice(unquote(compile(x, notail(env))), unquote(acc))), gacc}

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

  defp compile_def(name, init_ast, env, doc \\ nil) do
    intern_ast =
      quote do
        BeamLisp.Env.intern(unquote(env.ns), unquote(name), unquote(init_ast))
      end

    if doc do
      # def returns the interned value; the meta write is a side effect.
      quote do
        value = unquote(intern_ast)
        BeamLisp.Env.put_meta(unquote(env.ns), unquote(name), %{doc: unquote(doc)})
        value
      end
    else
      intern_ast
    end
  end

  defp compile_if(test, then, else_, env) do
    {:if, [],
     [compile(test, notail(env)), [do: compile(then, env), else: compile(else_, env)]]}
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
      init_ast = compile(init, acc_env)

      case pattern_form do
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
      init_ast = compile(init, acc_env)

      case pattern_form do
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
  # normalize to a list of `{params, body}` clauses; the same
  # normalization covers single- and multi-arity `defn`.
  defp fn_clauses([{:vector, params} | body]), do: [{params, body}]

  defp fn_clauses(clauses) do
    Enum.map(clauses, fn clause ->
      case unwrap_meta(clause) do
        {:list, [{:vector, params} | body]} -> {params, body}
        other -> raise "invalid fn clause: #{inspect(other)}"
      end
    end)
  end

  # Every macro fn receives `&form`/`&env` as its first two params — the
  # whole call form and the compile-time env — whether or not the body
  # names them. Inject them so `&form`/`&env` resolve as locals;
  # expand_macro always prepends the matching values.
  defp macro_clauses([{params, body} | rest]),
    do: [{macro_params(params), body} | macro_clauses(rest)]

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
  defp compile_fn(clauses, env, opts \\ []) do
    nil_rest = Keyword.get(opts, :nil_rest, false)
    fn_name = Keyword.get(opts, :name)

    compiled =
      Enum.map(clauses, fn {params, body} ->
        self = fresh_var("fnself")

        {head_vars, body_ast, fixed_count, variadic?} =
          compile_clause(env, params, body, %{self: self}, nil_rest, fn_name)
        fn_ast = self_apply(self, {:fn, [], [{:->, [], [head_vars, body_ast]}]})

        if variadic? do
          {:variadic, fixed_count, fn_ast}
        else
          {:fixed, fixed_count, fn_ast}
        end
      end)

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

  # `(fn s -> fn … -> body end end).(itself)` — self-application,
  # tail-call-optimized on the BEAM; shared by loop and fn recur.
  defp self_apply(self, inner_fn) do
    outer_fn = {:fn, [], [{:->, [], [[self], inner_fn]}]}
    {{:., [], [outer_fn]}, [], [outer_fn]}
  end

  # Compile one `{params, body}` fn clause. Returns
  # `{head_vars, body_ast, fixed_param_count, variadic?}`; the
  # caller picks the recur target via `recur_spec` (`%{self: var}`
  # for anonymous fns, `%{self_call: {mod, fname}}` for linked
  # defns) and decides how to wrap the result.
  defp compile_clause(env, params, body, recur_spec, nil_rest \\ false, fn_name \\ nil) do
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

    body_ast = block(preludes ++ rest_prelude ++ [block_forms(body, fn_env)])
    {head_vars, body_ast, length(fixed), rest != nil}
  end

  defp split_variadic(params) do
    case Enum.split_while(params, &(&1 != {:symbol, "&"})) do
      {fixed, []} ->
        {fixed, nil}

      {fixed, [{:symbol, "&"}, {:symbol, _} = rest]} ->
        {fixed, rest}

      _ ->
        raise "& in params must be followed by exactly one symbol"
    end
  end

  # Simple symbol params go straight into the fn head; destructured
  # params bind a fresh var there and destructure in a body prelude.
  defp bind_params(env, params) do
    {vars, preludes, acc_env} =
      Enum.reduce(params, {[], [], env}, fn
        {:symbol, name}, {vars, preludes, acc_env} ->
          var = fresh_var(name)
          {vars ++ [var], preludes, put_local(acc_env, name, var)}

        destructure, {vars, preludes, acc_env} ->
          whole = fresh_var("whole")
          {sub_steps, acc_env} = destructure_steps(destructure, acc_env, whole)
          prelude = Enum.map(sub_steps, fn {var, expr_ast} -> {:=, [], [var, expr_ast]} end)
          {vars ++ [whole], preludes ++ prelude, acc_env}
      end)

    {vars, preludes, acc_env}
  end

  # Destructuring, Clojure-style: lenient. `[a b & rest]` compiles
  # to nth/drop lookups (extra elements ignored, missing ones nil);
  # `{:keys [a] :as m}` compiles to `get` lookups (missing keys nil).
  # Returns `{steps, env'}` where steps are `{var, expr_ast}` pairs
  # whose exprs read from `whole_ast`.
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

          # Clojure binds an exhausted `& rest` to nil, not to an empty
          # collection. Upstream code loops on `(when more …)`, and `[]`
          # is truthy — binding `[]` here made jank's assoc-in/update-in
          # recurse forever rather than fail visibly.
          drop_ast =
            quote do
              case BeamLisp.RT.drop(unquote(whole_ast), unquote(length(fixed))) do
                [] -> nil
                dropped -> dropped
              end
            end

          {[{rest_var, drop_ast}], put_local(env, name, rest_var)}
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
              {{:symbol, k}, default} -> {k, default}
              other -> raise "unsupported :or binding: #{inspect(other)}"
            end)

          {binds, Map.merge(ors, defaults)}

        {{:keyword, "keys"}, {:vector, syms}}, {binds, ors} ->
          key_binds =
            Enum.map(syms, fn
              {:symbol, name} -> {:get, {:symbol, name}, String.to_atom(name)}
              other -> raise "unsupported :keys binding: #{inspect(other)}"
            end)

          {binds ++ key_binds, ors}

        {{:keyword, "strs"}, {:vector, syms}}, {binds, ors} ->
          str_binds =
            Enum.map(syms, fn
              {:symbol, name} -> {:get, {:symbol, name}, name}
              other -> raise "unsupported :strs binding: #{inspect(other)}"
            end)

          {binds ++ str_binds, ors}

        {{:keyword, "as"}, {:symbol, name}}, {binds, ors} ->
          {binds ++ [{:as, name}], ors}

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
                  case key_form do
                    {:keyword, k} -> String.to_atom(k)
                    k when is_binary(k) -> k
                    other -> raise "unsupported map key in binding: #{inspect(other)}"
                  end

                {:get, pattern, key}
            end

          {binds ++ [bind], ors}

        {other, _}, _ ->
          raise "unsupported map binding: #{inspect(other)}"
      end)

    # Compile the :or defaults in the entering scope (before any bind
    # in this map), as Clojure does.
    ors_asts = Map.new(ors, fn {k, default} -> {k, compile(default, env)} end)

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

  # `[a b & rest :as whole]` peels the trailing `:as name` off the
  # binding vector so split_variadic still sees `[a b & rest]`. `:as` is
  # positional at the END: anywhere else, or a missing name after it,
  # is a loud error rather than a silent mis-bind.
  defp peel_as_bind(elems) do
    case Enum.reverse(elems) do
      [{:symbol, name}, {:keyword, "as"} | rest_rev] ->
        {Enum.reverse(rest_rev), name}

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
  defp datum({:keyword, name}), do: String.to_atom(name)
  # Source positions are a COMPILER channel, not data. A macro receives
  # its arguments as data and walks them with `first`/`rest`/`seq?` —
  # runtime fns that know lists, not `{:meta, form, m}` wrappers. Leaving
  # the wrapper on made `(-> 5 (+ 3) (* 2))` compile `(* 2)` as a
  # one-argument call, because `->`'s `rest` saw a wrapper where a list
  # was promised. Positions are read off the form BEFORE it becomes a
  # datum (see `compile/2`); past this boundary they are dropped.
  defp datum({:meta, form, _m}), do: datum(form)
  defp datum({:list, items}), do: Enum.map(items, &datum/1)
  defp datum({:vector, items}), do: BeamLisp.Vector.new(Enum.map(items, &datum/1))
  defp datum({:set, items}), do: BeamLisp.Set.new(Enum.map(items, &datum/1))
  defp datum({:map, kvs}), do: Map.new(kvs, fn {k, v} -> {datum(k), datum(v)} end)
  defp datum(lit), do: lit

  # One protocol method implementation: `(m [args] body…)` compiles to
  # a method-name => fn-value map entry. The method form may carry a
  # reader position (it is a list); unwrap it so the shape matches.
  defp protocol_impl(form, env) do
    case unwrap_meta(form) do
      {:list, [{:symbol, m} | rest]} ->
        if rest == [], do: raise("defprotocol method #{m}: expected a body")
        {m, compile_fn(fn_clauses(rest), env)}

      other ->
        raise("expected (method-name [args]…) implementation, got #{inspect(other)}")
    end
  end

  # Resolve a type argument to the tag `Multi.type_of/1` would produce
  # for values of that type: keywords are the builtin tags themselves,
  # an uppercase symbol names an Elixir struct module, a lowercase
  # symbol is a bare tag name.
  defp type_tag({:keyword, name}), do: String.to_atom(name)

  defp type_tag({:symbol, name}) do
    if uppercase?(name), do: Module.concat([name]), else: String.to_atom(name)
  end

  defp type_tag(other), do: raise("expected a type tag (keyword) or struct module, got #{inspect(other)}")

  # Resolve a var name (possibly `alias/name` or `ns/name`) to a
  # `{ns, name}` pair for defmethod / protocol targets.
  defp multi_var_target(env, name) do
    case String.split(name, "/", parts: 2) do
      ["", _rest] -> {env.ns, name}
      [prefix, var] -> {Env.alias_target(env.ns, prefix) || core_alias(prefix), var}
      [plain] -> {env.ns, plain}
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
          uppercase?(prefix) -> {:remote, Module.concat([prefix]), String.to_atom(fun)}
          Env.ns_exists?(prefix) -> {:var, prefix, fun}
          true -> {:remote, String.to_atom(prefix), String.to_atom(fun)}
        end
    end
  end

  defp fetch_quoted(ns, name) do
    quote do
      BeamLisp.Env.fetch!(unquote(ns), unquote(name))
    end
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
    block(Enum.map(inits, &compile(&1, notail(env))) ++ [compile(last, env)])
  end

  # --- compile-time env ---

  defp notail(env), do: %{env | tail: false}

  # Thread a form's position (from its FormMeta wrapper) into the compile
  # env so the emitters below can stamp `line:` onto the AST. Positions are
  # best-effort: a form with no metadata keeps the env's current position.
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

  # The name of a `{:symbol, name}` token, possibly position-wrapped.
  defp name_of(form), do: name_of_unwrapped(unwrap_meta(form))
  defp name_of_unwrapped({:symbol, name}), do: name

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
