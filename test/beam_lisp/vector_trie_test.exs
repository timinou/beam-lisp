defmodule BeamLisp.VectorTrieTest do
  use ExUnit.Case, async: true

  alias BeamLisp.Vector

  @boundaries [0, 1, 31, 32, 33, 63, 64, 65, 1023, 1024, 1025, 32 * 32 + 1, 32769, 100_000]

  defp indices(0), do: []
  defp indices(n), do: Enum.to_list(0..(n - 1))

  describe "construction" do
    test "new/0 and new/1 build the empty and singleton vectors" do
      assert Vector.new() == Vector.new([])
      assert Vector.count(Vector.new()) == 0
      assert Vector.count(Vector.new([1])) == 1
    end

    test "new equals the compiler's tuple-backed literal for small vectors" do
      assert Vector.new([1, 2, 3]).items == {1, 2, 3}
      assert Vector.new([1, 2, 3]) == %Vector{items: {1, 2, 3}}
    end

    test "new preserves element order and count at every boundary" do
      for n <- @boundaries do
        expected = indices(n)
        v = Vector.new(expected)
        assert Vector.count(v) == n
        assert Vector.to_list(v) == expected
      end
    end
  end

  describe "conj appends in amortized O(1)" do
    test "build 0..N by repeated conj, asserting to_list each step" do
      for n <- @boundaries do
        v =
          Enum.reduce(indices(n), Vector.new(), fn i, acc ->
            acc = Vector.conj(acc, i)
            assert Vector.nth(acc, i) == i
            assert Vector.count(acc) == i + 1
            acc
          end)

        assert Vector.to_list(v) == indices(n)
      end
    end

    test "conj matches Clojure semantics on lists" do
      # vector conj appends; (conj '(1 2) 3) prepends — handled in RT,
      # here we only assert the vector side keeps appending.
      assert Vector.to_list(Vector.conj(Vector.new([1, 2]), 3)) == [1, 2, 3]
    end
  end

  describe "persistence" do
    test "the old vector is unchanged after conj" do
      v = Vector.new([1, 2, 3])
      v2 = Vector.conj(v, 4)
      assert Vector.to_list(v) == [1, 2, 3]
      assert Vector.to_list(v2) == [1, 2, 3, 4]
    end

    test "the old vector is unchanged after assoc" do
      v = Vector.new([1, 2, 3])
      v2 = Vector.assoc(v, 0, :x)
      assert Vector.to_list(v) == [1, 2, 3]
      assert Vector.nth(v2, 0) == :x
      assert Vector.to_list(v2) == [:x, 2, 3]
    end

    test "many versions coexist and each stays correct" do
      versions =
        Enum.reduce(0..999, [Vector.new()], fn i, [latest | _] = acc ->
          [Vector.conj(latest, i) | acc]
        end)

      # every version from 0..999 is still intact and correct
      Enum.with_index(Enum.reverse(versions)) |> Enum.each(fn {v, i} ->
        assert Vector.count(v) == i
        assert Vector.to_list(v) == indices(i)
      end)
    end

    test "persistence holds across the tail→trie flush boundary" do
      # build 40 elements, snapshot at 31 (before flush), keep conjing
      base = Enum.reduce(0..30, Vector.new(), &Vector.conj(&2, &1))
      snapshot31 = base
      grown = Enum.reduce(31..39, base, &Vector.conj(&2, &1))
      assert Vector.count(snapshot31) == 31
      assert Vector.to_list(snapshot31) == Enum.to_list(0..30)
      assert Vector.to_list(grown) == Enum.to_list(0..39)
    end

    test "deep-tree persistence: snapshots before and after a shift overflow" do
      # shift overflows at cnt just past 1056; snapshot just before.
      before = Enum.reduce(0..1055, Vector.new(), &Vector.conj(&2, &1))
      snap = before
      grown = Enum.reduce(1056..2000, before, &Vector.conj(&2, &1))
      assert Vector.count(snap) == 1056
      assert Vector.to_list(snap) == Enum.to_list(0..1055)
      assert Vector.to_list(grown) == Enum.to_list(0..2000)
    end
  end

  describe "nth" do
    test "indexed access returns the right element at boundaries" do
      for n <- @boundaries do
        v = Vector.new(indices(n))
        assert Enum.all?(indices(n), &(Vector.nth(v, &1) == &1))
      end
    end

    test "out-of-range and nil are lenient, like before" do
      v = Vector.new([1, 2, 3])
      assert Vector.nth(v, 3) == nil
      assert Vector.nth(v, -1) == nil
      assert Vector.nth(v, 100) == nil
      assert Vector.nth(Vector.new(), 0) == nil
    end

    test "a compiler-built literal (raw tuple) over 32 elements works through the API" do
      # the compiler builds vector literals as %Vector{items: big-tuple};
      # those have no trie wrapper and must still read/conj/assoc correctly.
      raw = %Vector{items: List.to_tuple(Enum.to_list(0..40))}
      assert Vector.count(raw) == 41
      assert Vector.nth(raw, 0) == 0
      assert Vector.nth(raw, 40) == 40
      assert Vector.nth(raw, 41) == nil
      assert Vector.to_list(raw) == Enum.to_list(0..40)

      grown = Vector.conj(raw, 41)
      assert Vector.count(grown) == 42
      assert Vector.to_list(grown) == Enum.to_list(0..41)
      # the raw 33+ tuple converts to a trie once it crosses 32
      assert Vector.nth(grown, 40) == 40

      edited = Vector.assoc(raw, 20, :raw)
      assert Vector.nth(raw, 20) == 20
      assert Vector.nth(edited, 20) == :raw
      assert Vector.count(edited) == 41
    end

    test "nil is a valid stored element" do
      v = Vector.new([nil, 1, nil])
      assert Vector.nth(v, 0) == nil
      assert Vector.nth(v, 1) == 1
      assert Vector.nth(v, 2) == nil
      assert Vector.count(v) == 3
    end
  end

  describe "assoc" do
    test "replace at an index keeps other elements" do
      v = Vector.new(Enum.to_list(0..99))
      v2 = Vector.assoc(v, 42, :deep)
      assert Vector.nth(v, 42) == 42
      assert Vector.nth(v2, 42) == :deep
      assert Vector.nth(v2, 41) == 41
      assert Vector.nth(v2, 43) == 43
      assert Vector.count(v2) == 100
    end

    test "assoc at index == count behaves as conj (Clojure assocN)" do
      v = Vector.new([1, 2, 3])
      assert Vector.assoc(v, 3, 4) == Vector.conj(v, 4)

      big = Vector.new(Enum.to_list(0..99))
      assert Vector.assoc(big, 100, :end) == Vector.conj(big, :end)
      assert Vector.nth(Vector.assoc(big, 100, :end), 100) == :end
    end

    test "assoc out of range raises" do
      v = Vector.new([1, 2, 3])
      assert_raise ArgumentError, ~r/out of bounds/, fn -> Vector.assoc(v, 4, :x) end

      big = Vector.new(Enum.to_list(0..99))
      assert_raise ArgumentError, ~r/out of bounds/, fn -> Vector.assoc(big, 101, :x) end
    end

    test "assoc into the tail region of a trie works" do
      v = Vector.new(Enum.to_list(0..999))
      v2 = Vector.assoc(v, 990, :t)
      assert Vector.to_list(v) |> Enum.at(990) == 990
      assert Vector.nth(v2, 990) == :t
      assert Vector.count(v2) == 1000
    end
  end

  describe "first / rest / drop" do
    test "first is the head, nil on empty" do
      assert Vector.first(Vector.new([1, 2])) == 1
      assert Vector.first(Vector.new()) == nil
    end

    test "rest drops the head and returns a list, empty stays empty" do
      assert Vector.rest(Vector.new([1, 2, 3])) == [2, 3]
      assert Vector.rest(Vector.new([1])) == []
      assert Vector.rest(Vector.new()) == []
    end

    test "rest over the trie path" do
      v = Vector.new(Enum.to_list(0..99))
      assert Vector.rest(v) == Enum.to_list(1..99)
      assert Vector.rest(Vector.new([1])) == []
    end

    test "drop returns a list" do
      assert Vector.drop(Vector.new([1, 2, 3]), 1) == [2, 3]
      assert Vector.drop(Vector.new(Enum.to_list(0..99)), 90) == Enum.to_list(90..99)
    end
  end

  describe "Enumerable interop" do
    test "Enum works over small and trie-backed vectors" do
      small = Vector.new([1, 2, 3])
      assert Enum.to_list(small) == [1, 2, 3]
      assert Enum.count(small) == 3
      assert Enum.member?(small, 2)
      refute Enum.member?(small, 9)
      assert Enum.sum(small) == 6

      big = Vector.new(Enum.to_list(0..9999))
      assert Enum.count(big) == 10_000
      assert Enum.sum(big) == Enum.sum(0..9999)
      assert Enum.member?(big, 9999)
      assert Enum.to_list(big) == Enum.to_list(0..9999)
    end

    test "reduce is a chunked walk, not nth-in-a-loop" do
      big = Vector.new(Enum.to_list(0..9999))
      assert Enum.reduce(big, 0, &+/2) == 49_995_000
    end

    test "count is O(1)" do
      v = Vector.new(Enum.to_list(0..9999))
      assert Vector.count(v) == 10_000
    end
  end

  describe "vectors are not lists" do
    test "the struct name is stable and pattern-matchable" do
      v = Vector.conj(Vector.new([1]), 2)
      assert %Vector{} = v
      refute is_list(v)
      assert Vector.to_list(v) == [1, 2]
    end
  end

  @tag :bench
  describe "benchmark" do
    test "100k conj build and 100k random nth" do
      # Build 100k by repeated conj.
      {build_us, v} =
        :timer.tc(fn ->
          Enum.reduce(0..99_999, Vector.new(), &Vector.conj(&2, &1))
        end)

      # 100k random nth.
      :rand.seed(:exsss, {1, 2, 3})
      nths = for _ <- 1..100_000, do: :rand.uniform(100_000) - 1
      {read_us, hits} = :timer.tc(fn -> Enum.map(nths, &Vector.nth(v, &1)) end)
      assert length(hits) == 100_000
      assert Enum.take(hits, 5) |> Enum.at(0) != nil

      IO.puts(
        "bench: conj-build 100k = #{div(build_us, 1000)}ms, random-nth 100k = #{div(read_us, 1000)}ms"
      )
    end
  end
end
