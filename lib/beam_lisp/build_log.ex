defmodule BeamLisp.BuildLog do
  @moduledoc """
  The build's FACT LOG, delegated to the language: `priv/build/build-log.bl`.

  The build's memory used to be one document — the manifest — rewritten after
  every source. It is now a log of facts: one appended line per source, in the
  language's own data syntax, replayed into a state. The manifest Mix reads is
  a PROJECTION of that state (`manifest/1`), so the two cannot disagree, and
  the log answers what the manifest never could:

    * `stale/3` — the sources a build would have to recompile, in plan order
      (the build's own worklist; `bl build --status` is this).
    * `impact/2` — everything that depends on a source, transitively. The
      reverse of the plan's `:deps`.
    * `coverage/3` — how much of the plan the log accounts for.

  Like `BeamLisp.BuildPlan`, this is the Elixir call surface over a beam-lisp
  program: the logic is in `priv/build/build-log.bl`. Requires the runtime
  (`BeamLisp.init/0` done).
  """

  @ns "build-log"

  # `is_map/1` is true for every struct, and beam-lisp has eleven struct types
  # that must never take a map path here — a Vector state would be walked as a
  # map and answered silently wrong. `is_bl_map/1` is the guard that means "a
  # beam-lisp map" (a host map that is not a struct).
  import BeamLisp.Guards, only: [is_bl_map: 1]

  @doc "The log that belongs to a manifest: `build.log` beside the manifest."
  @spec path_for(binary) :: binary
  def path_for(manifest_path) when is_binary(manifest_path), do: call("path-for", [manifest_path])

  @doc "Every fact in the log at `path`, oldest first. `[]` when there is no log."
  @spec facts(binary) :: [list]
  def facts(log_path) when is_binary(log_path), do: call("read-facts", [log_path])

  @doc """
  The build's state, folded from the log at `path` (last fact about a path
  wins): `%{sources: %{path => entry}, runs: [...], errors: [...], ended: %{...}}`.
  """
  @spec state(binary) :: map
  def state(log_path) when is_binary(log_path), do: call("replay", [facts(log_path)])

  @doc "The manifest projection of `state` — the document Mix reads."
  @spec manifest(map) :: map
  def manifest(state) when is_bl_map(state), do: call("manifest", [state])

  @doc """
  Is `path` fresh in `state`: recorded under `key` and `tier`, every beam on
  disk? `key` is the plan's per-source key, `tier` is
  `BeamLisp.AOTCache.key_for_source/1` — the same values the build compares.
  """
  @spec fresh?(map, binary, binary | nil, binary, binary) :: boolean
  def fresh?(state, path, key, tier, out),
    do: call("fresh?", [state, path, key, tier, out])

  @doc "The plan's sources `state` cannot vouch for, in plan order."
  @spec stale(BeamLisp.BuildPlan.plan(), map, binary) :: [binary]
  def stale(plan, state, out), do: call("stale", [plan, state, out])

  @doc """
  Everything that depends on `path`, transitively, in discovery order — the
  reverse closure of the plan's `:deps`. `path` itself is excluded.
  """
  @spec impact(BeamLisp.BuildPlan.plan(), binary) :: [binary]
  def impact(plan, path), do: call("impact", [plan, path])

  @doc "How much of the plan the log accounts for (`:sources`, `:fresh`, `:stale`, `:recorded`)."
  @spec coverage(BeamLisp.BuildPlan.plan(), map, binary) :: map
  def coverage(plan, state, out), do: call("coverage", [plan, state, out])

  defp call(name, args) do
    BeamLisp.Loader.ensure_loaded(@ns)
    BeamLisp.RT.invoke(BeamLisp.Env.fetch!(@ns, name), args)
  end
end
