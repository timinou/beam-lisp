defmodule BeamLisp.Multi do
  @moduledoc """
  Runtime engine for open dispatch: multimethods and protocols.

  Both live as plain vars in `BeamLisp.Env`'s `:beam_lisp_vars` table
  so ordinary call syntax finds them; the tables *behind* those vars
  are the open part — entries can be added, replaced or extended
  after the fact, which is exactly what open dispatch promises.

  Registry shapes (all under `:beam_lisp_vars`, so no new process and
  no collision with the `{ns, name}` var keys):

    * `{{:multi, ns, name}, %{dispatch: dfn, methods: %{key => mfn}}}`
      a multimethod's dispatch fn and its method table (`:default` key
      holds the fallback method).
    * `{{:hierarchy, ns}, %{child => [parents]}}` — the `derive` graph.
    * `{{{:protocol, ns, name, method}, type_tag}, mfn}` — a protocol
      method's per-type dispatch table.
    * `{{:protocol, ns, name}, %{methods: [names]}}` — the protocol
      descriptor's shape (what methods a complete extension must cover).

  Dispatch values are arbitrary beam-lisp values; the method table is
  keyed by `normalize_key/1` so structurally-equal values always hit
  the same entry regardless of representation (vectors especially).
  A method registered for the `:default` dispatch value is the
  fallback for any unmatched dispatch value, as in Clojure.

  The multi var itself holds a closure that re-enters `dispatch/3`,
  so a multimethod is a normal callable and re-defining it (Clojure's
  `defmulti` reuses the existing MultiFn, updating only the dispatch
  fn) preserves its methods — mirroring CLJ-1351.
  """

  alias BeamLisp.{Env, RT}

  @table :beam_lisp_vars

  # --- type tagging (the whole protocol abstraction) ---

  @doc """
  The one type tag every protocol dispatch keys on. Builtin value
  kinds map to keywords; Elixir structs map to their module (so
  interop structs are first-class extensible types). Returns an atom.
  """
  def type_of(v) when is_integer(v), do: :integer
  def type_of(v) when is_float(v), do: :float
  def type_of(v) when is_binary(v), do: :binary
  def type_of(v) when is_boolean(v), do: :boolean
  def type_of(nil), do: :nil
  def type_of(v) when is_atom(v), do: :keyword
  def type_of(v) when is_list(v), do: :list
  def type_of(%BeamLisp.Vector{}), do: :vector
  def type_of(%BeamLisp.LazySeq{}), do: :seq
  def type_of(%{__struct__: mod}) when is_atom(mod), do: mod
  def type_of(v) when is_map(v), do: :map
  def type_of(v) when is_function(v), do: :fn
  # A deftype instance is a tagged tuple carrying its module; it must
  # dispatch as that type, so this precedes the bare-tuple clause.
  def type_of({:bl_deftype, mod, _}) when is_atom(mod), do: mod
  def type_of(v) when is_tuple(v), do: :tuple
  def type_of(v) when is_pid(v), do: :pid
  def type_of(v) when is_reference(v), do: :reference

  # --- multimethods ---

  @doc "Normalize a dispatch value to a stable method-table key."
  def normalize_key(%BeamLisp.Vector{} = v), do: {:"bl-vector", Enum.to_list(v)}
  def normalize_key(v), do: v

  @doc """
  Define (or redefine) a multimethod. Interns `name` in `ns` as a
  callable whose call applies `dispatch_fn` to all args and runs the
  matching method.

  Mirroring Clojure (CLJ-1351), re-defining an existing multimethod
  reuses its method table and only swaps the dispatch fn — the other
  methods survive.
  """
  def define_multi(ns, name, dispatch_fn) do
    key = {:multi, ns, name}

    entry =
      case :ets.lookup(@table, key) do
        [{_, %{methods: methods}}] ->
          %{dispatch: dispatch_fn, methods: methods}

        [] ->
          %{dispatch: dispatch_fn, methods: %{}}
      end

    :ets.insert(@table, {key, entry})
    # RT.invoke spreads call args over the fn's parameters (apply/2),
    # so a fixed-arity closure would only ever see one arg. A tagged
    # variadic value ({min, f} with min 0) makes RT.invoke hand the fn
    # the whole args list instead, so any arity reaches dispatch/3.
    # The ns/name it closes over are stable per multi, so re-definition
    # simply re-interns a fresh value over the same key.
    Env.intern(ns, name, {:"$blfn", %{}, {0, fn args -> dispatch(ns, name, args) end}})
  end

  @doc "Add or replace the method for `dispatch_val` on the multi `ns/name`."
  def add_method(ns, name, dispatch_val, method_fn) do
    key = {:multi, ns, name}
    entry = multi!(ns, name)

    methods =
      Map.put(entry.methods, normalize_key(dispatch_val), method_fn)

    :ets.insert(@table, {key, %{entry | methods: methods}})
    method_fn
  end

  @doc """
  Run a multimethod: apply its dispatch fn to `args`, look up the
  method by the normalized result, falling back to the `:default`
  method when there is one. No match and no default raises a clear
  error naming the multi and the dispatch value.
  """
  def dispatch(ns, name, args) do
    entry = multi!(ns, name)
    key = normalize_key(RT.invoke(entry.dispatch, args))

    case Map.fetch(entry.methods, key) do
      {:ok, mfn} ->
        RT.invoke(mfn, args)

      :error ->
        # Clojure's `isa?` dispatch: a dispatch value derived from a
        # registered method key still hits that method, before the
        # `:default` fallback.
        method_keys = Map.keys(entry.methods)

        case Enum.find(method_keys, &isa?(ns, key, &1)) do
          nil ->
            case Map.fetch(entry.methods, :default) do
              {:ok, mfn} -> RT.invoke(mfn, args)
              :error -> raise no_method_error(ns, name, key)
            end

          k ->
            RT.invoke(Map.fetch!(entry.methods, k), args)
        end
    end
  end

  defp multi!(ns, name) do
    case :ets.lookup(@table, {:multi, ns, name}) do
      [{_, entry}] -> entry
      [] -> raise "No multimethod named #{ns}/#{name} — defmulti it before adding methods"
    end
  end

  defp no_method_error(ns, name, key) do
    "No method in multimethod #{ns}/#{name} for dispatch value: #{inspect(key)}"
  end

  # --- hierarchies (derive/isa?) ---

  @doc "Record `child` as derived from `parent` in ns's hierarchy. Returns true."
  def derive(ns, child, parent) do
    parents =
      case :ets.lookup(@table, {:hierarchy, ns}) do
        [{_, h}] ->
          Map.update(h, child, [parent], &[parent | Enum.reject(&1, fn p -> p == parent end)])

        [] ->
          %{child => [parent]}
      end

    :ets.insert(@table, {{:hierarchy, ns}, parents})
    true
  end

  @doc "Direct parents of `x` in ns's hierarchy."
  def parents(ns, x) do
    case :ets.lookup(@table, {:hierarchy, ns}) do
      [{_, h}] -> Map.get(h, x, [])
      [] -> []
    end
  end

  @doc "All transitive ancestors of `x` in ns's hierarchy."
  def ancestors(ns, x), do: walk_ancestors(ns, x, MapSet.new())

  defp walk_ancestors(ns, x, seen) do
    ps = parents(ns, x)

    Enum.reduce(ps, MapSet.new(), fn p, acc ->
      if MapSet.member?(seen, p) or MapSet.member?(acc, p) do
        acc
      else
        MapSet.union(acc, MapSet.put(walk_ancestors(ns, p, MapSet.put(seen, x)), p))
      end
    end)
  end

  @doc """
  True when `x` is `y` or transitively derived from `y` in ns's
  hierarchy — the relation a multimethod could consult after an exact
  dispatch-value match fails (Clojure's `isa?` dispatch semantics).
  """
  def isa?(_ns, x, y) when x == y, do: true

  def isa?(ns, x, y) do
    Enum.any?(ancestors(ns, x), &(&1 == y))
  end

  @doc "Remove `child`'s derivation from `parent` in ns's hierarchy. Returns false."
  def underive(ns, child, parent) do
    case :ets.lookup(@table, {:hierarchy, ns}) do
      [{_, h}] when is_map_key(h, child) ->
        rest = Enum.reject(Map.get(h, child), &(&1 == parent))
        h = if rest == [], do: Map.delete(h, child), else: Map.put(h, child, rest)
        :ets.insert(@table, {{:hierarchy, ns}, h})

      _ ->
        :ok
    end

    false
  end

  # --- protocols ---

  @doc """
  Define a protocol: intern `name` in `ns` as a descriptor var, and
  intern each method as a callable var that dispatches on the type
  tag of its first argument (via `type_of/1`).
  """
  def define_protocol(ns, name, method_names) do
    :ets.insert(@table, {{:protocol, ns, name}, %{methods: method_names}})
    Env.intern(ns, name, {:"$protocol", ns, name, method_names})

    for method <- method_names do
      Env.intern(ns, method, {:"$blfn", %{}, {0, fn args -> dispatch_protocol(ns, name, method, args) end}})
    end
  end

  @doc """
  Extend `type_tag` with implementations of a protocol's methods.
  `impls` maps method name => fn. Adding a method that already exists
  for the type replaces it; other types' entries are untouched.
  """
  def extend_type(ns, protocol, type_tag, impls) do
    proto = protocol!(ns, protocol)

    # Every method the protocol declares must be covered, else a later
    # call silently misses; catch that at extension time.
    missing = Enum.reject(proto.methods, &Map.has_key?(impls, &1))

    if missing != [] do
      raise "extend-type #{ns}/#{protocol} for #{inspect(type_tag)} is missing methods: #{inspect(missing)}"
    end

    for {method, fn_value} <- impls do
      key = {{:protocol, ns, protocol, method}, type_tag}
      :ets.insert(@table, {key, fn_value})
    end

    :ok
  end

  @doc "Dispatch a protocol method on the first argument's type tag."
  def dispatch_protocol(ns, protocol, method, args) do
    tag = type_of(hd(args))
    key = {{:protocol, ns, protocol, method}, tag}

    case :ets.lookup(@table, key) do
      [{_, mfn}] ->
        RT.invoke(mfn, args)

      [] ->
        raise "No implementation of method #{method} of protocol #{ns}/#{protocol} for type #{inspect(tag)}"
    end
  end

  defp protocol!(ns, name) do
    case :ets.lookup(@table, {:protocol, ns, name}) do
      [{_, desc}] -> desc
      [] -> raise "No protocol named #{ns}/#{name} — defprotocol it before extending"
    end
  end
end
