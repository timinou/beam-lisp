defmodule BeamLisp.PerfProbe do
  @moduledoc """
  A throwaway stage-timing accumulator for profiling hot bl pipelines.

  `mark(stage, micros)` adds `micros` to a per-stage running total (and bumps a
  call count) in an ETS table; `dump/0` returns the totals; `reset/0` clears them.
  Deliberately trivial and side-effecting — it exists to answer "where does the
  time go" with real numbers, then be deleted. NOT part of the datom pipeline's
  contract; the `mark` calls are removed once the profiling is done.
  """

  @tab :beam_lisp_perf_probe

  # Owned by the pinned Loader.Server so a probe table created inside a
  # short-lived process (a parallel-build worker, an async test fork) does
  # not vanish with it. See BeamLisp.Native.table/0.
  defp tab do
    case :ets.whereis(@tab) do
      :undefined ->
        BeamLisp.Loader.Server.run(fn ->
          try do
            :ets.new(@tab, [:public, :named_table, :set])
          rescue
            ArgumentError -> :ok
          end
        end)

        @tab

      _ ->
        @tab
    end
  end

  @doc "Add `micros` to `stage`'s total and bump its call count."
  def mark(stage, micros) do
    tab()
    :ets.update_counter(@tab, stage, [{2, micros}, {3, 1}], {stage, 0, 0})
    :ok
  end

  @doc "Every stage's `{stage, total_micros, calls}`, highest total first."
  def dump do
    tab()
    :ets.tab2list(@tab)
    |> Enum.sort_by(fn {_s, total, _n} -> -total end)
  end

  @doc "Clear all accumulated timings."
  def reset do
    tab()
    :ets.delete_all_objects(@tab)
    :ok
  end
end
