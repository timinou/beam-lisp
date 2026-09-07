alias BeamLisp.LazyMemo
LazyMemo.ensure_loaded!()
n = 100_000
r = LazyMemo.create(0)
tc = fn name, f ->
  {t, _} = :timer.tc(fn -> Enum.each(1..n, fn _ -> f.() end) end)
  IO.puts("INT|#{name}|ns_per_op=#{round(t * 1000 / n)}")
end
Process.put(:v, LazyMemo.nif_read_fast(r))
# Full fast CAS (succeeds every time)
tc.("cas_fast_ok", fn -> v = Process.get(:v); :ok = LazyMemo.nif_compare_exchange_fast(r, v, v + 1, [], 8, []); Process.put(:v, v + 1) end)
# CAS that FAILS the equality check: exercises lock + load + compare, no save/graph/reclaim
tc.("cas_fast_retry", fn -> :retry = LazyMemo.nif_compare_exchange_fast(r, :never, 1, [], 8, []) end)
# read_fast for reference (lock + load + copy-out)
tc.("read_fast", fn -> LazyMemo.nif_read_fast(r) end)
# A no-op cost of building the args (Vec<ResourceArc>, Vec<(pid,term)> decode)
tc.("nif_id_floor", fn -> LazyMemo.nif_id(r) end)
