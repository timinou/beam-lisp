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
    key_for = BeamLisp.Env.fetch!(@ns, "key-for")

    # The committed bootstrap seed may carry the previous generation of
    # `build-plan`, whose `key-for` is 3-ary (no `node-of`). The build that
    # re-emits the boot tier runs THROUGH that seed, so this call must work
    # against both generations: memoized when the language offers it, plain
    # otherwise. Once the seed is re-blessed the fallback is never taken.
    if BeamLisp.RT.invocable?(key_for, 4),
      do: BeamLisp.RT.invoke(key_for, [ns, resolve, seed_arg, &memo_node/2]),
      else: BeamLisp.RT.invoke(key_for, [ns, resolve, seed_arg])
  end

  # ── the node memo ──────────────────────────────────────────────────────────
  #
  # A plan node is a PURE function of a source's bytes: forms, header, interface
  # hash, interface names, references. The runtime drift gate asks `key_for`
  # once per namespace it vets, and each call walks that namespace's whole
  # require-closure — so the same ninety files were read and parsed ninety
  # times over. Measured on a ninety-namespace application: 71.7s of a 72.5s
  # load was this gate; the beams' own `__bl_init__` replay was under a
  # second. Keying the memo on the CONTENT HASH (never the path, never mtime)
  # keeps the gate's guarantee intact: an edited file has new bytes, a new
  # key, and is parsed afresh; the closure key is still folded from live bytes
  # on every call. Only the parse is shared.
  #
  # VM-wide, owned by the pinned `Loader.Server` (the same rule as the
  # native-declarations and lazy-seq tables): created lazily by the first
  # caller, it must outlive that caller — a parallel-build worker exits after
  # its one file.
  @memo :beam_lisp_build_plan_nodes

  @doc """
  `node-from` memoized by content hash. `ns` is what the node records as
  its `:path` (the gate uses the namespace name); a memo hit for the same
  bytes under another name is re-labelled, not re-parsed.
  """
  def memo_node(ns, content) when is_binary(ns) and is_binary(content) do
    hash = :crypto.hash(:sha256, content)

    node =
      case :ets.lookup(memo_table(), hash) do
        [{^hash, node}] ->
          node

        [] ->
          node =
            BeamLisp.RT.invoke(BeamLisp.Env.fetch!(@ns, "node-from"), [ns, content])

          :ets.insert(memo_table(), {hash, node})
          node
      end

    Map.put(node, :path, ns)
  end

  @doc "Forget every memoized node (tests; a toolchain change rotates the parse)."
  def clear_memo do
    case :ets.whereis(@memo) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@memo)
    end

    :ok
  end

  defp memo_table do
    case :ets.whereis(@memo) do
      :undefined ->
        BeamLisp.Loader.Server.run(fn ->
          try do
            :ets.new(@memo, [:named_table, :public, :set, read_concurrency: true])
          rescue
            # Another process won the race; its table is the one we want.
            ArgumentError -> :ok
          end
        end)

        @memo

      _ ->
        @memo
    end
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
