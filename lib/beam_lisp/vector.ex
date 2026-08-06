defmodule BeamLisp.Vector do
  @moduledoc """
  The persistent vector.

  Tuple-backed: `nth` is O(1), `conj` copies (O(n)) — right for the
  small vectors idiomatic Clojure favors; a HAMT is the perf upgrade
  path if profiling ever demands it. What matters semantically is
  that a vector is *not* a list: macros depend on the distinction,
  since macro output is data reinterpreted as forms.

  Implements `Enumerable`, so vectors flow straight into Elixir's
  `Enum` and `Stream` — interop in both directions.
  """

  defstruct items: {}

  @type t :: %__MODULE__{items: tuple}

  def new(items \\ []) when is_list(items), do: %__MODULE__{items: List.to_tuple(items)}

  def count(%__MODULE__{items: items}), do: tuple_size(items)

  def nth(%__MODULE__{items: items}, i) when i >= 0 and i < tuple_size(items), do: elem(items, i)
  def nth(%__MODULE__{}, _i), do: nil

  def first(%__MODULE__{} = v), do: nth(v, 0)

  def rest(%__MODULE__{} = v), do: v |> to_list() |> tl_or_empty()

  defp tl_or_empty([_ | t]), do: t
  defp tl_or_empty([]), do: []

  @doc "Clojure `conj`: append."
  def conj(%__MODULE__{items: items}, x), do: %__MODULE__{items: Tuple.insert_at(items, tuple_size(items), x)}

  def drop(%__MODULE__{} = v, n), do: v |> to_list() |> Enum.drop(n)

  def to_list(%__MODULE__{items: items}), do: Tuple.to_list(items)

  defimpl Enumerable do
    def count(v), do: {:ok, BeamLisp.Vector.count(v)}

    def member?(v, x), do: {:ok, Enum.member?(BeamLisp.Vector.to_list(v), x)}

    def reduce(v, acc, fun), do: Enumerable.List.reduce(BeamLisp.Vector.to_list(v), acc, fun)

    def slice(_v), do: {:error, __MODULE__}
  end
end
