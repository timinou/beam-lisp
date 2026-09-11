defmodule BeamLisp.Model do
  @moduledoc """
  Where a *downloaded model* lives on this machine.

  ## Why this is not under `priv/`

  `priv/z3/` sets the precedent for a fetched binary, and it is the wrong one
  here for a reason that is a matter of arithmetic. A solver is ~50 MB and is
  fetched per checkout to match the pinned release. A static embedding model is
  the same 33 MB for every checkout, every project and every worktree on the
  box, and it is not *built* — it is *cached*. Copying it into each tree buys
  nothing and costs 33 MB each.

  So the model is ambient, like the AOT cache (`BeamLisp.AOTCache`) and the Cargo
  target dir: kept in the user cache, addressed by name, shared by everything
  that asks for it.

  ## One rule, two callers

  The `.bl` side (`code.embed`) and the Mix fetch task both need this path, and
  they must agree — a fetch into one directory and a load from another is a
  capability that silently reads as absent. So the rule lives here once and both
  call it: Elixir owns the filesystem question, beam-lisp owns what to do about
  the answer.
  """

  @env_dir "BEAM_LISP_MODEL_DIR"

  @doc """
  Root of the model cache: `$BEAM_LISP_MODEL_DIR`, else
  `$XDG_CACHE_HOME/beam_lisp/models`.

  Resolved PER CALL, never memoised: a test (or a fetch with `--dir`) sets the
  variable and expects the next call to see it. `BeamLisp.AOTCache` learned this
  the same way — a load-time `def` here would fix the directory for every later
  caller in the VM.
  """
  @spec root() :: String.t()
  def root do
    case System.get_env(@env_dir) do
      nil -> :filename.basedir(:user_cache, ~c"beam_lisp") |> Path.join("models")
      dir -> Path.expand(dir)
    end
  end

  @doc "The directory for the model named `name` (`minishlab/potion-code-16M-v2`)."
  @spec dir(String.t()) :: String.t()
  def dir(name), do: Path.join(root(), name)

  @doc "The env var that overrides `root/0`."
  @spec dir_env() :: String.t()
  def dir_env, do: @env_dir
end
