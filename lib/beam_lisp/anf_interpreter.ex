defmodule BeamLisp.AnfInterpreter do
  @moduledoc false

  # The reference interpreter models Core's raw trace binding with a tagged
  # frame list. It must never pass this model to the BEAM raw_raise primop.
  def capture(fun) do
    {:ok, BeamLisp.RT.invoke(fun, [])}
  catch
    kind, reason -> {:raised, kind, reason, {:interpreted_trace, __STACKTRACE__}}
  end

  def reraise(kind, reason, {:interpreted_trace, frames}) do
    :erlang.raise(kind, reason, frames)
  end
end
