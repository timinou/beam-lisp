defmodule BeamLisp.Link do
  @moduledoc """
  Var linking: `defn` becomes named functions in a per-namespace
  module, so call sites compile to direct remote calls instead of
  ETS lookup + `RT.invoke/2` dispatch.

  Namespace `"my.app"` maps to module `BeamLisp.Ns.My.App`. Every
  `defn` (re)generates the namespace module with all its current
  defs (O(ns size) per def — defs are rare, calls are hot), then:

    * interns the var's *value* as a capture of the module fn, so
      `apply`, `map f`, and interop keep working unchanged
    * registers link metadata in `BeamLisp.Env`, so later call
      sites emit `BeamLisp.Ns.User.f(a, b)` directly

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
  """
  def defvar(ns, name, new_defs) when is_binary(ns) and is_binary(name) do
    mod = module_for(ns)

    all_defs =
      ns
      |> Env.ns_defs()
      |> Map.put(name, new_defs)

    block =
      {:__block__, [],
       Enum.flat_map(all_defs, fn {_var, defs} -> Enum.map(defs, &elem(&1, 3)) end)}

    # Redefinition is the normal case (every defn regenerates the
    # ns module); silence the compiler's module-conflict warning.
    prev_opts = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      Module.create(mod, block, Macro.Env.location(__ENV__))
    after
      Code.compiler_options(prev_opts)
    end
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
