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
  becomes a node via `BeamLisp.SourceGraph.header/1` and a sha256 of its bytes.
  """
  @spec plan_paths([binary]) :: plan
  def plan_paths(paths) do
    paths
    |> Enum.map(fn path ->
      content = File.read!(path)
      {ns, reqs} = BeamLisp.SourceGraph.header(content)
      %{path: path, ns: ns, reqs: reqs, hash: content_hash(content)}
    end)
    |> plan()
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

  @doc "sha256 (upper hex) of a source's bytes — the leaf hash every key folds."
  def content_hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16()
end
