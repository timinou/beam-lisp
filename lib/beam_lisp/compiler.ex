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

  @special_forms ~w(ns def fn defn defmacro let loop recur if do quote syntax-quote receive throw try)

  @doc "A fresh top-level compile-time environment."
  def new_env(ns \\ Env.current_ns()), do: %{ns: ns, locals: %{}, recur: nil, tail: true}

  @doc "Read, compile and evaluate every form in `source`. Returns the last value."
  def eval_string(source, env \\ new_env()) do
    # Enter the env's namespace; from there, per-form re-reads track
    # any `ns` switches, exactly as defmacro side effects are seen.
    Env.in_ns(env.ns)

    source
    |> Reader.read_all()
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
      Macro.Env.location(__ENV__)
    )

    mod.run()
  end

  @doc "Compile one reader form to an Elixir quoted expression."
  def compile(form, env)

  # --- literals ---

  def compile(form, _env)
      when is_number(form) or is_binary(form) or is_boolean(form) or is_nil(form),
      do: form

  def compile({:keyword, name}, _env), do: String.to_atom(name)

  def compile({:vector, items}, env) do
    tuple_ast = {:{}, [], Enum.map(items, &compile(&1, notail(env)))}
    {:%, [], [{:__aliases__, [], [:BeamLisp, :Vector]}, {:%{}, [], [items: tuple_ast]}]}
  end

  def compile({:map, kvs}, env) do
    {:%{}, [], Enum.map(kvs, fn {k, v} -> {compile(k, notail(env)), compile(v, notail(env))} end)}
  end

  # --- symbols ---

  def compile({:symbol, name}, env) do
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

  def compile({:list, []}, _env), do: []

  def compile({:list, [{:symbol, head} | args]}, env) when head in @special_forms do
    compile_special(head, args, env)
  end

  def compile({:list, [{:keyword, kw} | args]}, env) do
    arg_asts = Enum.map(args, &compile(&1, notail(env)))

    quote do
      BeamLisp.RT.invoke(unquote(String.to_atom(kw)), unquote(arg_asts))
    end
  end

  def compile({:list, [{:symbol, name} | args]}, env) do
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
            compile(expand_macro(macro_fn, args), env)

          :error ->
            arg_asts = compile_args(args, env)

            linked =
              case Env.link(env.ns, name) do
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

  def compile({:list, [head | args]}, env) do
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
  defp compile_special("ns", [{:symbol, name} | clauses], _env) do
    specs =
      Enum.flat_map(clauses, fn
        {:list, [{:keyword, "require"} | require_specs]} -> require_specs
        other -> raise "ns supports only :require clauses, got: #{inspect(other)}"
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

  defp compile_special("def", [{:symbol, name}, init], env),
    do: compile_def(name, compile(init, notail(env)), env)

  defp compile_special("def", [{:symbol, name}, doc, init], env) when is_binary(doc),
    do: compile_def(name, compile(init, notail(env)), env, doc)

  defp compile_special("fn", args, env) do
    clauses =
      case args do
        [{:symbol, _name} | clauses] -> fn_clauses(clauses)
        clauses -> fn_clauses(clauses)
      end

    compile_fn(clauses, env)
  end

  defp compile_special("defn", [{:symbol, name} | rest], env) do
    {doc, rest} = split_docstring(rest)

    cond do
      rest == [] ->
        raise "defn #{name}: expected at least one parameter vector"

      match?([h | _] when is_binary(h), rest) ->
        raise "defn #{name}: expected a parameter vector, got a string literal (a docstring must be followed by clauses)"

      true ->
        compile_defn(name, fn_clauses(rest), env, doc)
    end
  end

  # A macro is a fn stored under a tag; calls to it expand at
  # compile time (see macro_for/expand_macro below).
  defp compile_special("defmacro", [{:symbol, name} | rest], env) do
    {doc, rest} = split_docstring(rest)

    cond do
      rest == [] ->
        raise "defmacro #{name}: expected at least one parameter vector"

      match?([h | _] when is_binary(h), rest) ->
        raise "defmacro #{name}: expected a parameter vector, got a string literal (a docstring must be followed by clauses)"

      true ->
        compile_def(name, {:{}, [], [:"$macro", compile_fn(fn_clauses(rest), env)]}, env, doc)
    end
  end

  defp compile_special("syntax-quote", [form], env), do: synq_data(form, env)

  defp compile_special("let", [{:vector, bindings} | body], env) do
    {steps, final_env} = compile_bindings(bindings, notail(env))
    body_ast = block_forms(body, %{final_env | tail: env.tail})
    nest_steps(steps, body_ast)
  end

  # loop = let + a recur target. Self-application is a tail call on
  # the BEAM, so (recur …) runs in constant stack. Destructured
  # bindings destructure at entry: the recur params are the pattern
  # values (the whole map/vector), so `recur` re-supplies them exactly
  # as in Clojure.
  defp compile_special("loop", [{:vector, bindings} | body], env) do
    {params, entry_binds, arg_asts, bound_env} = loop_bindings(bindings, notail(env))

    self = fresh_var("loop")
    loop_env = %{bound_env | recur: %{self: self, arity: length(params)}, tail: true}
    body_ast = nest_steps(entry_binds, block_forms(body, loop_env))

    inner_fn = {:fn, [], [{:->, [], [params, body_ast]}]}
    self_applied = self_apply(self, inner_fn)
    {{:., [], [self_applied]}, [], arg_asts}
  end

  defp compile_special("recur", args, env) do
    case env.recur do
      nil ->
        raise "recur used with no enclosing loop or fn"

      %{arity: arity} = target ->
        unless env.tail, do: raise("recur must be in tail position")

        unless length(args) == arity,
          do: raise("recur arity mismatch: target takes #{arity}, got #{length(args)}")

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
      Enum.split_with(clauses, &match?({:list, [{:symbol, "after"} | _]}, &1))

    pairs = Enum.chunk_every(normal, 2)

    unless Enum.all?(pairs, &(length(&1) == 2)) do
      raise "receive clauses must be pattern/body pairs"
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

        [{:list, [{:symbol, "after"}, timeout, body]}] ->
          after_clause = {:->, [], [[compile(timeout, notail(env))], compile(body, env)]}
          [do: do_clauses, after: [after_clause]]

        _ ->
          raise "receive takes at most one (after ms body) clause"
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
    {catches, rest} = Enum.split_with(forms, &match?({:list, [{:symbol, "catch"} | _]}, &1))
    {finallies, body} = Enum.split_with(rest, &match?({:list, [{:symbol, "finally"} | _]}, &1))

    finally_body =
      case finallies do
        [] -> []
        [{:list, [{:symbol, "finally"} | fb]}] -> fb
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
  defp catch_branch({:list, [{:symbol, "catch"}, first | rest]}, e_var, env) do
    case first do
      {:symbol, name} ->
        if uppercase?(name) do
          case rest do
            [{:symbol, e_name} | handler] ->
              typed_branch(name, e_name, handler, e_var, env)

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
  defp compile_pattern({:symbol, "_"}, env), do: {[{:_, [], __MODULE__}], env}

  defp compile_pattern({:symbol, name}, env) do
    var = fresh_var(name)
    {[var], put_local(env, name, var)}
  end

  defp compile_pattern({:keyword, name}, env), do: {[String.to_atom(name)], env}

  defp compile_pattern({:vector, items}, env) do
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

  defp compile_pattern({:map, kvs}, env) do
    {pairs, env} =
      Enum.map_reduce(kvs, env, fn {k, v}, acc_env ->
        key =
          case k do
            {:keyword, name} -> String.to_atom(name)
            lit when is_number(lit) or is_binary(lit) -> lit
            other -> raise "unsupported map pattern key: #{inspect(other)}"
          end

        {[pat], acc_env} = compile_pattern(v, acc_env)
        {{key, pat}, acc_env}
      end)

    {[{:%{}, [], pairs}], env}
  end

  defp compile_pattern({:list, [{:symbol, "quote"}, form]}, env) do
    {[Macro.escape(datum(form))], env}
  end

  defp compile_pattern(lit, env) when is_number(lit) or is_binary(lit) or is_boolean(lit) or is_nil(lit),
    do: {[lit], env}

  defp compile_pattern(other, _env), do: raise("unsupported receive pattern: #{inspect(other)}")

  # A defn links: its clauses become named defs in the namespace
  # module (variadic under a mangled name, rest as the last param),
  # the var's value is a capture, and later call sites compile to
  # direct remote calls. See BeamLisp.Link.
  defp compile_defn(name, clauses, env, doc) do
    mod = BeamLisp.Link.module_for(env.ns)

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

        def_ast = {:def, [], [{fname, [], head_vars}, [do: body_ast]]}
        {kind, fixed_count, fname, def_ast}
      end)

    defvar_ast =
      quote do
        BeamLisp.Link.defvar(unquote(env.ns), unquote(name), unquote(Macro.escape(entries)))
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
    case Env.fetch(ns, name) do
      {:ok, {:"$macro", m}} -> {:ok, m}
      _ -> :error
    end
  end

  # Call the macro with the *unevaluated* argument forms as data,
  # then reinterpret the data it returns as a form to compile.
  # Vectors-as-data round-trip as `%BeamLisp.Vector{}`, which is why
  # macros needed a real vector type: `(fn [x] …)` and `[x]` must
  # not collapse into each other.
  defp expand_macro(macro_fn, args) do
    args
    |> Enum.map(&datum/1)
    |> then(&BeamLisp.RT.invoke(macro_fn, &1))
    |> data_to_form()
  end

  defp data_to_form({:symbol, _name} = sym), do: sym

  defp data_to_form(%BeamLisp.Vector{} = v),
    do: {:vector, Enum.map(BeamLisp.Vector.to_list(v), &data_to_form/1)}

  defp data_to_form(items) when is_list(items),
    do: {:list, Enum.map(items, &data_to_form/1)}

  defp data_to_form(m) when is_map(m),
    do: {:map, Enum.map(m, fn {k, v} -> {data_to_form(k), data_to_form(v)} end)}

  defp data_to_form(a) when is_atom(a) and a not in [nil, true, false],
    do: {:keyword, Atom.to_string(a)}

  defp data_to_form(lit), do: lit

  # --- syntax-quote ---

  # Emits AST that *builds* the datum at runtime, with ~ and ~@
  # punching holes back into evaluated code.
  defp synq_data({:list, [{:symbol, "unquote"}, x]}, env), do: compile(x, notail(env))

  defp synq_data({:list, [{:symbol, "unquote-splicing"}, _]}, _env),
    do: raise("~@ is only valid inside a syntax-quoted list or vector")

  defp synq_data({:list, items}, env), do: synq_list(items, env)

  defp synq_data({:vector, items}, env) do
    quote do
      BeamLisp.Vector.new(unquote(synq_list(items, env)))
    end
  end

  defp synq_data({:map, kvs}, env) do
    {:%{}, [], Enum.map(kvs, fn {k, v} -> {synq_data(k, env), synq_data(v, env)} end)}
  end

  defp synq_data({:symbol, name}, _env), do: Macro.escape({:symbol, name})
  defp synq_data({:keyword, name}, _env), do: String.to_atom(name)
  defp synq_data(lit, _env), do: lit

  defp synq_list(items, env) do
    Enum.reduce(Enum.reverse(items), [], fn
      {:list, [{:symbol, "unquote-splicing"}, x]}, acc ->
        {:++, [], [compile(x, notail(env)), acc]}

      item, acc ->
        [{:|, [], [synq_data(item, env), acc]}]
    end)
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
      raise "binding forms must be even, each a pattern and a value"
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
      raise "binding forms must be even, each a pattern and a value"
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
    Enum.map(clauses, fn
      {:list, [{:vector, params} | body]} -> {params, body}
      other -> raise "invalid fn clause: #{inspect(other)}"
    end)
  end

  # A single-arity fn compiles to a real Elixir fn — passable to
  # `Enum`, storable in a var, callable via `apply/2`. Elixir fns are
  # fixed-arity, so multi-clause and variadic fns get a tag that
  # `RT.invoke/2` dispatches on.
  #
  # Every clause is also a recur target (as in Clojure): the clause
  # fn is wrapped in self-application, and `recur` in tail position
  # re-enters it in constant stack. Inner fns shadow outer targets,
  # so recur never crosses a fn boundary.
  defp compile_fn(clauses, env) do
    compiled =
      Enum.map(clauses, fn {params, body} ->
        self = fresh_var("fnself")
        {head_vars, body_ast, fixed_count, variadic?} = compile_clause(env, params, body, %{self: self})
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
  defp compile_clause(env, params, body, recur_spec) do
    {fixed, rest} = split_variadic(params)
    {head_vars, preludes, clause_env} = bind_params(env, fixed)

    {head_vars, clause_env} =
      case rest do
        nil ->
          {head_vars, clause_env}

        {:symbol, name} ->
          rest_var = fresh_var(name)
          {head_vars ++ [rest_var], put_local(clause_env, name, rest_var)}
      end

    recur = Map.put(recur_spec, :arity, length(head_vars))
    fn_env = %{clause_env | recur: recur, tail: true}
    body_ast = block(preludes ++ [block_forms(body, fn_env)])
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

          drop_ast =
            quote do
              BeamLisp.RT.drop(unquote(whole_ast), unquote(length(fixed)))
            end

          {[{rest_var, drop_ast}], put_local(env, name, rest_var)}
      end

    {Enum.concat(steps) ++ rest_steps, env}
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
  defp datum({:list, items}), do: Enum.map(items, &datum/1)
  defp datum({:vector, items}), do: BeamLisp.Vector.new(Enum.map(items, &datum/1))
  defp datum({:map, kvs}), do: Map.new(kvs, fn {k, v} -> {datum(k), datum(v)} end)
  defp datum(lit), do: lit

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
