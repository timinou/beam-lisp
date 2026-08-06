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

  @special_forms ~w(ns def fn defn defmacro let loop recur if do quote syntax-quote)

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
    arg_env = notail(env)
    arg_asts = Enum.map(args, &compile(&1, arg_env))

    cond do
      local?(env, name) ->
        invoke_quoted(local(env, name), arg_asts)

      true ->
        # Macros resolve at compile time against the live registry,
        # including through aliases (a/macro → target-ns/macro).
        case macro_for(env.ns, name) do
          {:ok, macro_fn} ->
            compile(expand_macro(macro_fn, args), env)

          :error ->
            if String.contains?(name, "/") do
              case slash_target(env, name) do
                {:var, ns, var} ->
                  invoke_quoted(fetch_quoted(ns, var), arg_asts)

                {:remote, module, fun} ->
                  quote do
                    apply(unquote(module), unquote(fun), unquote(arg_asts))
                  end
              end
            else
              invoke_quoted(fetch_quoted(env.ns, name), arg_asts)
            end
        end
    end
  end

  def compile({:list, [head | args]}, env) do
    arg_env = notail(env)
    invoke_quoted(compile(head, arg_env), Enum.map(args, &compile(&1, arg_env)))
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
    do: compile_def(name, compile(init, notail(env)), env)

  defp compile_special("fn", args, env) do
    clauses =
      case args do
        [{:symbol, _name} | clauses] -> fn_clauses(clauses)
        clauses -> fn_clauses(clauses)
      end

    compile_fn(clauses, env)
  end

  defp compile_special("defn", [{:symbol, name} | rest], env) do
    rest =
      case rest do
        [doc | rest] when is_binary(doc) -> rest
        rest -> rest
      end

    compile_def(name, compile_fn(fn_clauses(rest), env), env)
  end

  # A macro is a fn stored under a tag; calls to it expand at
  # compile time (see macro_for/expand_macro below).
  defp compile_special("defmacro", [{:symbol, name} | rest], env) do
    rest =
      case rest do
        [doc | rest] when is_binary(doc) -> rest
        rest -> rest
      end

    compile_def(name, {:{}, [], [:"$macro", compile_fn(fn_clauses(rest), env)]}, env)
  end

  defp compile_special("syntax-quote", [form], env), do: synq_data(form, env)

  defp compile_special("let", [{:vector, bindings} | body], env) do
    {steps, final_env} = compile_bindings(bindings, notail(env))
    body_ast = block_forms(body, %{final_env | tail: env.tail})
    nest_steps(steps, body_ast)
  end

  # loop = let + a recur target. Self-application is a tail call on
  # the BEAM, so (recur …) runs in constant stack.
  defp compile_special("loop", [{:vector, bindings} | body], env) do
    {steps, bound_env} = compile_bindings(bindings, notail(env))

    self = fresh_var("loop")
    {param_vars, arg_asts} = Enum.unzip(steps)
    loop_env = %{bound_env | recur: %{self: self, arity: length(steps)}, tail: true}
    body_ast = block_forms(body, loop_env)

    inner_fn = {:fn, [], [{:->, [], [param_vars, body_ast]}]}
    outer_fn = {:fn, [], [{:->, [], [[self], inner_fn]}]}
    self_applied = {{:., [], [outer_fn]}, [], [outer_fn]}
    {{:., [], [self_applied]}, [], arg_asts}
  end

  defp compile_special("recur", args, env) do
    case env.recur do
      nil ->
        raise "recur used with no enclosing loop or fn"

      %{self: self, arity: arity} ->
        unless env.tail, do: raise("recur must be in tail position")

        unless length(args) == arity,
          do: raise("recur arity mismatch: target takes #{arity}, got #{length(args)}")

        arg_asts = Enum.map(args, &compile(&1, notail(env)))
        self_app = {{:., [], [self]}, [], [self]}
        {{:., [], [self_app]}, [], arg_asts}
    end
  end

  defp compile_special("if", [test, then], env), do: compile_if(test, then, nil, env)
  defp compile_special("if", [test, then, else_], env), do: compile_if(test, then, else_, env)

  defp compile_special("do", body, env), do: block_forms(body, env)

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

  defp compile_def(name, init_ast, env) do
    quote do
      BeamLisp.Env.intern(unquote(env.ns), unquote(name), unquote(init_ast))
    end
  end

  defp compile_if(test, then, else_, env) do
    {:if, [],
     [compile(test, notail(env)), [do: compile(then, env), else: compile(else_, env)]]}
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
  # `RT.invoke/2` dispatches on. A fn body is a new recur scope:
  # recur may not cross a fn boundary (fn-targeted recur is wave 3).
  defp compile_fn(clauses, env) do
    compiled =
      Enum.map(clauses, fn {params, body} ->
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

        fn_env = %{clause_env | recur: nil, tail: true}
        body_ast = block(preludes ++ [block_forms(body, fn_env)])
        fn_ast = {:fn, [], [{:->, [], [head_vars, body_ast]}]}

        case rest do
          nil -> {:fixed, length(fixed), fn_ast}
          _ -> {:variadic, length(fixed), fn_ast}
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
    {steps, env} =
      Enum.reduce(kvs, {[], env}, fn
        {{:keyword, "keys"}, {:vector, syms}}, {steps, acc_env} ->
          Enum.reduce(syms, {steps, acc_env}, fn {:symbol, name}, {steps, acc_env} ->
            var = fresh_var(name)

            get_ast =
              quote do
                BeamLisp.RT.get(unquote(whole_ast), unquote(String.to_atom(name)))
              end

            {steps ++ [{var, get_ast}], put_local(acc_env, name, var)}
          end)

        {{:keyword, "as"}, {:symbol, name}}, {steps, acc_env} ->
          var = fresh_var(name)
          {steps ++ [{var, whole_ast}], put_local(acc_env, name, var)}

        {{:keyword, key}, {:symbol, name}}, {steps, acc_env} ->
          var = fresh_var(name)

          get_ast =
            quote do
              BeamLisp.RT.get(unquote(whole_ast), unquote(String.to_atom(key)))
            end

          {steps ++ [{var, get_ast}], put_local(acc_env, name, var)}

        other, _acc ->
          raise "unsupported map binding: #{inspect(other)}"
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
