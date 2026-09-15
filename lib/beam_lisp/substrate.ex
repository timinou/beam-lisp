defmodule BeamLisp.Substrate do
  @moduledoc """
  The Elixir SUBSTRATE stage, delegated to the language:
  `priv/build/substrate.bl`.

  `mix compile` builds two things — the Elixir sources in `lib/` with mix's own
  `:elixir` compiler, and the `.bl` sources with this project's compiler task.
  The drop must do both with no Mix project, no `_build` and no `MIX_ENV`, and
  Elixir's compiler plus `Kernel.ParallelCompiler` ship in the payload, so the
  substrate is just another stage: same plan, same output directory, same fact
  log as the AOT waves (`[:build/ex path content-hash [modules]]`).

  Freshness is the content hash; the module list is recorded so a beam that
  vanished pulls its source back into the build. One batch compile — the
  parallel compiler resolves cross-file dependencies itself — still yields a
  fact per file, because every compiled module reports the file it came from.

  Like `BeamLisp.BuildPlan` and `BeamLisp.BuildLog`, this is the Elixir call
  surface; the logic is in `priv/build/substrate.bl`. Requires the runtime
  (`BeamLisp.init/0` done).
  """

  @ns "substrate"

  @doc """
  Every `.ex` under `root`, minus anything under an entry of `exclude`
  (relative paths, e.g. `["lib/dev", "lib/mix"]`), sorted.
  """
  @spec sources(binary, [binary]) :: [binary]
  def sources(root, exclude) when is_binary(root) and is_list(exclude),
    do: call("sources", [root, exclude])

  @doc """
  The sources in `paths` the log cannot vouch for (see `BeamLisp.BuildLog.state/1`):
  no fact, a different content hash, or a beam their fact names that is gone.
  """
  @spec stale(map, [binary], binary) :: [binary]
  def stale(state, paths, out), do: call("stale", [state, paths, out])

  @doc """
  Compile `paths` into `out` as one batch.

  Returns `%{compiled: n, facts: [fact], errors: [msg]}`. The CALLER appends the
  facts: the build owns the log's ordering, and there is one writer. A failed
  batch returns no facts, so the sources stay stale and the next run retries.
  """
  @spec compile!([binary], binary) :: map
  def compile!(paths, out), do: call("compile!", [paths, out])

  defp call(name, args) do
    BeamLisp.Loader.ensure_loaded(@ns)
    BeamLisp.RT.invoke(BeamLisp.Env.fetch!(@ns, name), args)
  end
end
