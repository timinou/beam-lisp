defmodule BeamLisp.Link do
  @moduledoc """
  Var linking: `defn` becomes named functions in a per-namespace
  module, so call sites compile to direct remote calls instead of
  ETS lookup + `RT.invoke/2` dispatch.

  Namespace `"my.app"` maps to module `BeamLisp.Ns.My.App`. Every
  `defn` (re)generates the namespace module, then:

    * interns the var's *value* as a capture of the module fn, so
      `apply`, `map f`, and interop keep working unchanged
    * registers link metadata in `BeamLisp.Env`, so later call
      sites emit `BeamLisp.Ns.User.f(a, b)` directly

  The namespace module only carries *shims* that forward each fn to its
  own immutable body module (`BeamLisp.Ns.Fn.*`). Splitting the two keeps a
  stored closure alive no matter how often the namespace is redefined:
  the BEAM keeps just two versions of a module and purges the oldest, so
  if closures' code lived in the regenerated namespace module, the third
  redefinition after a closure was created would kill it. Body modules
  are never reloaded, so they are never purged; redefinition makes a new
  body module and repoints the shim, and existing closures keep running
  their own old code. Hot-swap still works because the shim keeps a
  stable name that call sites bake and redefinition reloads in place.

  Variadic fns get a mangled `name__bl_v/min+1` def (last param is
  the rest list) to avoid colliding with fixed clauses of the same
  arity. Redefinition regenerates the module — ordinary BEAM hot
  code semantics.
  """

  alias BeamLisp.Env

  @table :beam_lisp_vars

  @doc "The module backing namespace `ns`."
  def module_for(ns) do
    segments = ns |> String.split(".") |> Enum.map(&Macro.camelize/1)
    Module.concat([BeamLisp.Ns | segments])
  end

  @doc """
  Install `new_defs` for `name` in `ns` and regenerate the namespace
  module. `new_defs` is a list of
  `{:fixed, arity, fname, def_ast} | {:variadic, min, fname, def_ast}`.
  Returns the interned value.

  The definition's real body is compiled into a fresh, immutable *body
  module*; the namespace module only carries a thin shim that forwards
  to it. See `fresh_body_module/0` and `shim_defs/1` for why.
  """
  def defvar(ns, name, new_defs, location \\ nil) when is_binary(ns) and is_binary(name) do
    mod = module_for(ns)

    # This definition's real code — and every closure it creates — lives
    # in a fresh body module. Redefinition makes a *new* body module and
    # repoints the shim; closures from the old body keep pointing at their
    # own module, which is never loaded again and so never purged.
    body_mod = fresh_body_module()
    body_defs = Enum.map(new_defs, fn entry -> Tuple.insert_at(entry, tuple_size(entry), body_mod) end)

    all_defs =
      ns
      |> Env.ns_defs()
      |> Map.put(name, body_defs)

    build_module(body_mod, body_block(body_defs), location)
    build_module(mod, shim_block(all_defs), location)
    Env.put_ns_defs(ns, all_defs)

    fixed = for {:fixed, arity, fname, _} <- new_defs, do: {arity, fname}
    variadic = Enum.find_value(new_defs, fn
      {:variadic, min, fname, _} -> {min, fname}
      _ -> nil
    end)

    value = fn_value(mod, fixed, variadic)

    link_info =
      {mod, Map.new(fixed), variadic}

    :ets.insert(@table, {{:link, ns, name}, link_info})
    Env.intern(ns, name, value)
  end

  # A stable, uniquely-named home for one defn's real code. It is never
  # reloaded, so BEAM version churn cannot purge it: the VM keeps exactly
  # two versions of a module and drops the oldest on the third load, and
  # that drop is what turned stored closures into BadFunctionErrors. It
  # lives under `BeamLisp.Ns.Fn.*` (not `BeamLisp.Fn.*`) so a stack frame
  # from code that raises here still carries the `BeamLisp.Ns.*` prefix
  # that error-reporting tests key on.
  defp fresh_body_module do
    Module.concat([BeamLisp.Ns, "Fn", "M" <> Integer.to_string(System.unique_integer([:positive]))])
  end

  # The real `def` ASTs, one per clause of the defn.
  defp body_block(body_defs) do
    {:__block__, [], Enum.map(body_defs, &elem(&1, 3))}
  end

  @doc """
  The `def` ASTs that go in the namespace module: one forwarding shim per
  defn clause. The namespace module is the stable name call sites bake and
  hot-swap reloads, so AOT must reproduce this exact shape from the defs
  the compiler drove into `Env.ns_defs/1`.
  """
  def shim_defs(ns_defs) do
    Enum.flat_map(ns_defs, fn {_var, defs} -> Enum.map(defs, &shim_def/1) end)
  end

  @doc """
  Group each defn's real `def` ASTs by the body module that hosts them,
  so AOT can emit one `.beam` per body module alongside the namespace
  module. Returns `[{body_mod, [def_ast]}]`.
  """
  def body_modules(ns_defs) do
    ns_defs
    |> Enum.flat_map(fn {_var, defs} -> defs end)
    |> Enum.group_by(&elem(&1, 4), &elem(&1, 3))
  end

  # A guarded clause's head is `{:when, _, params ++ [guard]}`, so the
  # shim MUST carry the guard too. Two reasons, both load-bearing:
  #
  #   * clause selection happens at whichever module the caller enters.
  #     A bare shim would forward every call to the body module's first
  #     clause-by-arity and let it raise FunctionClauseError, instead of
  #     falling through to the next clause.
  #   * without this clause the generic one below binds `fname` to `:when`
  #     and builds `def when(f(x), guard)`, whose body calls itself — a
  #     silent infinite loop the moment the fn is called.
  defp shim_def({kind, _n, _fname, {:def, line, [{:when, wmeta, when_args}, [do: _]]}, body_mod})
       when kind in [:fixed, :variadic] do
    {[{fname, _, head}], [guard]} = Enum.split(when_args, length(when_args) - 1)

    {:def, line,
     [
       {:when, wmeta, [{fname, [], head}, guard]},
       [do: {{:., [], [body_mod, fname]}, [], head}]
     ]}
  end

  defp shim_def({kind, _n, _fname, {:def, line, [{fname, _, head}, [do: _]]}, body_mod})
       when kind in [:fixed, :variadic] do
    {:def, line, [{fname, [], head}, [do: {{:., [], [body_mod, fname]}, [], head}]]}
  end

  # The namespace module: one forwarding shim per defn clause. Shims keep
  # the stable `BeamLisp.Ns.<Ns>.f/arity` entry points that call sites bake
  # and hot-swap reloads, while holding no code themselves — so churning
  # this module (every defn rebuilds it) can never strand a closure.
  defp shim_block(all_defs) do
    {:__block__, [], shim_defs(all_defs)}
  end

  # Create a module from a block, silencing the module-conflict warning:
  # rebuilding the namespace module on every defn is the normal case, and
  # a macro-expanded defn arrives with no position, so fall back to this
  # file's location exactly as before.
  defp build_module(mod, block, location) do
    prev_opts = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      Module.create(mod, block, location || Macro.Env.location(__ENV__))
    after
      Code.compiler_options(prev_opts)
    end
  end

  # A single fixed-arity fn is just a capture of the def — a real
  # Elixir fun, composable with Enum and interop. Anything else gets
  # the tagged multi-arity/variadic wrapper with captures inside.
  defp fn_value(mod, [{arity, fname}], nil) do
    Function.capture(mod, fname, arity)
  end

  defp fn_value(mod, fixed, variadic) do
    fixed_map = Map.new(fixed, fn {arity, fname} -> {arity, Function.capture(mod, fname, arity)} end)

    variadic_entry =
      case variadic do
        nil -> nil
        {min, fname} -> {min, Function.capture(mod, fname, min + 1)}
      end

    {:"$blfn", fixed_map, variadic_entry}
  end
end
