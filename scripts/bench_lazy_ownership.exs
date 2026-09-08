# Run after building: mix run --no-compile --no-start scripts/bench_lazy_ownership.exs
# Samples measure map/count in fresh workers, not application startup.
alias BeamLisp.{LazyMemo, LazySeq, RT}

LazyMemo.ensure_loaded!()
for size <- [1_000, 2_000, 4_000, 8_000, 32_000] do
  samples = for _ <- 1..3 do
    Task.async(fn ->
      {elapsed, count} = :timer.tc(fn ->
        RT.map(fn value -> value + 1 end, Enum.to_list(1..size)) |> LazySeq.count()
      end)
      if count != size, do: raise("incorrect traversal count")
      elapsed
    end) |> Task.await(60_000)
  end
  IO.inspect(%{elements: size, samples_us: samples, median_us: Enum.at(Enum.sort(samples), 1)})
end

wait = fn wait, expected, deadline ->
  stats = LazyMemo.stats()
  cond do
    stats.live_cells == expected and stats.pending_reclaims == 0 -> stats
    System.monotonic_time(:millisecond) >= deadline -> raise "retention did not settle: #{inspect(stats)}"
    true -> Process.sleep(1); wait.(wait, expected, deadline)
  end
end

wait.(wait, 0, System.monotonic_time(:millisecond) + 5_000)
kept = LazySeq.new(fn -> :kept end)
:kept = LazySeq.force(kept)

for batch <- 1..3 do
  Task.async(fn ->
    Enum.each(1..20_000, fn value ->
      ^value = LazySeq.new(fn -> value end) |> LazySeq.force()
    end)
    :done
  end) |> Task.await(60_000)
  stats = wait.(wait, 1, System.monotonic_time(:millisecond) + 5_000)
  IO.inspect(Map.put(stats, :discarded_batch, batch))
  :kept = Task.async(fn -> LazySeq.force(kept) end) |> Task.await()
end
:kept = LazySeq.force(kept)
IO.puts("Ownership checks passed: discarded cells reclaimed; shared live value preserved")
