defmodule BeamLisp.BuildPlan do
  @moduledoc """
  The build plan, delegated to the language: `priv/boot/build-plan.bl`.

  One post-order traversal of the namespace graph yields everything the build
  needs — topological order, per-source closure key, dependency paths, and
  the DAG's waves — in O(V + E). This module is the Elixir call surface, the
  same seam shape as `BeamLisp.SourceGraph`.

  Requires the runtime (`BeamLisp.init/0` done).
  """

  @ns "build-plan"

  @type node_ :: %{path: binary, ns: binary | nil, reqs: [binary], hash: binary}
  @type plan :: %{
          order: [node_],
          waves: [[node_]],
          closure: %{binary => [binary]},
          key: %{binary => binary},
          deps: %{binary => [binary]}
        }

  @doc """
  Read every source once and plan the build. `paths` are source files; each
  becomes a node via `node-from` (header, content hash, interface hash, the
  names the interface covers, and the file's references into each required
  ns) — the same node the runtime gate builds, so build and gate agree.
  """
  @spec plan_paths([binary]) :: plan
  def plan_paths(paths) do
    BeamLisp.Loader.ensure_loaded(@ns)
    node_from = BeamLisp.Env.fetch!(@ns, "node-from")

    paths
    |> Enum.map(fn path -> BeamLisp.RT.invoke(node_from, [path, BeamLisp.Loader.read_source(path)]) end)
    |> plan()
  end

  @doc """
  The freshness key of one namespace, resolved by name — what the runtime
  drift gate compares to a beam's stamp and what emit stamps. `resolve.(ns)`
  returns a namespace's source content or `nil`; `seed` is an optional
  `{ns, content}` for the primary ns when its file is known but may not
  resolve by name (the emit path). `nil` when `ns` itself does not resolve.

  ONE definition of the key (`build-plan/key-for` → `plan`), two callers.
  """
  @spec key_for(binary, (binary -> binary | nil), {binary, binary} | nil) :: binary | nil
  def key_for(ns, resolve, seed \\ nil) when is_binary(ns) and is_function(resolve, 1) do
    BeamLisp.Loader.ensure_loaded(@ns)
    seed_arg = if seed, do: [elem(seed, 0), elem(seed, 1)], else: nil
    BeamLisp.RT.invoke(BeamLisp.Env.fetch!(@ns, "key-for"), [ns, resolve, seed_arg])
  end

  @doc "Plan from already-built nodes (see `t:node_/0`)."
  @spec plan([node_]) :: plan
  def plan(nodes) do
    BeamLisp.Loader.ensure_loaded(@ns)
    raw = BeamLisp.RT.invoke(BeamLisp.Env.fetch!(@ns, "plan"), [nodes])

    %{
      order: raw[:order],
      waves: raw[:waves],
      closure: raw[:closure],
      key: raw[:key],
      deps: raw[:deps]
    }
  end

end
