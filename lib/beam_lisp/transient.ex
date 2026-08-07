defmodule BeamLisp.Transient do
  @moduledoc """
  Clojure transients: a mutable-inside-a-scope view of a persistent
  collection, used to build bulk results without paying per-element
  path-copying.

  BEAM values are immutable, so "mutable" here is a process-local
  fiction: the transient is a lightweight `{:"$transient", kind, key}`
  tag whose live state lives in the *process dictionary* under a
  unique `key`. Every operation re-reads that state; `persistent!`
  freezes it into a persistent collection and deletes the slot, so
  any further use raises — Clojure's one-way door.

  **An honest performance note: this is an API-compatibility layer,
  not a speedup.** BEAM has no shared mutable state, so the transient's
  "mutation" is a process-dictionary indirection — two dictionary ops
  per element. That overhead exceeds the algorithmic saving:

    * **Vectors** — the persistent vector's tail buffer already gives
      amortized O(1) `conj`, so the copy Clojure's transients exist to
      avoid is already cheap. The cons-list accumulation the transient
      uses (rebuild the trie once at `persistent!`) is O(n), but the
      per-element `Process.get`/`Process.put` makes it *slower* in
      practice — measured ~2.7x slower than plain `conj` over 100k
      elements (`test/beam_lisp/wave17_transient_test.exs`).

    * **Maps** — Elixir maps are already persistent with cheap
      structural sharing; `assoc!` is `Map.put` behind the wrapper.

  The value delivered is fidelity, not speed: `keys`/`vals`/`set`/
  `zipmap`/`frequencies`/`group-by` run verbatim from upstream
  `core.jank`, and `persistent!` enforces Clojure's one-way door.

  The wrapper is single-process by construction (the state lives in
  the caller's process dictionary), which matches Clojure — transients
  are not thread-safe and must not escape the scope they were built in.

  A transient created but never persisted leaks its process-dictionary
  slot until the process exits; like Clojure, the contract is
  *always* finish with `persistent!`.
  """

  alias BeamLisp.Vector

  @tag :"$transient"

  @doc "`(transient coll)` — vector or map into a transient view."
  def transient(%Vector{} = v) do
    # Pre-reverse to a list accumulator; conj! prepends (O(1)) and
    # persistent! re-reverses + builds the trie exactly once.
    key = make_ref()
    put_state(key, {:alive, {:vec, v |> Vector.to_list() |> Enum.reverse()}})
    {@tag, :vector, key}
  end

  def transient(%BeamLisp.Set{} = s) do
    # Before the is_map clause: a set is a struct, and a struct is a
    # map, so without this it would become a map transient and
    # conj! would fail. jank's `set` is written as
    # (persistent! (reduce conj! (transient #{}) coll)).
    key = make_ref()
    put_state(key, {:alive, {:set, s}})
    {@tag, :set, key}
  end

  def transient(m) when is_map(m) do
    key = make_ref()
    put_state(key, {:alive, {:map, m}})
    {@tag, :map, key}
  end

  def transient(other) do
    raise ArgumentError,
          "transient not supported for #{inspect(other)} (only vectors and maps)"
  end

  @doc "`(conj! t x)` — append to a transient vector."
  def conj!({@tag, :vector, key}, x) do
    case state(key) do
      {:alive, {:vec, rev}} ->
        put_state(key, {:alive, {:vec, [x | rev]}})
        {@tag, :vector, key}
    end
  end

  def conj!({@tag, :set, key}, x) do
    case state(key) do
      {:alive, {:set, s}} ->
        put_state(key, {:alive, {:set, BeamLisp.Set.add(s, x)}})
        {@tag, :set, key}
    end
  end

  @doc "`(assoc! t k v)` — set a transient map entry."
  def assoc!({@tag, :map, key}, k, v) do
    case state(key) do
      {:alive, {:map, m}} ->
        put_state(key, {:alive, {:map, Map.put(m, k, v)}})
        {@tag, :map, key}
    end
  end

  @doc "`(dissoc! t k)` — remove a transient map entry."
  def dissoc!({@tag, :map, key}, k) do
    case state(key) do
      {:alive, {:map, m}} ->
        put_state(key, {:alive, {:map, Map.delete(m, k)}})
        {@tag, :map, key}
    end
  end

  @doc "`(persistent! t)` — freeze the transient and invalidate it."
  def persistent!({@tag, kind, key}) do
    case {kind, Process.delete(key)} do
      {:vector, {:alive, {:vec, rev}}} -> Vector.new(Enum.reverse(rev))
      {:set, {:alive, {:set, s}}} -> s
      {:map, {:alive, {:map, m}}} -> m
      _ -> raise ArgumentError, "persistent! on an already-persisted transient"
    end
  end

  @doc false
  def persistent!(other) do
    raise ArgumentError, "persistent! expected a transient, got #{inspect(other)}"
  end

  @doc "`(get t k default)` on a transient map — read-through to live state."
  def get({@tag, :map, key}, k, default) do
    case state(key) do
      {:alive, {:map, m}} -> Map.get(m, k, default)
      _ -> raise ArgumentError, "get on an already-persisted transient"
    end
  end

  @doc "`(hash-map k v …)` — variadic constructor (even number of forms)."
  def hash_map(k, v, rest) when is_list(rest) do
    if rem(length(rest), 2) != 0 do
      raise ArgumentError, "hash-map requires an even number of forms, got #{length(rest) + 2}"
    end

    Enum.chunk_every(rest, 2)
    |> Enum.reduce(%{k => v}, fn [pk, pv], acc -> Map.put(acc, pk, pv) end)
  end

  @doc "`(hash-map)` — the empty map."
  def hash_map_empty, do: %{}

  # --- internals -----------------------------------------------------

  defp state(key) do
    case Process.get(key) do
      nil -> raise ArgumentError, "operation on an already-persisted transient"
      alive -> alive
    end
  end

  defp put_state(key, state), do: Process.put(key, state)
end
