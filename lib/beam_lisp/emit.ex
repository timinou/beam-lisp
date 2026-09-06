defmodule BeamLisp.Emit do
  @moduledoc """
  Shared canonical ANF module construction for live and AOT namespace emission.
  Definitions live in immutable body modules; a stable namespace forwards calls.
  The committed seed's older ABI is adapted only during bootstrap staging.
  """
  @type clause :: map()
  @type descriptor :: map()

  def module_for(ns) do
    segments = ns |> String.split(".") |> Enum.map(&Macro.camelize/1)
    Module.concat([BeamLisp.Ns | segments])
  end

  def fresh_body_module,
    do:
      Module.concat([
        BeamLisp.Ns,
        "Fn",
        "M" <> Integer.to_string(System.unique_integer([:positive]))
      ])

  def attach_body_module(new_defs, body_mod),
    do: Enum.map(new_defs, fn entry -> Tuple.insert_at(entry, tuple_size(entry), body_mod) end)

  def fixed_variadic(new_defs) do
    fixed = for {:fixed, arity, fname, _} <- new_defs, do: {arity, fname}

    variadic =
      Enum.find_value(new_defs, fn
        {:variadic, min, fname, _} -> {min, fname}
        _ -> nil
      end)

    {fixed, variadic}
  end

  def body_modules(ns_defs) do
    ns_defs
    |> Enum.flat_map(fn {_var, defs} -> defs end)
    |> Enum.group_by(&elem(&1, 4), &elem(&1, 3))
  end

  def shim_clauses(ns_defs) do
    ns_defs
    |> Enum.flat_map(fn {_var, defs} -> defs end)
    |> Enum.uniq_by(fn d -> {elem(d, 2), clause_arity(elem(d, 3))} end)
    |> Enum.map(fn d -> shim_clause(elem(d, 2), clause_arity(elem(d, 3)), elem(d, 4)) end)
  end

  defp clause_arity(%{op: :"defn-clause", params: params}), do: length(params)

  defp clause_arity(other),
    do:
      raise(
        ArgumentError,
        "canonical emitter requires :defn-clause payloads, got: #{inspect(other, limit: 4)}"
      )

  defp shim_clause(fname, arity, body_mod) do
    names = if arity == 0, do: [], else: Enum.map(0..(arity - 1), &"arg#{&1}")
    params = Enum.map(names, &%{pop: :pvar, name: &1})

    %{
      op: :"defn-clause",
      fname: fname,
      params: params,
      guard: nil,
      body: remote(body_mod, fname, Enum.map(names, &var/1)),
      ann: %{}
    }
  end

  def descriptor(name, clauses, exports, attrs \\ [], ann \\ %{}) do
    exports = Enum.map(exports, &canonical_pair/1)
    attrs = Enum.map(attrs, &canonical_pair/1)

    if function_exported?(BeamLisp.Ns.Anf, :module, 5),
      do: apply(BeamLisp.Ns.Anf, :module, [name, clauses, exports, attrs, ann]),
      else: BeamLisp.BootstrapAdapter.descriptor(name, clauses, exports, attrs, ann)
  end

  defp canonical_pair(%BeamLisp.Vector{} = pair), do: pair
  defp canonical_pair({left, right}), do: %BeamLisp.Vector{items: {left, right}}
  defp canonical_pair([left, right]), do: %BeamLisp.Vector{items: {left, right}}

  def descriptor_for(name, clauses, attrs \\ [], ann \\ %{}) do
    exports = clauses |> Enum.map(&{&1.fname, length(&1.params)}) |> Enum.uniq()
    descriptor(name, clauses, exports, attrs, ann)
  end

  def compile_descriptor(descriptor) do
    compiled =
      if function_exported?(BeamLisp.Ns.Lower, :"descriptor->beam", 1),
        do: apply(BeamLisp.Ns.Lower, :"descriptor->beam", [descriptor]),
        else: BeamLisp.BootstrapAdapter.compile_descriptor(descriptor)

    case compiled do
      {mod, bytes} when is_atom(mod) and is_binary(bytes) -> {mod, bytes}
      other -> raise "Core module emitter returned invalid result: #{inspect(other)}"
    end
  end

  def load_binary!({mod, bytes}, filename \\ "beam_lisp_generated") do
    case :code.load_binary(mod, String.to_charlist(filename), bytes) do
      {:module, ^mod} -> mod
      {:error, reason} -> raise "cannot publish #{inspect(mod)}: #{inspect(reason)}"
      other -> raise "cannot publish #{inspect(mod)}: #{inspect(other)}"
    end
  end

  def fn_value(mod, [{arity, fname}], nil), do: Function.capture(mod, fname, arity)

  def fn_value(mod, fixed, variadic) do
    fixed_map =
      Map.new(fixed, fn {arity, fname} -> {arity, Function.capture(mod, fname, arity)} end)

    rest =
      case variadic do
        nil -> nil
        {min, fname} -> {min, Function.capture(mod, fname, min + 1)}
      end

    {:"$blfn", fixed_map, rest}
  end

  def lit(value), do: %{op: :lit, val: value, ann: %{}}
  def var(name), do: %{op: :var, name: name, ann: %{}}
  def remote(mod, fun, args), do: %{op: :remote, mod: mod, fun: fun, args: args, ann: %{}}
  def sequence(nodes), do: %{op: :do, stmts: nodes, ann: %{}}
  def closure(body), do: %{op: :fn, clauses: [%{pats: [], guard: nil, body: body}], ann: %{}}

  def function_clause(fname, body, params \\ []),
    do: %{op: :"defn-clause", fname: fname, params: params, guard: nil, body: body, ann: %{}}
end
