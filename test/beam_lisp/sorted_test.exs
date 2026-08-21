defmodule BeamLisp.SortedTest do
  @moduledoc """
  Substrate tests for `BeamLisp.Sorted` and its `BeamLisp.RT` integration.

  Two distinct concerns live here, and they fail for different reasons:

  1. **Ordering correctness** — does the key encoding reproduce Clojure's
     `compare` order? A wrong answer here silently mis-sorts an index,
     which surfaces much later as a query returning the wrong rows.

  2. **Clause-order regressions** — a `SortedMap` IS a struct, and a struct
     IS a map on the BEAM, so any RT function whose `is_bl_map` (or generic
     `%{__struct__: mod}`) clause precedes the sorted clause reads the
     STRUCT's fields instead of the collection's contents. That bug is
     silent: `find/2` returned `nil` for present keys during development
     and every other operation still looked correct.

  §2 is the reason this file asserts on operations that "obviously" work.
  They obviously worked right up until a clause landed above them.
  """

  use ExUnit.Case, async: true

  alias BeamLisp.{RT, Sorted}
  alias BeamLisp.Sorted.{SortedMap, SortedSet}

  describe "key encoding reproduces Clojure's compare order" do
    test "numbers order numerically across int and float" do
      # Erlang's term order agrees with Clojure here, but only because
      # ints and floats share an encoding rank. Separate ranks would sort
      # all ints before all floats — silently wrong for `[?e :age ?a]`
      # range predicates over mixed numeric data.
      s = Sorted.set_new([3, 1.5, 2, 1, 2.5])
      assert Sorted.set_to_list(s) == [1, 1.5, 2, 2.5, 3]
    end

    test "nil sorts before every other value" do
      s = Sorted.set_new([:kw, nil, 5, "str"])
      assert Sorted.set_to_list(s) |> List.first() == nil
    end

    test "cross-type ordering is total and stable" do
      # Clojure's `compare` raises across most types; a total order is
      # required here instead, because an index must never crash on
      # heterogeneous values. The exact interleaving is less important
      # than it being deterministic and repeatable.
      values = [:kw, "str", 5, nil, true, [1, 2]]
      once = Sorted.set_new(values) |> Sorted.set_to_list()
      twice = Sorted.set_new(Enum.reverse(values)) |> Sorted.set_to_list()
      assert once == twice
    end

    test "booleans do not interleave with keywords" do
      # Both are atoms on the BEAM: without separate ranks, `true` would
      # sort between the keywords `:a` and `:z` by atom name.
      s = Sorted.set_new([:a, true, :z, false])
      list = Sorted.set_to_list(s)
      bool_positions = Enum.filter(0..3, &(Enum.at(list, &1) in [true, false]))
      assert bool_positions == [0, 1], "booleans must group, got: #{inspect(list)}"
    end

    test "tuples order element-wise (the datom key layout)" do
      # This is precisely how index keys are shaped: {e, a, v, tx}.
      # Element-wise ordering is what makes a prefix scan possible.
      s = Sorted.set_new([{1, :b}, {1, :a}, {0, :z}, {2, :a}])
      assert Sorted.set_to_list(s) == [{0, :z}, {1, :a}, {1, :b}, {2, :a}]
    end

    test "vectors order element-wise like tuples" do
      v = fn items -> %BeamLisp.Vector{items: List.to_tuple(items)} end
      s = Sorted.set_new([v.([1, 2]), v.([1, 1]), v.([0, 9])])
      assert Sorted.set_to_list(s) |> Enum.map(&Tuple.to_list(&1.items)) == [[0, 9], [1, 1], [1, 2]]
    end
  end

  describe "range scans" do
    setup do
      %{s: Sorted.set_new(1..20//1 |> Enum.to_list())}
    end

    test "inclusive on both bounds", %{s: s} do
      assert Sorted.subseq_entries(s, {:bound, 5}, {:bound, 8}) |> Enum.map(&elem(&1, 0)) == [5, 6, 7, 8]
    end

    test "unbounded below and above", %{s: s} do
      assert Sorted.subseq_entries(s, :unbounded, {:bound, 3}) |> Enum.map(&elem(&1, 0)) == [1, 2, 3]
      assert Sorted.subseq_entries(s, {:bound, 18}, :unbounded) |> Enum.map(&elem(&1, 0)) == [18, 19, 20]
    end

    test "bounds that fall between keys still bracket correctly" do
      s = Sorted.set_new([10, 20, 30, 40])
      assert Sorted.subseq_entries(s, {:bound, 15}, {:bound, 35}) |> Enum.map(&elem(&1, 0)) == [20, 30]
    end

    test "empty range yields empty, not an error", %{s: s} do
      assert Sorted.subseq_entries(s, {:bound, 100}, {:bound, 200}) == []
      # inverted bounds are empty rather than a crash
      assert Sorted.subseq_entries(s, {:bound, 8}, {:bound, 5}) == []
    end

    test "descending reverses the same bounded window", %{s: s} do
      assert Sorted.rsubseq_entries(s, {:bound, 5}, {:bound, 8}) |> Enum.map(&elem(&1, 0)) == [8, 7, 6, 5]
    end

    test "scan on an empty collection is empty" do
      assert Sorted.subseq_entries(Sorted.set_new([]), :unbounded, :unbounded) == []
      assert Sorted.subseq_entries(Sorted.map_new(), {:bound, 1}, {:bound, 5}) == []
    end
  end

  describe "sorted map basics" do
    test "put replaces an equal key rather than duplicating" do
      m = Sorted.map_new() |> Sorted.map_put(:a, 1) |> Sorted.map_put(:a, 2)
      assert Sorted.map_count(m) == 1
      assert Sorted.map_get(m, :a) == 2
    end

    test "get returns the default for an absent key" do
      m = Sorted.map_new([{:a, 1}])
      assert Sorted.map_get(m, :zz, :missing) == :missing
      assert Sorted.map_get(m, :zz) == nil
    end

    test "delete is idempotent" do
      m = Sorted.map_new([{:a, 1}])
      once = Sorted.map_delete(m, :a)
      twice = Sorted.map_delete(once, :a)
      assert Sorted.map_count(twice) == 0
    end

    test "first/last are O(log n) endpoints, nil when empty" do
      m = Sorted.map_new([{:b, 2}, {:a, 1}, {:c, 3}])
      assert Sorted.first_entry(m) == {:a, 1}
      assert Sorted.last_entry(m) == {:c, 3}
      assert Sorted.first_entry(Sorted.map_new()) == nil
      assert Sorted.last_key(Sorted.set_new([])) == nil
    end

    test "keys and vals are both in key order" do
      m = Sorted.map_new([{"c", 3}, {"a", 1}, {"b", 2}])
      assert Sorted.map_keys(m) == ["a", "b", "c"]
      assert Sorted.map_vals(m) == [1, 2, 3]
    end
  end

  describe "RT integration: the struct-is-a-map hazard" do
    # Every assertion below guards a clause that MUST precede the generic
    # map/struct clauses in BeamLisp.RT. `find/2` is the one that actually
    # regressed during development, and it regressed silently.

    setup do
      %{
        m: Sorted.map_new([{"a", 1}, {"b", 2}]),
        s: Sorted.set_new([1, 2, 3])
      }
    end

    test "find returns the entry for a present key, not nil", %{m: m} do
      # THE regression: the generic %{__struct__: mod} clause matched
      # first, Record.record?/1 said false, and find_in_map/2 then read
      # the struct's :tree field — nil for every real key.
      assert RT.find(m, "a") == %BeamLisp.Vector{items: {"a", 1}}
      assert RT.find(m, "absent") == nil
    end

    test "count reports entries, not struct fields", %{m: m, s: s} do
      # A struct has 1 field here; a wrong clause order returns 1.
      assert RT.count(m) == 2
      assert RT.count(s) == 3
    end

    test "get reads contents, not fields", %{m: m, s: s} do
      assert RT.get(m, "b", :miss) == 2
      assert RT.get(m, :tree, :miss) == :miss, "must not expose the backing field"
      assert RT.get(s, 2, :miss) == 2
      assert RT.get(s, 99, :miss) == :miss
    end

    test "seq yields ordered contents and nil when empty", %{m: m, s: s} do
      assert RT.seq(s) == [1, 2, 3]
      assert RT.seq(m) == [%BeamLisp.Vector{items: {"a", 1}}, %BeamLisp.Vector{items: {"b", 2}}]
      assert RT.seq(Sorted.set_new([])) == nil
      assert RT.seq(Sorted.map_new()) == nil
    end

    test "first/rest/next read contents", %{s: s} do
      assert RT.first(s) == 1
      assert RT.rest(s) == [2, 3]
      assert RT.next(s) == [2, 3]
      assert RT.first(Sorted.set_new([])) == nil
    end

    test "contains? is membership for sets and key-presence for maps", %{m: m, s: s} do
      assert RT.contains?(s, 2)
      refute RT.contains?(s, 99)
      assert RT.contains?(m, "a")
      refute RT.contains?(m, 1), "a map's contains? asks about KEYS, not values"
    end

    test "predicates agree with the operations that act on these types", %{m: m, s: s} do
      assert RT.map?(m), "a sorted map answers every map operation, so map? must agree"
      refute RT.map?(s)
      assert RT.set?(s)
      assert RT.coll?(m) and RT.coll?(s)
      assert RT.sorted?(m) and RT.sorted?(s)
      refute RT.sorted?(%{}), "a plain map is unordered"
      assert RT.sorted_map?(m)
      refute RT.sorted_map?(s)
      assert RT.sorted_set?(s)
      refute RT.sorted_set?(m)
    end

    test "assoc maintains order; conj adds members/entries", %{m: m, s: s} do
      assoced = RT.assoc(m, "aa", 99)
      assert Sorted.map_keys(assoced) == ["a", "aa", "b"]
      assert %SortedSet{} = RT.conj(s, 0)
      assert RT.first(RT.conj(s, 0)) == 0
      assert %SortedMap{} = RT.conj(m, %BeamLisp.Vector{items: {"z", 26}})
    end

    test "assoc on a sorted set raises rather than corrupting the struct", %{s: s} do
      assert_raise ArgumentError, ~r/not supported on a sorted set/, fn ->
        RT.assoc(s, :k, :v)
      end
    end

    test "conj on a sorted map rejects a non-entry loudly", %{m: m} do
      assert_raise ArgumentError, ~r/expects a \[k v\] entry/, fn -> RT.conj(m, 42) end
    end

    test "disj removes a member", %{s: s} do
      assert RT.count(RT.disj(s, 2)) == 2
      assert RT.count(RT.disj(s, 99)) == 3, "disj is idempotent"
    end

    test "printing is ordered and deterministic", %{m: m, s: s} do
      assert RT.print_str(s) == "#{"#"}{1 2 3}"
      assert RT.print_str(m) == ~s({"a" 1, "b" 2})
    end

    test "map/filter iterate in key order", %{m: m, s: s} do
      assert RT.map(fn x -> x * 10 end, s) |> Enum.to_list() == [10, 20, 30]
      keys = RT.map(fn entry -> RT.get(entry, 0, nil) end, m) |> Enum.to_list()
      assert keys == ["a", "b"]
    end

    test "transientable? is false: gb_trees is already persistent", %{m: m, s: s} do
      refute RT.transientable?(m)
      refute RT.transientable?(s)
    end
  end

  describe "constructors" do
    test "sorted_map/1 pairs flat args" do
      m = RT.sorted_map([:b, 2, :a, 1])
      assert Sorted.map_keys(m) == [:a, :b]
    end

    test "sorted_map/1 rejects an odd argument count loudly" do
      assert_raise ArgumentError, ~r/no value supplied for key/, fn ->
        RT.sorted_map([:a, 1, :b])
      end
    end

    test "sorted_set_of/1 de-duplicates" do
      assert RT.sorted_set_of([3, 1, 3, 1]) |> Sorted.set_to_list() == [1, 3]
    end

    test "sorted_map_of/1 accepts entry vectors" do
      entries = [%BeamLisp.Vector{items: {:b, 2}}, %BeamLisp.Vector{items: {:a, 1}}]
      assert RT.sorted_map_of(entries) |> Sorted.map_keys() == [:a, :b]
    end
  end

  describe "review-gate regressions: the encoder must PROJECT RT.compare" do
    # The encoder invented its own rank table and disagreed with the
    # language's authoritative order in three places. Two competing
    # definitions of "sorted" is how an index silently returns wrong rows.

    test "agrees with RT.compare for every cross-type pair" do
      values = [nil, false, true, 0, 1.5, "s", :s, [1, 2]]

      for a <- values, b <- values do
        cmp = RT.compare(a, b)
        [x | _] = Sorted.set_new([a, b]) |> Sorted.set_to_list()

        cond do
          cmp < 0 -> assert x === a, "compare says #{inspect(a)} < #{inspect(b)}, encoder disagrees"
          cmp > 0 -> assert x === b, "compare says #{inspect(b)} < #{inspect(a)}, encoder disagrees"
          true -> :ok
        end
      end
    end

    test "a sorted set matches RT.sort for a mixed value set" do
      values = [:kw, "str", 5, nil, true, false, 1.5]
      sorted_via_sort = RT.sort(values) |> Enum.to_list()
      assert Sorted.set_new(values) |> Sorted.set_to_list() == sorted_via_sort
    end

    test "keywords compare by NAME, not by atom identity" do
      assert Sorted.set_new([:zebra, :apple]) |> Sorted.set_to_list() == [:apple, :zebra]
    end
  end

  describe "review-gate regressions: sentinel and improper lists" do
    test "a legal :unbounded keyword is usable as a real bound" do
      # `:unbounded` was the raw internal marker, so scanning FOR that
      # keyword was read as "no bound" and returned everything.
      s = Sorted.set_new([:a, :unbounded, :z])
      assert RT.subseq(s, :unbounded, :unbounded) == [:unbounded]
      assert RT.subseq(s, :a, :unbounded) == [:a, :unbounded]
    end

    test "an improper [head | LazySeq] key encodes instead of crashing" do
      # RT.cons/2 legitimately produces these; Enum.map raised on the
      # non-list tail. A key that crashes on INSERT fails a whole
      # transaction for a value the language allows.
      improper = RT.cons(0, BeamLisp.LazySeq.new(fn -> nil end))
      assert Sorted.set_new([improper]) |> Sorted.set_count() == 1
    end

    test "a lazy tail is realised into the encoding, so order is by contents" do
      # A lazy-seq thunk yields a CELL (a list), not a {head, tail} tuple.
      lazy_23 = BeamLisp.LazySeq.new(fn -> [2, 3] end)
      improper = RT.cons(1, lazy_23)

      # Encoding must realise the tail, so this sorts by CONTENTS
      # (1,2,3) rather than by the opaque struct sitting in the tail.
      s = Sorted.set_new([[1, 9], improper])
      assert Sorted.set_count(s) == 2
      assert [first_key | _] = Sorted.set_to_list(s)
      # [1,2,3] < [1,9] element-wise, so the improper value sorts first.
      # (It is still an improper list, so realise it before comparing.)
      assert BeamLisp.LazySeq.to_list(first_key) == [1, 2, 3]
    end
  end

  describe "review-gate regressions: equality and stack ops" do
    test "a sorted map equals a plain map with the same entries" do
      # Clojure: sortedness is an index property, not part of identity.
      assert RT.eqv(Sorted.map_new([{:a, 1}]), %{a: 1})
      assert RT.eqv(%{a: 1}, Sorted.map_new([{:a, 1}]))
      refute RT.eqv(Sorted.map_new([{:a, 1}]), %{a: 2})
      refute RT.eqv(Sorted.map_new([{:a, 1}]), %{a: 1, b: 2})
    end

    test "a sorted set equals a hashed set with the same members" do
      assert RT.eqv(Sorted.set_new([1, 2]), BeamLisp.Set.new([1, 2]))
      refute RT.eqv(Sorted.set_new([1, 2]), BeamLisp.Set.new([1, 3]))
    end

    test "two sorted collections are equal regardless of build order" do
      assert RT.eqv(Sorted.set_new([1, 2]), Sorted.set_new([2, 1]))
    end

    test "peek and pop reject ordered collections rather than answering first/rest" do
      assert_raise ArgumentError, ~r/not a stack/, fn -> RT.peek(Sorted.set_new([1, 2])) end
      assert_raise ArgumentError, ~r/not a stack/, fn -> RT.pop(Sorted.set_new([1, 2])) end
      assert_raise ArgumentError, ~r/not a stack/, fn -> RT.peek(Sorted.map_new([{:a, 1}])) end
      assert_raise ArgumentError, ~r/not a stack/, fn -> RT.pop(Sorted.map_new([{:a, 1}])) end
    end
  end
end
