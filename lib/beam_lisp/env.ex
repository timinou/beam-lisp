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
        %{ns: "user", seeded: false, loaded: MapSet.new(), load_paths: []}
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
    candidates =
      case String.split(name, "/", parts: 2) do
        # A leading slash (`/`, `/x`) is part of the var name itself.
        ["" | _] ->
          [{ns, name}] ++ refer_candidate(ns, name) ++ [{"core", name}]

        [prefix, var_name] ->
          [{alias_target(ns, prefix) || prefix, var_name}]

        [plain] ->
          [{ns, plain}] ++ refer_candidate(ns, plain) ++ [{"core", plain}]
      end

    Enum.find_value(candidates, :error, fn key ->
      case :ets.lookup(@table, key) do
        [{^key, value}] -> {:ok, value}
        [] -> nil
      end
    end)
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

  @doc "Refer `name` into `ns` so it resolves bare, as if defined there."
  def add_refer(ns, name, source_ns) do
    :ets.insert(@table, {{:refer, ns, name}, source_ns})
    :ok
  end

  defp refer_candidate(ns, name) do
    case :ets.lookup(@table, {:refer, ns, name}) do
      [{_, source}] -> [{source, name}]
      [] -> []
    end
  end

  @doc "True when any var is interned in `ns`."
  def ns_exists?(ns) do
    case :ets.match(@table, {{ns, :_}, :_}, 1) do
      {[_], _} -> true
      _ -> false
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

  @doc "Register link metadata `{module, %{arity => fname}, {min, vfname} | nil}` for a fn var."
  def put_link(ns, name, info), do: :ets.insert(@table, {{:link, ns, name}, info})

  @doc "Resolve link metadata with the same alias/refer/core rules as fetch/2."
  def link(ns, name) do
    candidates =
      case String.split(name, "/", parts: 2) do
        ["" | _] ->
          [{ns, name}] ++ refer_candidate(ns, name) ++ [{"core", name}]

        [prefix, var_name] ->
          [{alias_target(ns, prefix) || prefix, var_name}]

        [plain] ->
          [{ns, plain}] ++ refer_candidate(ns, plain) ++ [{"core", plain}]
      end

    Enum.find_value(candidates, :error, fn {cns, cname} ->
      case :ets.lookup(@table, {:link, cns, cname}) do
        [{_, info}] -> {:ok, info}
        [] -> nil
      end
    end)
  end

  @doc "Directories the loader searches for `<ns>.bl` files, innermost first."
  def load_paths, do: Agent.get(__MODULE__, & &1.load_paths)

  def push_load_path(dir), do: Agent.update(__MODULE__, &%{&1 | load_paths: [dir | &1.load_paths]})

  def pop_load_path do
    Agent.update(__MODULE__, &%{&1 | load_paths: tl(&1.load_paths)})
  end

  def fetch!(ns, name) do
    case fetch(ns, name) do
      {:ok, value} -> value
      :error -> raise "undefined var: #{ns}/#{name}"
    end
  end

  def seeded?, do: Agent.get(__MODULE__, & &1.seeded)
  def mark_seeded, do: Agent.update(__MODULE__, &%{&1 | seeded: true})
end
