defmodule BeamLisp.CompilerOptions do
  @moduledoc """
  The Elixir compiler options beam-lisp's emitters need, set ONCE for the VM.

  Every emitter — `Module.create` in `BeamLisp.Emit`, the eval module in
  `BeamLisp.Compiler.eval_form/2`, the AOT block compiler, `defrecord`,
  `defserver` — needs the same two options:

    * `ignore_module_conflict: true` — redefinition is the normal case (hot
      reload, a var redefined at the REPL, two loaders of one multi-ns file),
      and the warning is noise.
    * `infer_signatures: false` — drops Elixir's type checker to `:traverse`
      mode for generated code. Signature construction (`Module.Types.Descr`
      tuple intersections) dominates compile time on tuple-literal-dense
      generated modules: one heavy defn measured 93s with, 63ms without.

  `Code.compiler_options/1` is a VM-WIDE cell (a `:persistent_term` behind
  `:elixir_config`). The historical pattern — read the options, set ours, do
  the work, restore the previous — is a read-modify-write with no lock, and
  under a parallel build it interleaves:

      A: prev = %{ignore: false}          B: prev = %{ignore: false}
      A: set ignore: true                 B: set ignore: true
      A: Module.create … restore → false  B: Module.create ← conflict raised
                                          B: restore → false

  Or worse, an emitter that reads the cell between A's set and A's restore
  "restores" `infer_signatures: true` for everyone, and the next dense module
  spins for minutes. The symptom in the wave build was a var going missing
  (`undefined var: compiler/quoted-datum`): a body module purged by a
  conflicting redefinition that only ran because the flag was momentarily off.

  So there is no restore. Set the options once, keep them for the life of the
  VM, and make every emitter idempotently ensure they are set. Nothing in
  beam-lisp wants the defaults back: the runtime never compiles Elixir source
  through `Code.compile_*` where the type checker's signatures would matter,
  and `mix compile`'s own Elixir pass runs BEFORE the beam-lisp compiler with
  its own options (the Mix compiler sets them per run, not from this cell).
  """

  @opts [ignore_module_conflict: true, infer_signatures: false]
  @flag {__MODULE__, :set}

  @doc "Set the options if this VM has not yet. Cheap after the first call."
  def ensure! do
    unless :persistent_term.get(@flag, false) do
      Code.compiler_options(@opts)
      :persistent_term.put(@flag, true)
    end

    :ok
  end
end
