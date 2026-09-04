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

  alias BeamLisp.{Emit, Env}


  @doc "The module backing namespace `ns`. Delegates to `BeamLisp.Emit`."
  defdelegate module_for(ns), to: BeamLisp.Emit

  @doc """
  Install `new_defs` for `name` in `ns` and regenerate the namespace
  module. `new_defs` is a list of
  `{:fixed, arity, fname, def_ast} | {:variadic, min, fname, def_ast}`.
  Returns the interned value.

  The definition's real body is compiled into a fresh, immutable *body
  module*; the namespace module only carries a thin shim that forwards
  to it. See `BeamLisp.Emit.fresh_body_module/0` and `BeamLisp.Emit.shim_defs/1`
  for why — the shim/body split now lives in the shared emitter.
  """
  def defvar(ns, name, new_defs, location \\ nil) when is_binary(ns) and is_binary(name) do
    # Backend switch (PLAN-079 S-D). When the process/global backend is :core
    # AND the self-hosted Core backend module is loaded, a def is built through
    # bl-ANF -> Core Erlang (self.core/core-defvar-anf) instead of the Elixir
    # emitter below. Default :elixir (key unset), so this is INERT until
    # something opts in -- the switch a full-suite regression flips to prove
    # Core can build the whole system before it becomes the default.
    if core_backend?() do
      apply(BeamLisp.Ns.Self.Core, :"core-defvar-anf", [ns, name, new_defs])
    else
      defvar_elixir(ns, name, new_defs, location)
    end
  end

  # True when the active backend is :core and self.core is available to serve
  # it. Process key first (per-eval override, e.g. a test), then the global
  # key; absent -> :elixir. The load/export guard covers the boot window before
  # self.core is compiled -- during genesis the Elixir path must run.
  defp core_backend? do
    backend =
      Process.get(:bl_backend) ||
        (case BeamLisp.Env.lookup({:bl_backend}) do
           {:ok, b} -> b
           :error -> :elixir
         end)

    backend == :core and Code.ensure_loaded?(BeamLisp.Ns.Self.Core) and
      function_exported?(BeamLisp.Ns.Self.Core, :"core-defvar-anf", 3) and
      # self.core's VARS must be interned, not just its module code loaded:
      # core-defvar-anf reaches its own siblings (expand-defaults, lower-anf, …)
      # through the Env var table, so an un-interned self.core would route here
      # and then raise `undefined var: self.core/…` on the first sibling call.
      # When the ns is not interned (e.g. a --path-scoped tool env that never
      # booted the Core backend) fall back to the Elixir path, which is always
      # available. `maybe_load_core_backend/0` interns it at boot under :core.
      BeamLisp.Env.loaded_ns?("self.core")
  end

  defp defvar_elixir(ns, name, new_defs, location) do
    mod = Emit.module_for(ns)

    # This definition's real code — and every closure it creates — lives
    # in a fresh body module. Redefinition makes a *new* body module and
    # repoints the shim; closures from the old body keep pointing at their
    # own module, which is never loaded again and so never purged.
    body_mod = Emit.fresh_body_module()
    body_defs = Emit.attach_body_module(new_defs, body_mod)

    all_defs =
      ns
      |> Env.ns_defs()
      |> Map.put(name, body_defs)

    Emit.build_module(body_mod, Emit.body_block(body_defs), location)
    Emit.build_module(mod, Emit.shim_block(all_defs), location)
    Env.put_ns_defs(ns, all_defs)

    {fixed, variadic} = Emit.fixed_variadic(new_defs)
    value = Emit.fn_value(mod, fixed, variadic)
    link_info = {mod, Map.new(fixed), variadic}

    BeamLisp.Env.put_key({:link, ns, name}, link_info)
    Env.intern(ns, name, value)
  end

  # The shim/body split, fn-value shaping, and module creation all live in
  # `BeamLisp.Emit` — the one emitter shared with the AOT compiler, so an
  # AOT-loaded namespace is byte-for-byte the runtime one. These delegations
  # preserve the historical `Link` surface for existing callers.
  @doc "Forwarding shims for the namespace module. See `BeamLisp.Emit.shim_defs/1`."
  defdelegate shim_defs(ns_defs), to: BeamLisp.Emit

  @doc "Group real def ASTs by body module. See `BeamLisp.Emit.body_modules/1`."
  defdelegate body_modules(ns_defs), to: BeamLisp.Emit
end
