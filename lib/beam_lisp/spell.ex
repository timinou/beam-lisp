defmodule BeamLisp.Spell do
  @moduledoc """
  Loading the `spell/` application from Elixir.

  `spell/src/spell/*.bl` holds the machinery the chat loop is built from —
  `spell.seam`, `spell.contract`, `spell.machine`, `spell.provider`, and the
  seed definition `spell.seed`. Elixir-side consumers (scripts, ExUnit suites)
  need those namespaces loaded before they can call into them.

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
  The absolute path to `spell/src`, resolved from the project root.

  Resolved against the app's own directory rather than `File.cwd!/0` so a
  script run from elsewhere still finds it.
  """
  def src_path do
    Path.join(project_root(), @src)
  end

  @doc """
  Ensure the spell namespaces are loaded, and return `:ok`.

  Idempotent: `Loader.ensure_loaded/1` is a no-op for an already-loaded ns, so
  calling this from every script and every test setup costs nothing after the
  first. Requires `BeamLisp.init/0` to have run.

  `nss` defaults to the machinery plus the seed. Pass an explicit list to load
  a subset (a provider test needs no view emitter).
  """
  def load!(nss \\ ~w(spell.seam spell.contract spell.machine spell.provider spell.seed)) do
    BeamLisp.Env.add_search_path(src_path())
    Enum.each(nss, &BeamLisp.Loader.ensure_loaded/1)
    :ok
  end

  @doc "Init the runtime AND load spell — the two-line preamble every consumer needs."
  def init!(nss \\ nil) do
    BeamLisp.init()
    if nss, do: load!(nss), else: load!()
  end

  # The app dir under _build is a symlink farm; Mix.Project gives the real
  # source root when available, and cwd is the honest fallback for a script
  # run through `mix run` from the project root.
  defp project_root do
    if function_exported?(Mix.Project, :deps_path, 0) and Mix.Project.get() do
      Path.dirname(Mix.Project.project_file())
    else
      File.cwd!()
    end
  rescue
    _ -> File.cwd!()
  end
end
