defmodule BeamLisp.SeqCursor do
  @moduledoc false
  # Finite eager inputs are copied into native storage once, not once for every
  # deferred tail. Each cursor keeps at most one small chunk on the BEAM heap.
  defstruct chunk: [], tail: nil

  def new(list), do: %__MODULE__{tail: BeamLisp.LazyMemo.cursor(list)}

  def cell(%__MODULE__{chunk: [head | rest]} = cursor),
    do: [head | %{cursor | chunk: rest}]

  def cell(%__MODULE__{chunk: [], tail: nil}), do: nil

  def cell(%__MODULE__{chunk: [], tail: resource}) do
    {chunk, tail} = BeamLisp.LazyMemo.cursor_chunk(resource)
    cell(%__MODULE__{chunk: chunk, tail: tail})
  end

  defimpl Enumerable do
    def count(_cursor), do: {:error, __MODULE__}
    def member?(_cursor, _value), do: {:error, __MODULE__}
    def slice(_cursor), do: {:error, __MODULE__}
    def reduce(_cursor, {:halt, acc}, _fun), do: {:halted, acc}

    def reduce(cursor, {:suspend, acc}, fun),
      do: {:suspended, acc, &reduce(cursor, &1, fun)}

    def reduce(cursor, {:cont, acc}, fun) do
      case BeamLisp.SeqCursor.cell(cursor) do
        nil -> {:done, acc}
        [head | tail] -> reduce(tail, fun.(head, acc), fun)
      end
    end
  end
end
