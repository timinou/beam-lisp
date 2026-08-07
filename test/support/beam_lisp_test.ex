defmodule BeamLisp.Test do
  @moduledoc """
  Test-suite helpers.

  `realize/1` forces a lazy seq (or a partially-realized improper list) to a
  proper list so an ExUnit assertion can compare VALUES with Elixir's `==`.
  A `%BeamLisp.LazySeq{}` struct cannot overload `Kernel.==`, so a fn that
  now returns a lazy seq (beam-lisp's seq fns are uniformly lazy) would
  fail a plain `assert eval(...) == [list]`. The prelude/wave assertions
  were always about values; comparing a lazy result structurally was an
  accident of how they were written, not a semantic claim.
  """

  alias BeamLisp.LazySeq

  @doc "Realize a lazy/improper seq to a proper list; other values pass through unchanged."
  def realize(%LazySeq{} = l), do: LazySeq.to_list(l)
  def realize(x) when is_list(x), do: if(improper?(x), do: LazySeq.to_list(x), else: x)
  def realize(x), do: x

  defp improper?([_ | t]), do: improper_tail?(t)
  defp improper?(_), do: false
  defp improper_tail?(nil), do: false
  defp improper_tail?([]), do: false
  defp improper_tail?(%LazySeq{}), do: true
  defp improper_tail?([_ | t]), do: improper_tail?(t)
end
