defmodule BeamLisp.Image do
  @moduledoc """
  What kind of image this is: `"dev"`, `"release"` or `"drop"`.

  The question "am I in a development image?" used to be answered by asking
  whether `Mix` was loaded. That answer stops existing the day Mix is deleted —
  and worse, it fails in the direction that hurts: a development image would
  start looking like production, so `reload` would refuse to mutate it and the
  dev server would not start.

  So the kind is DECLARED by whoever built the image, and read from there:

    * `BL_BIN` set — a drop. Its Rust launcher names the compound it runs from.
    * `BEAM_LISP_IMAGE` set — a release; the shell launcher states its kind.
    * neither — a plain VM: `bl` from a checkout, a test run, CI.

  `BEAM_LISP_DEV=1` forces `"dev"` whatever the image, which is how a tree
  declares itself: `bl` puts a project file's `:env` into the real environment
  before a command runs, so `env.bl` can say `{:env {"BEAM_LISP_DEV" "1"}}`.

  This is the ONE implementation of the rule. `reload` (in bl) and the
  application's dev-server decision (in Elixir) both call it, because two copies
  of a signal are two signals.
  """

  @doc "The image kind: `\"dev\"`, `\"release\"` or `\"drop\"`."
  @spec kind() :: String.t()
  def kind do
    cond do
      dev_forced?() -> "dev"
      System.get_env("BL_BIN") -> "drop"
      System.get_env("BEAM_LISP_IMAGE") -> System.get_env("BEAM_LISP_IMAGE")
      true -> "dev"
    end
  end

  @doc "Whether this is a development image — the question callers actually ask."
  @spec dev?() :: boolean
  def dev?, do: kind() == "dev"

  @doc """
  Whether a packaged image (release or drop) may mutate itself. `BEAM_LISP_RELOAD`
  is the operator's opt-in, per node, with a bounded window.
  """
  @spec mutable?() :: boolean
  def mutable? do
    dev?() or System.get_env("BEAM_LISP_RELOAD") in ["1", "true"]
  end

  defp dev_forced?, do: System.get_env("BEAM_LISP_DEV") in ["1", "true"]
end
