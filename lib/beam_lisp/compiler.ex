defmodule BeamLisp.Compiler do
  @moduledoc """
  The host-facing front door to the SELF-HOSTED beam-lisp compiler.

  beam-lisp's compiler is written in beam-lisp (`priv/boot/compiler.bl`). Once
  that source is AOT-compiled into `BeamLisp.Ns.Compiler`, THIS module is a thin
  facade that delegates every entry point to it — the language compiles itself.
  There is no Elixir genesis compiler behind these functions any more: the
  original hand-written lowering (`compile_elixir` + `compile_special/*`) has
  been DELETED. A genesis-less tree boots from the committed Core-Erlang seed
  (`priv/bootstrap/seed/`, installed by `BeamLisp.Bootstrap`), and a change to
  `compiler.bl` is bootstrapped by the PREVIOUS generation of the seed compiler
  (see `BeamLisp.Bootstrap.install!/1`'s staging path) — never by Elixir.

  Why keep this module at all, rather than call `BeamLisp.Ns.Compiler`
  directly? A stable, well-known name. Every caller across `lib/`, the tests,
  and the tooling types `BeamLisp.Compiler.eval_string/…`; the facade lets the
  IMPLEMENTATION live in `.bl` while the NAME stays put. The facade holds only
  target-agnostic host glue (the backend switch and the intern-from-beam step),
  no compiler semantics.

  Compile-time environment (built by `new_env/1`, threaded by the .bl compiler):

    * `:ns` — current namespace for var resolution
    * `:locals` — `%{name => Elixir AST var}`
    * `:recur` — `nil | %{self: var, arity: n}`, the innermost loop target
    * `:tail` — whether this position is a tail position

  Runtime values live in `BeamLisp.Env`.
  """

  alias BeamLisp.Env

  @compiler_ns BeamLisp.Ns.Compiler

  @doc "A fresh top-level compile-time environment for namespace `ns`."
  def new_env(ns \\ Env.current_ns()), do: apply(@compiler_ns, :new_env, [ns])

  @doc """
  Read, compile and evaluate every form in `source`. Returns the last value.

  `file` is the source path (or nil) attached to each form's position metadata,
  so generated modules and compile errors can name it. Delegates to the
  self-hosted `eval_string` in `priv/boot/compiler.bl`.
  """
  def eval_string(source, env \\ new_env(), file \\ nil) do
    apply(@compiler_ns, :eval_string, [source, env, file])
  end

  @doc """
  Compile one reader form to a value and evaluate it.

  The form is compiled into a throwaway module (not `erl_eval`-interpreted) so
  `loop`/`recur` keep real tail-call optimisation. Delegates to the self-hosted
  `eval_form`.
  """
  def eval_form(form, env), do: apply(@compiler_ns, :eval_form, [form, env])

  @doc """
  Compile one reader form to its Elixir/Core syntax tree.

  THE CUTOVER SEAM, now fully self-hosted: it delegates to `BeamLisp.Ns.Compiler`
  whenever the `compiler` namespace is interned (the normal state, from the seed
  or a fresh build). Before the compiler is interned on a from-source tree there
  is nothing to delegate to — but there is also no Elixir genesis fallback any
  more, so `enable_bl_backend/0` (run at boot, after the seed installs) MUST have
  interned it first. `:compiler_backend :bl` forces delegation; anything else
  still requires the ns to be interned.
  """
  def compile(form, env) do
    if use_bl_compiler?() do
      apply(@compiler_ns, :compile, [form, env])
    else
      raise """
      beam-lisp compiler not loaded: BeamLisp.Ns.Compiler is not interned, and
      the Elixir genesis compiler has been removed. The self-hosted compiler
      boots from the committed seed (priv/bootstrap/seed/) via
      BeamLisp.Bootstrap.install!/1 + BeamLisp.Compiler.enable_bl_backend/0.
      This usually means boot ran out of order (enable the backend before the
      first compile) or the seed is missing/corrupt.
      """
    end
  end

  @doc "Expand `form` once as a macro call in namespace `ns` (self-hosted)."
  def macroexpand_1(form, ns), do: apply(@compiler_ns, :macroexpand_1, [form, ns])

  @doc "Prelink a `defn`'s call surface for namespace `ns` (self-hosted)."
  def prelink_defn(form, ns), do: apply(@compiler_ns, :prelink_defn, [form, ns])

  @doc "Read ONE top-level form of `source` as runtime data (self-hosted)."
  def read_data(source) when is_binary(source),
    do: apply(@compiler_ns, :read_data, [source])

  @doc "Read EVERY top-level form of `source` as runtime data (self-hosted)."
  def read_all_data(source) when is_binary(source),
    do: apply(@compiler_ns, :read_all_data, [source])

  @doc "Restart this process's fresh-name counter (self-hosted)."
  def reset_fresh!, do: apply(@compiler_ns, :reset_fresh!, [])

  # --- boot glue: the backend switch + intern-from-beam (no compiler semantics) ---

  @doc """
  Whether to route `compile/2` through the self-hosted beam-lisp compiler.

  `:bl` forces it; `:genesis` is no longer meaningful (there is no genesis) and
  behaves like `:auto`; `:auto` delegates whenever the `compiler` namespace is
  interned in this node's Env — which it is once the seed installs and
  `enable_bl_backend/0` runs.
  """
  def use_bl_compiler? do
    case Application.get_env(:beam_lisp, :compiler_backend, :auto) do
      :bl -> true
      _ -> Env.loaded_ns?("compiler")
    end
  end

  @doc """
  Ensure the self-hosted beam-lisp compiler is ready to serve `compile/2`.

  Interns the `compiler` namespace from its beam (the committed seed on a fresh
  tree, or the freshly built beam otherwise) — running its `__bl_init__`, which
  replays the compiler's own `def` VALUES into the Env var table. No
  compilation, no genesis. Idempotent. Returns `:bl` when the self-hosted
  compiler is now active, `:genesis` (legacy label = "not active") otherwise.
  """
  def enable_bl_backend do
    unless Env.loaded_ns?("compiler") do
      BeamLisp.Loader.ensure_loaded("compiler")
    end

    if Env.loaded_ns?("compiler"), do: :bl, else: :genesis
  end
end
