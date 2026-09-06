defmodule BeamLisp.Link do
  @moduledoc """
  Installs canonical clauses as immutable bodies and stable namespace shims.
  All descriptors compile before code and namespace bookkeeping are published.
  """
  alias BeamLisp.{BootstrapAdapter, Emit, Env}
  defdelegate module_for(ns), to: BeamLisp.Emit

  def defvar(ns, name, new_defs, location \\ nil) when is_binary(ns) and is_binary(name) do
    new_defs = BootstrapAdapter.normalize_defs_to_canonical(new_defs)
    mod = Emit.module_for(ns)
    body_mod = Emit.fresh_body_module()
    body_defs = Emit.attach_body_module(new_defs, body_mod)
    all_defs = Env.ns_defs(ns) |> Map.put(name, body_defs)

    all_defs =
      Map.new(all_defs, fn {var, defs} ->
        {var, BootstrapAdapter.normalize_defs_to_canonical(defs)}
      end)

    body_clauses = Enum.map(body_defs, &elem(&1, 3))
    body_beam = body_mod |> Emit.descriptor_for(body_clauses) |> Emit.compile_descriptor()

    shim_beam =
      mod |> Emit.descriptor_for(Emit.shim_clauses(all_defs)) |> Emit.compile_descriptor()

    filename = publication_filename(location)
    Emit.load_binary!(body_beam, filename)
    Emit.load_binary!(shim_beam, filename)
    Env.put_ns_defs(ns, all_defs)
    {fixed, variadic} = Emit.fixed_variadic(new_defs)
    value = Emit.fn_value(mod, fixed, variadic)
    Env.put_key({:link, ns, name}, {mod, Map.new(fixed), variadic})
    Env.intern(ns, name, value)
  end

  defp publication_filename(nil), do: "beam_lisp_live"

  defp publication_filename(location) when is_list(location),
    do: to_string(location[:file] || "beam_lisp_live")

  defp publication_filename(location), do: to_string(location)
  defdelegate shim_clauses(ns_defs), to: BeamLisp.Emit
  defdelegate body_modules(ns_defs), to: BeamLisp.Emit
end
