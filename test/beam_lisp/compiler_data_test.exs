defmodule BeamLisp.CompilerDataTest do
  use ExUnit.Case, async: false
  alias BeamLisp.{CompilerData, LazySeq, Vector}

  test "finite collections and zipped mapping remain eager" do
    assert CompilerData.eager_map(&(&1 * 2), Vector.new([1, 2])) == [2, 4]
    assert CompilerData.eager_map(&+/2, [1, 2], [10]) == [11]
    assert CompilerData.eager_map(& &1, nil) == []
    assert CompilerData.eager_to_list(%{a: 1}) == [Vector.new([:a, 1])]
    assert CompilerData.eager_map_indexed(fn i, x -> {i, x} end, [:a, :b]) == [{0, :a}, {1, :b}]
  end

  test "mapping and grouping invoke callbacks once in source order" do
    for operation <- [&CompilerData.eager_map/2, &CompilerData.eager_group_by/2] do
      Process.put(:compiler_order, [])
      operation.(fn x ->
        Process.put(:compiler_order, [x | Process.get(:compiler_order)])
        rem(x, 2)
      end, [3, 1, 2])
      assert Process.get(:compiler_order) == [2, 1, 3]
    end
    assert CompilerData.eager_group_by(&rem(&1, 2), [3, 1, 2, 4]) == %{0 => [2, 4], 1 => [3, 1]}
  end

  test "filter truthiness, stable sort, and distinct preserve order" do
    assert CompilerData.eager_filter(& &1, [false, nil, 0, :ok]) == [0, :ok]
    assert CompilerData.eager_sort_by(&rem(&1, 2), [3, 1, 4, 2, 5]) == [4, 2, 3, 1, 5]
    assert CompilerData.eager_distinct([2, 1, 2, 3, 1]) == [2, 1, 3]
  end

  test "concat and mapcat preserve nested collection order" do
    assert CompilerData.eager_concat([nil, [1], Vector.new([2, 3]), []]) == [1, 2, 3]
    assert CompilerData.eager_mapcat(fn x -> [x, x + 1] end, [1, 3]) == [1, 2, 3, 4]
  end

  test "improper inputs are refused before invoking callbacks" do
    Process.put(:compiler_effect, false)
    assert_raise ArgumentError, ~r/finite data/, fn ->
      CompilerData.eager_map(fn _ -> Process.put(:compiler_effect, true) end, [1 | :tail])
    end
    refute Process.get(:compiler_effect)
  end

  test "lazy inputs and lazy mapcat results are not realized" do
    Process.put(:compiler_effect, false)
    lazy = LazySeq.new(fn -> Process.put(:compiler_effect, true); [1] end)
    for operation <- [fn -> CompilerData.eager_map(& &1, lazy) end,
                      fn -> CompilerData.eager_filter(& &1, lazy) end,
                      fn -> CompilerData.eager_concat([[0], lazy]) end,
                      fn -> CompilerData.eager_mapcat(fn _ -> lazy end, [0]) end] do
      assert_raise ArgumentError, ~r/LazySeq/, operation
      refute Process.get(:compiler_effect)
    end
  end

  test "callback exceptions preserve their original class and stop traversal" do
    Process.put(:compiler_order, [])
    assert catch_throw(CompilerData.eager_map(fn x ->
      Process.put(:compiler_order, [x | Process.get(:compiler_order)])
      if x == 2, do: throw(:stop), else: x
    end, [1, 2, 3])) == :stop
    assert Process.get(:compiler_order) == [2, 1]
    assert_raise FunctionClauseError, fn -> CompilerData.eager_map(fn :ok -> :ok end, [:bad]) end
  end

  test "finite ranges use exclusive endpoints and empty bounds" do
    assert CompilerData.eager_range(3) == [0, 1, 2]
    assert CompilerData.eager_range(2, 4) == [2, 3]
    assert CompilerData.eager_range(0) == []
    assert CompilerData.eager_range(4, 2) == []
  end
end
