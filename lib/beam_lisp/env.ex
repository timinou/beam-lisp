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
        %{ns: "user", seeded: false}
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
  Resolve `name`, looking in `ns` first and falling back to `core`.

  A name containing a `/` is split into `{ns, var}` and looked up in
  that namespace only, so `core/map` and `user/f` both resolve.
  """
  def fetch(ns, name) do
    candidates =
      case String.split(name, "/", parts: 2) do
        [ns_part, var_name] -> [{ns_part, var_name}]
        [plain] -> [{ns, plain}, {"core", plain}]
      end

    Enum.find_value(candidates, :error, fn key ->
      case :ets.lookup(@table, key) do
        [{^key, value}] -> {:ok, value}
        [] -> nil
      end
    end)
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
