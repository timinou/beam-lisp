defmodule BeamLisp.Spell do
  @moduledoc """
  Loading the `spell/` application from Elixir.

  `spell/src/spell/*.bl` holds the machinery the live machine is built from —
  `spell.seam`, `spell.contract`, `spell.machine`, and the default shell
  (`spell.seed`, `spell.live-state`). Elixir-side consumers (scripts, ExUnit
  suites) need those namespaces loaded before they can call into them.

  This exists so exactly ONE place knows where spell lives. The previous shape
  was `for f <- ~w(seam contract chat), do: eval_string(File.read!("priv/\#{f}.bl"))`
  repeated in four files: a hand-maintained dependency ORDER (seam before
  contract, or contract's require fails) duplicated per call site. Moving the
  files broke all four independently. Requiring by NAMESPACE instead of by path
  hands the ordering to the loader, which already computes it from the
  `(:require …)` forms — the dependency graph is in the source, so nothing here
  needs to know that contract depends on seam.
  """

  @src "spell/src"

  @doc """
  The absolute path to `spell/src`.

  Resolved from the Mix project's own file when running under Mix (correct even
  when the task is invoked from a subdirectory), and from cwd otherwise. It is
  deliberately NOT resolved from `Application.app_dir/1`: under `_build` that is
  a symlink farm containing compiled artefacts, not the `spell/` source tree.

  Consequence worth naming: this locates the spell application inside THIS
  checkout. A release or an escript that vendored beam-lisp would need its own
  path (`BEAM_LISP_PATH`, or `Env.add_search_path/1` directly) — which is why
  those affordances exist and this one is a convenience over them, not the only
  way in.
  """
  def src_path do
    Path.join(project_root(), @src)
  end

  @doc """
  Ensure the spell namespaces are loaded, and return `:ok`.

  Idempotent: `Loader.ensure_loaded/1` is a no-op for an already-loaded ns, so
  calling this from every script and every test setup costs nothing after the
  first. Requires `BeamLisp.init/0` to have run.

  With no argument it loads `spell.app`, the application's MANIFEST namespace,
  whose `(:require …)` head names the modules that make up spell. That is one
  list, in beam-lisp, next to the code it describes — rather than a list of
  namespace strings here in Elixir that a later wave must remember to update.
  Globbing `spell/src/spell/*.bl` was the other candidate and is worse: it
  would load whatever happens to be on disk, including a scratch file, and it
  would decide load ORDER by filename.

  Pass an explicit list to load a subset — a provider test needs no view
  emitter, and loading less keeps a unit test's failure surface small.
  """
  def load!(nss \\ ["spell.app"]) do
    BeamLisp.Env.add_search_path(src_path())
    Enum.each(nss, &BeamLisp.Loader.ensure_loaded/1)
    :ok
  end

  @doc "Init the runtime AND load spell — the two-line preamble every consumer needs."
  def init!(nss \\ nil) do
    BeamLisp.init()
    if nss, do: load!(nss), else: load!()
  end

  # Under Mix, the project file's directory is the checkout root regardless of
  # where the task was invoked from. `Mix.Project.get()` returns nil when no
  # project is loaded (escript, release, plain iex), and Mix may not be loaded
  # at all — hence the availability check on Mix.Project itself rather than on
  # an unrelated function. No rescue: a raise here would mean Mix is loaded,
  # claims a project, and cannot say where it is, which is a broken assumption
  # worth surfacing rather than silently degrading to cwd.
  defp project_root do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get() do
      Path.dirname(Mix.Project.project_file())
    else
      File.cwd!()
    end
  end
end
