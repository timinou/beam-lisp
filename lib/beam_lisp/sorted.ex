defmodule BeamLisp.Sorted do
  @moduledoc """
  beam-lisp's ORDERED collections: `SortedMap` and `SortedSet`, backed by
  OTP's `:gb_trees`.

  ## Why this exists

  `BeamLisp.Set` is `MapSet`-backed: hash membership, no ordering. That is
  the right default for a Clojure set — but an ordered collection answers a
  question a hashed one cannot: *"every element between A and B, in order"*.

  That question is the whole basis of index scanning, which is why this
  module is the prerequisite for the EAV/datalog layer (PLAN-033): a
  covering index is nothing but an order-preserving key encoding plus a
  range scan over it. `subseq`/`rsubseq` here ARE that scan.

  ## Why `:gb_trees` rather than a tree written in beam-lisp

  The maximalist rule for this project is "as much as possible in `.bl`;
  Elixir keeps only substrate". A balanced binary tree is substrate: OTP
  ships a fuzz-hardened, decades-old general balanced tree with O(log n)
  ops and — critically — `:gb_trees.iterator_from/2`, which starts an
  in-order walk at an arbitrary key WITHOUT materialising the prefix. That
  last property is what makes a range scan cheap; reimplementing it in
  `.bl` would be slower, buggier, and would duplicate OTP for no gain.

  The vocabulary ON TOP (`sorted-set`, `subseq`, comparator handling) lives
  in `priv/core.bl`, where it belongs.

  ## Ordering is Clojure's, not Erlang's

  Erlang's term order sorts `number < atom < reference < fun < port < pid <
  tuple < map < list < bitstring`. Clojure's `compare` refuses to compare
  across most types, and orders numbers numerically regardless of int/float.
  `:gb_trees` uses Erlang term order internally via `<`/`>`, which agrees
  with Clojure for the cases an index actually stores (numbers of one kind,
  binaries, tuples of those). Rather than pay for a custom comparator on
  every node, keys are stored under an ORDER-PRESERVING ENCODING computed
  once at insert (`encode_key/1`), so Erlang's native comparison yields
  Clojure's answer.

  The encoding is `{rank, value}`: rank groups by type so cross-type
  comparison is total and stable, and within a rank the natural term order
  is already correct. Integers and floats share rank 0 so `1 < 1.5 < 2`
  holds across kinds — the one place Erlang's order (which also compares
  numbers numerically) and Clojure's agree exactly.

  ## The struct-is-a-map hazard

  Same rule as `BeamLisp.Set` and `BeamLisp.Vector`: a struct IS a map on
  the BEAM, so every `SortedMap`/`SortedSet` clause in `BeamLisp.RT` MUST
  precede that function's `is_bl_map` clause, or `count`/`seq`/`first`
  read the struct's two fields instead of the collection's contents. The
  clauses are guarded with `is_bl_map` on the plain-map side, so the
  ordering is enforced by the guard rather than by convention.
  """

  defmodule SortedMap do
    @moduledoc """
    An ordered map: keys in Clojure `compare` order, backed by `:gb_trees`.

    `tree` holds `{encoded_key, {original_key, value}}` — the encoding is
    what `:gb_trees` compares on, the original key is what beam-lisp sees
    on the way out. Storing both avoids decoding on every read.
    """
    defstruct [:tree]
  end

  defmodule SortedSet do
    @moduledoc """
    An ordered set: a `SortedMap` whose values are ignored.

    Backed by the same `:gb_trees` so that `subseq`/`rsubseq`/`first`/`last`
    have one implementation rather than two.
    """
    defstruct [:tree]
  end

  alias BeamLisp.Sorted.{SortedMap, SortedSet}

  # ── key encoding ─────────────────────────────────────────────────────
  #
  # {rank, comparable} — rank makes cross-type order total, and within a
  # rank Erlang's native term order already matches Clojure's.
  #
  # nil sorts before everything (Clojure: (compare nil x) is -1 for all x),
  # so it gets rank -1 rather than being lumped in with atoms.

  @doc """
  Encode `key` into a term whose Erlang order matches Clojure's `compare`.

  Numbers share a rank so `1 < 1.5 < 2` holds across int/float. `nil` sorts
  first. Booleans are separated from keywords because Erlang would order
  them as the atoms `false`/`true` interleaved among keyword names.
  """
  def encode_key(nil), do: {-1, nil}
  def encode_key(x) when is_number(x), do: {0, x}
  def encode_key(x) when is_boolean(x), do: {1, x}
  def encode_key(x) when is_atom(x), do: {2, x}
  def encode_key(x) when is_binary(x), do: {3, x}
  def encode_key(%BeamLisp.Vector{} = v), do: {4, Enum.map(BeamLisp.Vector.to_list(v), &encode_key/1)}
  def encode_key(x) when is_list(x), do: {4, Enum.map(x, &encode_key/1)}
  def encode_key(x) when is_tuple(x), do: {5, x |> Tuple.to_list() |> Enum.map(&encode_key/1)}
  # Anything else (maps, fns, pids) has no meaningful Clojure order; rank 6
  # keeps the tree total rather than crashing, and equal keys still collide
  # correctly because the raw term is the tiebreaker.
  def encode_key(x), do: {6, x}

  # ── construction ─────────────────────────────────────────────────────

  @doc "The empty sorted map."
  def map_new, do: %SortedMap{tree: :gb_trees.empty()}

  @doc "A sorted map from an enumerable of `{k, v}` pairs."
  def map_new(pairs) do
    Enum.reduce(pairs, map_new(), fn {k, v}, acc -> map_put(acc, k, v) end)
  end

  @doc "The empty sorted set."
  def set_new, do: %SortedSet{tree: :gb_trees.empty()}

  @doc "A sorted set of the distinct elements of `enum`."
  def set_new(enum), do: Enum.reduce(enum, set_new(), &set_add(&2, &1))

  # ── sorted map ops ───────────────────────────────────────────────────

  @doc "Map with `k` associated to `v` (replaces an equal key)."
  def map_put(%SortedMap{tree: t}, k, v),
    do: %SortedMap{tree: :gb_trees.enter(encode_key(k), {k, v}, t)}

  @doc "Value for `k`, or `default` when absent."
  def map_get(%SortedMap{tree: t}, k, default \\ nil) do
    case :gb_trees.lookup(encode_key(k), t) do
      {:value, {_orig, v}} -> v
      :none -> default
    end
  end

  @doc "Whether `k` is present."
  def map_has_key?(%SortedMap{tree: t}, k), do: :gb_trees.is_defined(encode_key(k), t)

  @doc "Map with `k` removed (idempotent)."
  def map_delete(%SortedMap{tree: t} = m, k) do
    ek = encode_key(k)
    if :gb_trees.is_defined(ek, t),
      do: %SortedMap{m | tree: :gb_trees.delete(ek, t)},
      else: m
  end

  @doc "Number of entries."
  def map_count(%SortedMap{tree: t}), do: :gb_trees.size(t)

  @doc "Entries as a list of `{k, v}`, in key order."
  def map_to_list(%SortedMap{tree: t}),
    do: :gb_trees.values(t) |> Enum.map(fn {k, v} -> {k, v} end)

  @doc "Keys in order."
  def map_keys(%SortedMap{} = m), do: map_to_list(m) |> Enum.map(&elem(&1, 0))

  @doc "Values in key order."
  def map_vals(%SortedMap{} = m), do: map_to_list(m) |> Enum.map(&elem(&1, 1))

  # ── sorted set ops ───────────────────────────────────────────────────

  @doc "Set with `x` added (idempotent)."
  def set_add(%SortedSet{tree: t}, x),
    do: %SortedSet{tree: :gb_trees.enter(encode_key(x), {x, nil}, t)}

  @doc "Set with `x` removed (idempotent)."
  def set_del(%SortedSet{tree: t} = s, x) do
    ek = encode_key(x)
    if :gb_trees.is_defined(ek, t),
      do: %SortedSet{s | tree: :gb_trees.delete(ek, t)},
      else: s
  end

  @doc "Membership test."
  def set_member?(%SortedSet{tree: t}, x), do: :gb_trees.is_defined(encode_key(x), t)

  @doc "Cardinality."
  def set_count(%SortedSet{tree: t}), do: :gb_trees.size(t)

  @doc "Members in order."
  def set_to_list(%SortedSet{tree: t}),
    do: :gb_trees.values(t) |> Enum.map(fn {k, _} -> k end)

  # ── ordered access (the point of the module) ─────────────────────────

  @doc "First (smallest) key/member, or nil when empty."
  def first_key(%SortedMap{tree: t}), do: smallest(t, fn {k, _v} -> k end)
  def first_key(%SortedSet{tree: t}), do: smallest(t, fn {k, _} -> k end)

  @doc "First entry `{k, v}` of a sorted map, or nil when empty."
  def first_entry(%SortedMap{tree: t}), do: smallest(t, & &1)

  @doc "Last (largest) key/member, or nil when empty."
  def last_key(%SortedMap{tree: t}), do: largest(t, fn {k, _v} -> k end)
  def last_key(%SortedSet{tree: t}), do: largest(t, fn {k, _} -> k end)

  @doc "Last entry `{k, v}` of a sorted map, or nil when empty."
  def last_entry(%SortedMap{tree: t}), do: largest(t, & &1)

  defp smallest(t, f) do
    case :gb_trees.size(t) do
      0 -> nil
      _ -> t |> :gb_trees.smallest() |> elem(1) |> f.()
    end
  end

  defp largest(t, f) do
    case :gb_trees.size(t) do
      0 -> nil
      _ -> t |> :gb_trees.largest() |> elem(1) |> f.()
    end
  end

  @doc """
  Ascending entries whose key satisfies the bound, as `{k, v}` pairs.

  `start` and `stop` are inclusive bounds; `:unbounded` omits that side.
  The walk begins at `iterator_from/2`, so a scan over a narrow range does
  NOT traverse the keys below it — this is the property index scanning
  depends on.
  """
  def subseq_entries(coll, start, stop) do
    t = tree(coll)

    iter =
      case start do
        :unbounded -> :gb_trees.iterator(t)
        k -> :gb_trees.iterator_from(encode_key(k), t)
      end

    take_while_le(iter, stop_encoded(stop), [])
  end

  @doc """
  Descending entries whose key satisfies the bound, as `{k, v}` pairs.

  `:gb_trees` has no reverse iterator, so this walks the ascending range
  and reverses it. The range is bounded first, so the cost is proportional
  to the RESULT size, not the tree size — which is the property that
  matters. A native descending iterator would save the reversal only.
  """
  def rsubseq_entries(coll, start, stop) do
    subseq_entries(coll, start, stop) |> Enum.reverse()
  end

  defp tree(%SortedMap{tree: t}), do: t
  defp tree(%SortedSet{tree: t}), do: t

  defp stop_encoded(:unbounded), do: :unbounded
  defp stop_encoded(k), do: encode_key(k)

  defp take_while_le(iter, stop, acc) do
    case :gb_trees.next(iter) do
      :none ->
        Enum.reverse(acc)

      {ek, {k, v}, rest} ->
        if stop == :unbounded or ek <= stop,
          do: take_while_le(rest, stop, [{k, v} | acc]),
          else: Enum.reverse(acc)
    end
  end
end
