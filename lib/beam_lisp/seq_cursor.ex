defmodule BeamLisp.SeqCursor do
  @moduledoc false
  # Finite eager inputs are copied into native storage once, not once for every
  # deferred tail. Each cursor keeps at most one small chunk on the BEAM heap.
  # `dirty` is the source's lane decision, made ONCE by the native cursor at
  # creation (a chunk of large elements takes the dirty scheduler; a normal
  # chunk of <=32 small heads takes the fast one). It is copied onto every
  # sub-cursor so the whole walk uses the lane the source's shape demands.
  defstruct chunk: [], tail: nil, dirty: false

  def new(list) do
    resource = BeamLisp.LazyMemo.cursor(list)
    %__MODULE__{tail: resource, dirty: BeamLisp.LazyMemo.cursor_dirty_chunks?(resource)}
  end

  def cell(%__MODULE__{chunk: [head | rest]} = cursor),
    do: [head | %{cursor | chunk: rest}]

  def cell(%__MODULE__{chunk: [], tail: nil}), do: nil

  def cell(%__MODULE__{chunk: [], tail: resource, dirty: dirty}) do
    {chunk, tail} = BeamLisp.LazyMemo.cursor_chunk(resource, dirty)
    cell(%__MODULE__{chunk: chunk, tail: tail, dirty: dirty})
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
