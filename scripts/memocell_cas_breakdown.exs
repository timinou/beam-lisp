alias BeamLisp.LazyMemo
LazyMemo.ensure_loaded!()
n = 100_000
r = LazyMemo.create(0)
tc = fn name, f ->
  {t, _} = :timer.tc(fn -> Enum.each(1..n, fn _ -> f.() end) end)
  IO.puts("CAS|#{name}|ns_per_op=#{round(t * 1000 / n)}")
end

# 1. full public swap (read + exchange incl. Elixir walk + flat_size)
tc.("full_swap", fn -> v = LazyMemo.read(r); :ok = LazyMemo.exchange(r, v, v + 1, []) end)
# 2. raw NIF read only (dirty hop + env copy-out)
tc.("nif_read_only", fn -> LazyMemo.nif_read(r) end)
# 3. raw NIF CAS only, deps/estimate precomputed (dirty hop + save + graph lock)
v0 = LazyMemo.nif_read(r)
Process.put(:v, v0)
tc.("nif_cas_only", fn -> v = Process.get(:v); :ok = LazyMemo.nif_compare_exchange(r, v, v + 1, [], 8, []); Process.put(:v, v + 1) end)
# 3b. fast-lane raw NIFs (regular scheduler) — the new floor
tc.("nif_read_FAST", fn -> LazyMemo.nif_read_fast(r) end)
Process.put(:v, LazyMemo.nif_read_fast(r))
tc.("nif_cas_FAST", fn -> v = Process.get(:v); :ok = LazyMemo.nif_compare_exchange_fast(r, v, v + 1, [], 8, []); Process.put(:v, v + 1) end)
tc.("nif_lane", fn -> LazyMemo.nif_lane(r) end)
# 3c. LARGE cell: router must stay on the dirty lane (safety check)
big = LazyMemo.create(Map.new(1..50_000, fn i -> {i, i} end))
IO.puts("CAS|big_cell_lane|#{LazyMemo.nif_lane(big)}")
IO.puts("CAS|small_cell_lane|#{LazyMemo.nif_lane(r)}")
# 4. Elixir-side overhead alone: dependency walk + flat_size on a small int
tc.("elixir_walk+estimate", fn -> LazyMemo.dependencies(1); LazyMemo.estimate_bytes(1) end)
# 5. nif_stats (non-dirty NIF) — cost of a plain scheduler NIF crossing for reference
tc.("nif_stats_nondirty", fn -> LazyMemo.nif_stats() end)
# 6. nif_id (non-dirty, trivial) — floor for a regular-scheduler NIF call
tc.("nif_id_nondirty", fn -> LazyMemo.nif_id(r) end)
# 7. Agent baseline
{:ok, ag} = Agent.start_link(fn -> 0 end)
tc.("agent_update", fn -> Agent.update(ag, &(&1 + 1)) end)
# 8. :atomics — true lock-free BEAM primitive floor
a = :atomics.new(1, [])
tc.("atomics_add", fn -> :atomics.add(a, 1, 1) end)
