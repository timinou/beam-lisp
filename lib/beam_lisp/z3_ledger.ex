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
  @tiers [:"native-witness", :z3, :memo]

  # EVERY slot, and the key → slot map. Module attributes resolve where they are
  # used, so these sit above the functions that need them. `:total` is a slot like any
  # other, so the histogram reports it without arithmetic — an earlier version derived
  # the slot with `find_index(...) + 1` and handed :counters a 0.
  @all @fragments ++ @tiers ++ [:total]
  @index @all |> Enum.with_index(1) |> Map.new()

  @key {__MODULE__, :counters}

  def up?, do: :persistent_term.get(@key, nil) != nil

  # Created at LOAD, in one process, before anything can race.
  @on_load :open
  def start, do: :ok

  @doc false
  # Public because @on_load needs an exported zero-arity function (with `defp` the
  # module failed to load and took every z3 call with it: 24 errors of 24 in the soak).
  #
  # Counters, created ONCE at load. Two earlier shapes were measured and rejected:
  # an ETS named table created on first use is a check-then-create across processes,
  # so racers died with "table name already exists" — counted as a wrong verdict, ~1 in
  # 200, which is how this was found; and an ETS table created at load then vanished
  # ("the table identifier does not refer to an existing ETS table") because a table dies
  # with the process that made it, and the loader is short-lived. A counters ref has no
  # owner: it outlives the process that created it.
  def open do
    :persistent_term.put(@key, :counters.new(length(@all), [:write_concurrency]))
    :ok
  end

  @doc """
  Record one decision: the question's `fragment`, the `tier` that answered, and the
  `status` it answered WITH — `sat`, `unsat`, or `unknown`.

  The status is half the record. The tier says WHO answered; the status says
  whether there was an answer at all, and `unknown` collapsed into a boolean is how
  a machine whose invariant holds came to be reported as violated (FUP-058).
  """
  def record(fragment, tier, status \\ nil, us \\ nil) do
    start()
    bump(fragment)
    bump(tier)
    bump(:total)
    # A MAP, not a tuple: the trail is read from beam-lisp, and there `(get tuple 1)`
    # returns nil (an Elixir tuple is not indexable from the language), which made
    # tier-for fall through to its default. Atom keys on a plain map read fine — the
    # z3 results have been read that way all along.
    Process.put({__MODULE__, :here}, [
      %{fragment: fragment, tier: tier, status: status, us: us} | Process.get({__MODULE__, :here}, [])
    ])
    :ok
  end

  @doc "The tiers this process has used since `clear_here/0`."
  def here, do: Process.get({__MODULE__, :here}, []) |> Enum.reverse()

  @doc "Forget this process's trail (called at the start of a unit of work)."
  def clear_here do
    Process.put({__MODULE__, :here}, [])
    :ok
  end

  @doc """
  The decisions in this process's trail that the solver could NOT decide.

  `unknown` is an answer about the SOLVER, not about the question: a fragment it
  cannot decide, or a ceiling it hit. Read as a boolean it becomes "not proved",
  and the verifier renders "not proved" as "violated" — so this is what the
  boundary asks before it lets a verdict out.
  """
  def undecided do
    here() |> Enum.filter(&(to_string(&1[:status]) == "unknown"))
  end

  @doc """
  The COST of this process's decisions, in microseconds — the instrument behind
  choosing a deadline from a measured distribution instead of an argument. Before
  it existed, no obligation in the tree had ever been timed.
  """
  def cost do
    us = here() |> Enum.map(&(&1[:us] || 0))
    max = if us == [], do: 0, else: Enum.max(us)
    %{count: length(us), total_us: Enum.sum(us), max_us: max}
  end

  @doc "The rollup, zeroes included so a missing tier is visibly zero."
  def histogram do
    %{
      total: count(:total),
      fragments: Map.new(@fragments, fn f -> {f, count(f)} end),
      tiers: Map.new(@tiers, fn t -> {t, count(t)} end)
    }
  end

  @doc "Reset the rollup (tests, and a fresh measurement). Also clears this trail."
  def reset do
    for k <- @all, do: :counters.put(counters(), ix(k), 0)
    clear_here()
  end

  # Keys arrive from beam-lisp — where a keyword may reach us as an atom or as its
  # text — so canonicalise against the FIXED set (never inventing an atom from
  # data). An unknown key is a programming error and says so.
  defp canon(key) do
    s = to_string(key)

    case Enum.find(@all, &(Atom.to_string(&1) == s)) do
      nil -> raise "unknown ledger key #{inspect(key)} (expected one of #{inspect(@all)})"
      found -> found
    end
  end

  defp bump(key), do: :counters.add(counters(), ix(key), 1)

  defp counters, do: :persistent_term.get(@key)

  defp count(key), do: :counters.get(counters(), ix(key))

  defp ix(key) do
    case Map.fetch(@index, canon(key)) do
      {:ok, i} -> i
      :error -> raise "no ledger slot for #{inspect(key)}"
    end
  end
end
