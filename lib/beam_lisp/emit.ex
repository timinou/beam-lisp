defmodule BeamLisp.Emit do
  @moduledoc """
  The one place that turns a namespace's definitions into loadable modules.

  beam-lisp has two consumers that must produce *identical* module topology
  from the same `ns_defs`:

    * the **runtime** (`BeamLisp.Link.defvar/4`), which `Module.create`s the
      modules in-memory on every `def`, and
    * the **AOT compiler** (`BeamLisp.AOT`), which compiles them to `.beam`
      files on disk.

  When those two drifted, an AOT-loaded namespace behaved differently from a
  source-loaded one — most sharply under BEAM module *version churn*: the VM
  keeps two versions of a module and purges the oldest on the third load. A
  function value or macro closure captured from a purged version raises
  `BadFunctionError`. The runtime avoids this with a **shim/body split**:

    * the real code of each `defn` lives in a **body module**
      (`BeamLisp.Ns.Fn.*`) that is uniquely named and *never reloaded*, so
      churn can never purge it, and
    * the **namespace module** (`BeamLisp.Ns.<Name>`) holds only thin
      forwarding *shims* to the current body module. Rebuilding it on every
      `def` is safe precisely because it holds no code that anything closed
      over.

  This module owns that topology so both consumers share it byte-for-byte.
  It is deliberately close to pure: it maps data (`ns_defs`, def tuples) to
  more data (quoted blocks, module names, fn values). The only effectful
  entry, `build_module/3`, is the runtime's in-memory path; AOT feeds the
  same quoted blocks to `Code.compile_quoted/2` instead.

  ## The def tuple

  A single `defn` clause is a tuple the compiler emits and the runtime
  extends with a body module:

      {kind, arity_or_min, fname, def_ast}          # 4-field, from Compiler
      {kind, arity_or_min, fname, def_ast, body_mod} # 5-field, after attach

  `kind` is `:fixed | :variadic`; `arity_or_min` is the arity (fixed) or the
  minimum fixed argument count (variadic); `fname` is the emitted Elixir
  function atom; `def_ast` is the real `{:def, meta, [head, [do: body]]}`;
  `body_mod` is the module that hosts the real code.
  """

  # --- namespace / module naming ------------------------------------------

  @doc "The stable namespace module backing beam-lisp namespace `ns`."
  def module_for(ns) do
    segments = ns |> String.split(".") |> Enum.map(&Macro.camelize/1)
    Module.concat([BeamLisp.Ns | segments])
  end

  @doc """
  A stable, uniquely-named home for one definition's real code.

  It is never reloaded, so BEAM version churn cannot purge it: the VM keeps
  exactly two versions of a module and drops the oldest on the third load,
  and that drop is what turned stored closures into `BadFunctionError`s. It
  lives under `BeamLisp.Ns.Fn.*` (not `BeamLisp.Fn.*`) so a stack frame from
  code that raises here still carries the `BeamLisp.Ns.*` prefix that
  error-reporting tests key on.

  The runtime uses a process-unique integer — every `def` gets a brand-new
  module, which is exactly what makes redefinition safe. AOT overrides the
  naming with a *deterministic* scheme so incremental rebuilds are stable
  (see `BeamLisp.AOT`).
  """
  def fresh_body_module do
    Module.concat([BeamLisp.Ns, "Fn", "M" <> Integer.to_string(System.unique_integer([:positive]))])
  end

  # --- def-tuple shaping ---------------------------------------------------

  @doc """
  Attach `body_mod` to each 4-field def tuple, yielding the 5-field runtime
  shape `{kind, arity_or_min, fname, def_ast, body_mod}`.
  """
  def attach_body_module(new_defs, body_mod) do
    Enum.map(new_defs, fn entry -> Tuple.insert_at(entry, tuple_size(entry), body_mod) end)
  end

  @doc """
  The `{fixed, variadic}` call shape from a var's 4-field `new_defs`:
  `fixed` is a list of `{arity, fname}`; `variadic` is `{min, fname}` or nil.
  """
  def fixed_variadic(new_defs) do
    fixed = for {:fixed, arity, fname, _} <- new_defs, do: {arity, fname}

    variadic =
      Enum.find_value(new_defs, fn
        {:variadic, min, fname, _} -> {min, fname}
        _ -> nil
      end)

    {fixed, variadic}
  end

  # --- quoted blocks -------------------------------------------------------

  @doc "The real `def` ASTs for one body module: one per clause."
  def body_block(body_defs) do
    {:__block__, [], Enum.map(body_defs, &elem(&1, 3))}
  end

  @doc """
  Group each definition's real `def` ASTs by the body module that hosts
  them, so a consumer can emit one module per body module. Returns
  `[{body_mod, [def_ast]}]`.
  """
  def body_modules(ns_defs) do
    ns_defs
    |> Enum.flat_map(fn {_var, defs} -> defs end)
    |> Enum.group_by(&elem(&1, 4), &elem(&1, 3))
  end

  @doc """
  The forwarding shims that go in the namespace module: one per clause,
  each calling into the clause's body module. This is the stable
  `BeamLisp.Ns.<Ns>.f/arity` surface that call sites bake and hot-swap
  reloads.
  """
  def shim_defs(ns_defs) do
    Enum.flat_map(ns_defs, fn {_var, defs} -> Enum.map(defs, &shim_def/1) end)
  end

  @doc "The namespace module body: one forwarding shim per clause."
  def shim_block(all_defs) do
    {:__block__, [], shim_defs(all_defs)}
  end

  # A guarded clause's head is `{:when, _, params ++ [guard]}`, so the shim
  # MUST carry the guard too. Two reasons, both load-bearing:
  #
  #   * clause selection happens at whichever module the caller enters. A
  #     bare shim would forward every call to the body module's first
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

  # --- fn values -----------------------------------------------------------

  @doc """
  The runtime value of a fn var: a single fixed-arity fn is a plain capture
  (a real Elixir fun, composable with Enum and interop); anything else is
  the tagged multi-arity/variadic wrapper with captures inside. All captures
  target `mod`'s stable exported names.
  """
  def fn_value(mod, [{arity, fname}], nil) do
    Function.capture(mod, fname, arity)
  end

  def fn_value(mod, fixed, variadic) do
    fixed_map = Map.new(fixed, fn {arity, fname} -> {arity, Function.capture(mod, fname, arity)} end)

    variadic_entry =
      case variadic do
        nil -> nil
        {min, fname} -> {min, Function.capture(mod, fname, min + 1)}
      end

    {:"$blfn", fixed_map, variadic_entry}
  end

  # --- runtime module creation --------------------------------------------

  @doc """
  Create a module from a quoted block, silencing the module-conflict
  warning: rebuilding the namespace module on every `def` is the normal
  case, and a macro-expanded `defn` arrives with no position, so fall back
  to this file's location.

  This is the runtime's in-memory path. AOT compiles the same blocks to
  `.beam` binaries instead of calling this.
  """
  def build_module(mod, block, location) do
    # VM-wide critical section per module: with async test forks requiring
    # libraries concurrently, two loaders can compile the SAME module at
    # once (multi-ns files defeat per-file load locks: usage.bl and
    # error.bl both define relay.error) — Module.create raises "currently
    # being defined". Same fix as Record.define/3 and Native.declare/3
    # (PLAN-046); lock ids are {resource, requester} 2-tuples. The loser
    # simply redefines identically under ignore_module_conflict.
    :global.trans({{:bl_module, mod}, self()}, fn ->
      prev_opts = Code.compiler_options()
      # infer_signatures: false drops Elixir's type checker to :traverse mode
      # for the generated module — signature construction (Module.Types.Descr
      # tuple intersections) dominates compile time on tuple-literal-dense
      # generated code: one heavy defn measured 93s with, 63ms without.
      Code.compiler_options(ignore_module_conflict: true, infer_signatures: false)

      try do
        Module.create(mod, block, location || Macro.Env.location(__ENV__))
      after
        Code.compiler_options(prev_opts)
      end
    end)
  end
end
