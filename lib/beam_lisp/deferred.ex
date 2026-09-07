defmodule BeamLisp.Delay do
  @moduledoc """
  Clojure's `delay`: a computation deferred until the first `force`, then
  remembered. Backed by a `BeamLisp.LazySeq` cell, so it inherits that cell's
  entire force machine — shared result, one run under concurrent force
  (thundering-herd protection), retryable failure, cycle rejection — without a
  second implementation.

  A delay is NOT a sequence. It carries its own struct so `first`/`rest`/`Enum`
  never treat it as one, and so `deref`/`force`/`realized?` dispatch on it
  cleanly. The value it produces may itself be a vector, a map, or a seq; it is
  returned exactly as the body produced it, never normalized into a cons cell.
  """
  defstruct [:seq]
end

defmodule BeamLisp.Deferred do
  @moduledoc """
  `delay` / `force` / `realized?` / `memoize`, all over one memo cell.

  These are the value-shaped face of the same native cell that backs lazy
  sequences. `delay` remembers one value; `memoize` remembers one value per
  argument key. Both get shared-once evaluation and herd protection from the
  cell, not from new machinery here.
  """
  alias BeamLisp.{Delay, LazySeq}

  @doc "Wrap a zero-arg thunk in a `Delay`. The body runs at most once, on first force."
  def delay(thunk) when is_function(thunk, 0), do: %Delay{seq: LazySeq.new(thunk)}

  @doc """
  Force a delay to its value, remembered thereafter. `force` of a non-delay
  returns it unchanged, matching Clojure — so `force` is safe to apply to a
  value that may or may not be a delay.
  """
  def force(%Delay{seq: seq}), do: LazySeq.force(seq)
  def force(other), do: other

  @doc "Whether a delay has already produced its value. A non-delay is trivially realized."
  def realized?(%Delay{seq: seq}) do
    case LazySeq.memo_state(seq) do
      {:completed, _} -> true
      _ -> false
    end
  end

  def realized?(_), do: true

  @doc "True for a `Delay`."
  def delay?(%Delay{}), do: true
  def delay?(_), do: false
end
