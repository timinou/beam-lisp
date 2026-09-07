defmodule BeamLisp.CompilerData do
  @moduledoc """
  Eager traversals for finite compiler data. These do not realize LazySeq input
  or change the collection operations emitted into user programs.
  """

  alias BeamLisp.{RT, Vector}

  def eager_map(f, coll), do: Enum.map(eager_to_list(coll), &RT.invoke(f, [&1]))

  def eager_map(f, left, right) do
    Enum.zip(eager_to_list(left), eager_to_list(right))
    |> Enum.map(fn {a, b} -> RT.invoke(f, [a, b]) end)
  end

  def eager_filter(f, coll), do: Enum.filter(eager_to_list(coll), &RT.invoke(f, [&1]))

  def eager_concat(colls), do: colls |> eager_to_list() |> Enum.flat_map(&eager_to_list/1)

  def eager_mapcat(f, coll) do
    Enum.flat_map(eager_to_list(coll), fn item -> eager_to_list(RT.invoke(f, [item])) end)
  end

  def eager_map_indexed(f, coll) do
    coll |> eager_to_list() |> Enum.with_index()
    |> Enum.map(fn {value, index} -> RT.invoke(f, [index, value]) end)
  end

  def eager_sort_by(f, coll), do: Enum.sort_by(eager_to_list(coll), &RT.invoke(f, [&1]))

  def eager_group_by(f, coll) do
    # Compute keys in source order; reversing the input before grouping would
    # reverse key-function effects even if each resulting group looked correct.
    coll |> eager_to_list()
    |> Enum.reduce(%{}, fn item, groups ->
      key = RT.invoke(f, [item])
      Map.update(groups, key, [item], &[item | &1])
    end)
    |> Map.new(fn {key, values} -> {key, Enum.reverse(values)} end)
  end

  def eager_distinct(coll), do: coll |> eager_to_list() |> Enum.uniq()

  def eager_range(stop), do: eager_range(0, stop)
  def eager_range(start, stop) when is_integer(start) and is_integer(stop) do
    if start < stop, do: Enum.to_list(start..(stop - 1)), else: []
  end

  def eager_to_list(nil), do: []
  def eager_to_list(%Vector{items: items}) when is_tuple(items), do: Tuple.to_list(items)

  def eager_to_list(items) when is_list(items) do
    # is_list/1 also accepts improper cons cells. Validate the whole spine
    # before invoking callbacks, so malformed input cannot run partial effects.
    try do
      _ = length(items)
      items
    rescue
      ArgumentError -> invalid_input!()
    end
  end

  # is_map-ok: finite compiler dictionaries are raw maps; structs are explicitly excluded.
  def eager_to_list(items) when is_map(items) and not is_struct(items) do
    Enum.map(:maps.to_list(items), fn {key, value} -> Vector.new([key, value]) end)
  end

  def eager_to_list(_), do: invalid_input!()

  defp invalid_input! do
    raise ArgumentError, "compiler collection must be finite data (proper list, vector, map or nil), not LazySeq"
  end
end
