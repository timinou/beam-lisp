defmodule BeamLisp.ExInfo do
  @moduledoc """
  Exceptions for beam-lisp `throw`/`try`.

  `throw` compiles to `BeamLisp.ExInfo.raise_payload/1`, and `try`'s
  untyped catch binds the raised value (or a normalized Erlang error)
  as `e`. `ex-info`/`ex-data`/`ex-message` mirror Clojure's, so a
  thrown payload survives the round trip through an exception.
  """

  defexception [:message, :data]

  @doc "Build an exception carrying arbitrary data."
  def ex_info(msg, data), do: %__MODULE__{message: msg, data: data}

  @doc "The `data` of an ExInfo exception; nil for any other value."
  def ex_data(e), do: if(is_struct(e, __MODULE__), do: e.data, else: nil)

  @doc "A readable message for any value: exceptions via Exception.message, else inspect."
  def ex_message(e), do: if(is_exception(e), do: Exception.message(e), else: inspect(e))

  @doc """
  Raise a value as an exception, so `try` can catch it.

  An existing exception is re-raised as-is; a map becomes an ExInfo
  carrying it as `data`; anything else becomes an ExInfo with a
  printed message and no data.
  """
  def raise_payload(x) do
    cond do
      is_exception(x) ->
        raise x

      is_map(x) ->
        raise %__MODULE__{message: BeamLisp.RT.print_str(x), data: x}

      true ->
        raise %__MODULE__{message: inspect(x), data: nil}
    end
  end
end
