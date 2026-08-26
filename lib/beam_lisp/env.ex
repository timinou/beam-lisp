defmodule BeamLisp.Env do
  @moduledoc """
  The var registry.

  Vars live in a public ETS table keyed `{ns, name}`: reads are
  lock-free and happen in the caller's process, which keeps compiled
  code fast and free of a global message bottleneck. Namespace and
  bootstrap state (small, compile-time only) stays in the Agent,
  which also owns the table.

  Unqualified lookups fall back to `core`, mirroring how jank and
  Clojure refer `clojure.core` into every namespace.
  """

  use Agent

  @table :beam_lisp_vars

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        :ets.new(@table, [:named_table, :public, read_concurrency: true])
        %{ns: "user", seeded: false, loaded: MapSet.new(), load_paths: [], search_paths: []}
      end,
      name: __MODULE__
    )
  end

  @doc "The namespace new defs land in."
  def current_ns, do: Agent.get(__MODULE__, & &1.ns)

  def in_ns(ns) when is_binary(ns), do: Agent.update(__MODULE__, &%{&1 | ns: ns})

  @doc "Bind `name` to `value` in `ns`. Returns the value, like Clojure's def returns the var root."
  def intern(ns, name, value) do
    :ets.insert(@table, {{ns, name}, value})
    value
  end

  @doc """
  Resolve `name`, looking in `ns` first, then referred vars, and
  falling back to `core` (mirroring how jank and Clojure refer
  `clojure.core` into every namespace).

  A name containing a `/` is split into `{ns, var}`; if the prefix
  is an alias in `ns`, it resolves to the alias target instead.
  """
  def fetch(ns, name) do
    Enum.find_value(candidates(ns, name), :error, fn key ->
      case :ets.lookup(@table, key) do
        [{^key, value}] -> {:ok, value}
        [] -> nil
      end
    end)
  end

  # The candidate `{ns, name}` pairs a lookup should try, in order:
  # the namespace itself, then referred vars, then `core` (mirroring
  # how jank and Clojure refer `clojure.core` into every namespace).
  # A name containing a `/` splits into `{ns, var}`; if the prefix is
  # an alias in `ns`, it resolves to the alias target instead. A
  # leading slash (`/`, `/x`) is part of the var name itself.
  defp candidates(ns, name) do
    case String.split(name, "/", parts: 2) do
      ["" | _] ->
        [{ns, name}] ++ refer_candidate(ns, name) ++ [{"core", name}, {"sugar", name}]

      [prefix, var_name] ->
        [{alias_target(ns, prefix) || prefix, var_name}]

      [plain] ->
        [{ns, plain}] ++ refer_candidate(ns, plain) ++ [{"core", plain}, {"sugar", plain}]
    end
  end

  @doc "Record `alias` as shorthand for `target` inside `ns`."
  def add_alias(ns, alias_, target) do
    :ets.insert(@table, {{:alias, ns, alias_}, target})
    :ok
  end

  @doc "The namespace `alias` points to inside `ns`, if any."
  def alias_target(ns, alias_) do
    case :ets.lookup(@table, {:alias, ns, alias_}) do
      [{_, target}] -> target
      [] -> nil
    end
  end

  @doc """
  Every public var name interned in `ns`.

  Backs `(:require [ns :refer :all])`. Private vars are filtered here
  rather than at the refer site, so the blanket form can never smuggle
  in a name that the explicit `:refer […]` form would have refused.
  """
  def public_names(ns) do
    @table
    |> :ets.match({{ns, :"$1"}, :_})
    |> List.flatten()
    |> Enum.reject(fn name -> match?({:ok, %{private: true}}, meta(ns, name)) end)
  end

  @doc "Refer `name` into `ns` so it resolves bare, as if defined there."
  def add_refer(ns, name, source_ns) do
    :ets.insert(@table, {{:refer, ns, name}, source_ns})
    :ok
  end

  @doc """
  Refer every public var of `source_ns` into `ns`.

  A snapshot taken when the `(ns …)` form runs, exactly as Clojure's
  `:refer :all` is: vars interned in the source afterwards do not
  appear. This has to run *after* the require has loaded the source,
  which is why it is a runtime op rather than a compile-time expansion.
  """
  def add_refer_all(ns, source_ns) do
    for name <- public_names(source_ns), do: add_refer(ns, name, source_ns)
    :ok
  end

  @doc """
  True when `name` is interned in `ns` itself — no refer, alias or
  core fallback consulted.

  `fetch/2` deliberately searches all of those; a resolver asking "is
  this name local, or does it belong to somebody else?" needs the
  narrow question.
  """
  def local_var?(ns, name) do
    :ets.member(@table, {ns, name})
  end

  @doc """
  The namespace `name` was referred into `ns` from, or nil.

  Var lookup consults refers automatically; the compile-time resolvers
  for protocol and multimethod targets have to ask, because they need
  the owning namespace rather than the value.
  """
  def refer_source(ns, name) do
    case :ets.lookup(@table, {:refer, ns, name}) do
      [{_, source}] -> source
      [] -> nil
    end
  end

  defp refer_candidate(ns, name) do
    case refer_source(ns, name) do
      nil -> []
      source -> [{source, name}]
    end
  end

  @doc """
  Record that `ns` exists, independently of whether anything is
  interned in it yet.

  A namespace is brought into being by `(ns …)`, not by its first
  `def`. Inferring existence from "has at least one var" made an empty
  or not-yet-populated namespace unrequirable, which is the ordinary
  shape of a file whose forms have not run yet, of a namespace holding
  only macros, and of any two namespaces that refer to each other.
  """
  def declare_ns(ns) when is_binary(ns) do
    :ets.insert(@table, {{:ns, ns}, true})
    :ok
  end

  @doc """
  True when `ns` has been declared by an `(ns …)` form, or has any var
  interned in it.

  The second half keeps namespaces created by other routes — `in_ns`,
  direct `intern`, the prelude's seeding — visible without each having
  to announce itself.
  """
  def ns_exists?(ns) do
    case :ets.lookup(@table, {:ns, ns}) do
      [{_, true}] ->
        true

      [] ->
        case :ets.match(@table, {{ns, :_}, :_}, 1) do
          {[_], _} -> true
          _ -> false
        end
    end
  end

  def loaded_ns?(ns), do: Agent.get(__MODULE__, &MapSet.member?(&1.loaded, ns))
  def mark_loaded(ns), do: Agent.update(__MODULE__, &%{&1 | loaded: MapSet.put(&1.loaded, ns)})

  # --- var linking (BeamLisp.Link) ---
  # fn vars also live as named functions in a per-ns module; the
  # registry below lets call sites compile to direct remote calls.

  @doc "The def entries `{name => [{kind, arity, fname, def_ast}]}` backing ns's module."
  def ns_defs(ns) do
    case :ets.lookup(@table, {:ns_defs, ns}) do
      [{_, defs}] -> defs
      [] -> %{}
    end
  end

  def put_ns_defs(ns, defs), do: :ets.insert(@table, {{:ns_defs, ns}, defs})

  @doc """
  Every namespace that exists: defined something OR declared by `(ns …)`.

  Used to resolve a bare name when the current namespace is not the one
  that defines it — `current_ns/0` is process-global and outlives any
  single evaluation, so it is a hint rather than an answer.

  Declared namespaces are included because a namespace of plain `def`s has
  no `ns_defs` entry at all — `ns_defs` backs compiled `defn`s — so the
  narrower reading made a loaded, populated namespace invisible to anyone
  asking "what is loaded?" (the live-environment panel found exactly that:
  a contract-only namespace did not appear in its own listing).
  """
  def namespaces do
    defined = :ets.select(@table, [{{{:ns_defs, :"$1"}, :_}, [], [:"$1"]}])
    declared = :ets.select(@table, [{{{:ns, :"$1"}, :_}, [], [:"$1"]}])
    Enum.uniq(defined ++ declared)
  end

  @doc "Register link metadata `{module, %{arity => fname}, {min, vfname} | nil}` for a fn var."
  def put_link(ns, name, info), do: :ets.insert(@table, {{:link, ns, name}, info})

  @doc "Resolve link metadata with the same alias/refer/core rules as fetch/2."
  def link(ns, name) do
    Enum.find_value(candidates(ns, name), :error, fn {cns, cname} ->
      case :ets.lookup(@table, {:link, cns, cname}) do
        [{_, info}] -> {:ok, info}
        [] -> nil
      end
    end)
  end

  @doc """
  Record `meta` (a map) for `name` in `ns`. This is the general var
  metadata mechanism — `%{doc: "…"}`, `%{private: true}`,
  `%{dynamic: true}` and any other Clojure metadata keys all live in
  the one map. Writes **merge**: redefining a var with a new docstring
  keeps keys set earlier (so `:private` set on the first def survives a
  later doc-only redefinition) and the latest value wins per key.
  Returns `:ok`.
  """
  # is_map-ok: meta is the internal var-metadata map (compiler/REPL side
  # channel), never a user collection — structs are legitimate here.
  def put_meta(ns, name, meta) when is_map(meta) do
    merged =
      case :ets.lookup(@table, {:meta, ns, name}) do
        # is_map-ok: `existing` is the same internal metadata map from ETS.
        [{_, existing}] when is_map(existing) -> Map.merge(existing, meta)
        _ -> meta
      end

    :ets.insert(@table, {{:meta, ns, name}, merged})
    :ok
  end

  @doc "Read the metadata map recorded by `put_meta/3` for `name` in `ns` (no resolution)."
  def meta(ns, name) do
    case :ets.lookup(@table, {:meta, ns, name}) do
      [{_, meta}] -> {:ok, meta}
      [] -> :error
    end
  end

  @doc """
  Resolve `name` through the same alias/refer/core rules as `fetch/2`
  and return its docstring metadata.

  `name` is a var name string, or the quoted-symbol datum `{:symbol, name}`
  that `(doc 'foo)` hands over. Returns `%{ns: resolved_ns, name: resolved_name, doc: doc}`
  when a var with a docstring resolves, else `nil` (beam-lisp `doc` checks
  with `nil?` and reads the fields with `get`).
  """
  def doc_string(ns, name) do
    name = unwrap_doc_name(name)

    case Enum.find_value(candidates(ns, name), fn {cns, cname} ->
           case :ets.lookup(@table, {:meta, cns, cname}) do
             [{_, %{doc: doc}}] -> {cns, cname, doc}
             [] -> nil
           end
         end) do
      {cns, cname, doc} -> %{ns: cns, name: cname, doc: doc}
      nil -> nil
    end
  end

  defp unwrap_doc_name({:symbol, name}), do: name
  defp unwrap_doc_name(name) when is_binary(name), do: name

  @doc "Directories the loader searches for `<ns>.bl` files, innermost first."
  def load_paths, do: Agent.get(__MODULE__, & &1.load_paths)

  def push_load_path(dir), do: Agent.update(__MODULE__, &%{&1 | load_paths: [dir | &1.load_paths]})

  def pop_load_path do
    Agent.update(__MODULE__, &%{&1 | load_paths: tl(&1.load_paths)})
  end

  @doc """
  Configured search paths — library roots the loader consults after cwd.

  Distinct from `load_paths/0`, and the distinction matters: load paths are a
  STACK scoped to a load in progress (pushed on entry, popped after), while
  search paths are ambient configuration for the whole session. Conflating
  them would make a configured root vanish the moment a nested require
  finished, which is exactly the bug shape `pop_load_path` exists to create
  for the stack.
  """
  def search_paths, do: Agent.get(__MODULE__, &Map.get(&1, :search_paths, []))

  @doc "Append a search path (idempotent, order-preserving)."
  def add_search_path(dir) do
    dir = Path.expand(dir)

    Agent.update(__MODULE__, fn s ->
      paths = Map.get(s, :search_paths, [])
      if dir in paths, do: s, else: Map.put(s, :search_paths, paths ++ [dir])
    end)
  end

  @doc "Drop all configured search paths (test isolation)."
  def clear_search_paths, do: Agent.update(__MODULE__, &Map.put(&1, :search_paths, []))

  def fetch!(ns, name) do
    case fetch(ns, name) do
      {:ok, value} -> value
      :error -> raise "undefined var: #{ns}/#{name}"
    end
  end

  def seeded?, do: Agent.get(__MODULE__, & &1.seeded)
  def mark_seeded, do: Agent.update(__MODULE__, &%{&1 | seeded: true})
end
