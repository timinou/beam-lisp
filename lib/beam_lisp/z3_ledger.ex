defmodule BeamLisp.Z3.Ledger do
  @moduledoc """
  WHO answered, as data.

  A decision ladder is only honest if you can tell which rung answered, and the
  only way to know is to count. Every decision records two facts:

    * the FRAGMENT the question lives in (`:tag-lattice`, `:arith`, `:general`) —
      what a native rung would have to decide; and
    * the TIER that actually answered (`:native-witness`, `:z3`).

  The histogram over those counters is the measurement that decides whether
  another native rung is worth building: a number, not a taste.

  Two mechanisms, chosen deliberately:

    * the ROLLUP is `:counters` — atomic increments, so concurrent recorders
      cannot lose each other's counts. (An atom with `reset!(conj …)` did exactly
      that earlier in this work, and turned a working path into "one of eight
      answered".)
    * per-call attribution is the PROCESS DICTIONARY — a decision's tiers belong to
      the caller that made it. `here/0` is how a handler reports what its own
      request used.
  """

  @fragments [:"tag-lattice", :arith, :general]
  @tiers [:"native-witness", :z3]

  @table __MODULE__

  def up?, do: :ets.whereis(@table) != :undefined

  @doc """
  The table the counts live in: one ETS counter per KEY.

  ETS `update_counter` is atomic, so concurrent recorders cannot lose each other's
  counts, and the key is the term itself — `:arith`, `:z3`, `:total` — so there is
  no index arithmetic to get wrong. (The first version used `:counters`, whose
  indices are 1-based: it was called with index 0 and died "2nd argument: out of
  range" on the very first record, which took down every check that recorded one.)
  """
  def start do
    if up?() do
      :ok
    else
      :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])
      :ok
    end
  end

  @doc "Record one decision: the question's `fragment` and the `tier` that answered."
  def record(fragment, tier) do
    start()
    bump(fragment)
    bump(tier)
    bump(:total)
    Process.put({__MODULE__, :here}, [{fragment, tier} | Process.get({__MODULE__, :here}, [])])
    :ok
  end

  @doc "The tiers this process has used since `clear_here/0`."
  def here, do: Process.get({__MODULE__, :here}, []) |> Enum.reverse()

  @doc "Forget this process's trail (called at the start of a unit of work)."
  def clear_here do
    Process.put({__MODULE__, :here}, [])
    :ok
  end

  @doc "The rollup, zeroes included so a missing tier is visibly zero."
  def histogram do
    start()

    %{
      total: count(:total),
      fragments: Map.new(@fragments, fn f -> {f, count(f)} end),
      tiers: Map.new(@tiers, fn t -> {t, count(t)} end)
    }
  end

  @doc "Reset the rollup (tests, and a fresh measurement). Also clears this trail."
  def reset do
    if up?(), do: :ets.delete_all_objects(@table)
    clear_here()
  end

  # Keys arrive from beam-lisp — where a keyword may reach us as an atom or as its
  # text — so canonicalise against the FIXED set (never inventing an atom from
  # data). An unknown key is a programming error and says so.
  @all @fragments ++ @tiers ++ [:total]

  defp canon(key) do
    s = to_string(key)

    case Enum.find(@all, &(Atom.to_string(&1) == s)) do
      nil -> raise "unknown ledger key #{inspect(key)} (expected one of #{inspect(@all)})"
      found -> found
    end
  end

  defp bump(key) do
    k = canon(key)
    :ets.update_counter(@table, k, {2, 1}, {k, 0})
  end

  defp count(key) do
    k = canon(key)

    case :ets.lookup(@table, k) do
      [{^k, n}] -> n
      [] -> 0
    end
  end
end
