defmodule MemoProto do
  @moduledoc """
  Seven prototypes measuring the MemoCell NIF's generalizable capabilities
  against fair BEAM-native baselines. Prototypes-first: does NOT touch the
  boot-critical LazySeq path. Uses only the existing public LazyMemo API.
  """
  alias BeamLisp.{LazyMemo, LazySeq, SeqCursor}

  def mb(bytes), do: Float.round(bytes / 1_048_576, 2)
  def us(t), do: Float.round(t / 1, 0)
  def flat_bytes(term), do: :erts_debug.flat_size(term) * :erlang.system_info(:wordsize)

  defp gc_all do
    for p <- Process.list(), do: (try do :erlang.garbage_collect(p) rescue _ -> :ok catch _,_ -> :ok end)
    :erlang.garbage_collect()
    Process.sleep(50)
  end

  # ---- swap! implemented on the CAS primitive ----
  def swap(r, f) do
    cur = LazyMemo.read(r)
    case LazyMemo.exchange(r, cur, f.(cur), []) do
      :ok -> :ok
      :retry -> swap(r, f)
      :cycle -> raise "cycle"
    end
  end

  # =====================================================================
  # A. Shared large immutable: HOLDING cost across many processes.
  #    copy-per-process (message send) vs one cell + N cheap references.
  # =====================================================================
  def proto_a do
  n = 500
  big = Map.new(1..50_000, fn i -> {i, {i, i * 2, "v#{i}"}} end)
  size = flat_bytes(big)
  expected_copies_mb = mb(size * n)

  gc_all()
  base = :erlang.memory(:total)
  copies = for _ <- 1..n do
    spawn(fn -> receive do {:hold, t} -> Process.put(:t, t); receive do :stop -> :ok end end end)
  end
  for p <- copies, do: send(p, {:hold, big})
  Process.sleep(200); gc_all()
  copy_delta = :erlang.memory(:total) - base
  for p <- copies, do: send(p, :stop)
  Process.sleep(100); gc_all()

  base2 = :erlang.memory(:total)
  cell = LazyMemo.create(big)
  holders = for _ <- 1..n do
    spawn(fn -> receive do {:hold, r} -> Process.put(:r, r); receive do :stop -> :ok end end end)
  end
  for p <- holders, do: send(p, {:hold, cell})
  Process.sleep(200); gc_all()
  cell_delta = :erlang.memory(:total) - base2
  for p <- holders, do: send(p, :stop)
  _ = cell

  cd = max(cell_delta, 0)
  IO.puts("A|value_bytes=#{size}|n=#{n}|expected_if_copied_mb=#{expected_copies_mb}|copy_delta_mb=#{mb(copy_delta)}|cell_delta_mb=#{mb(cd)}|copies_held_equiv=#{Float.round(copy_delta/size,1)}")
end

  # =====================================================================
  # B. Mutable ref: CAS swap! vs Agent (general term ref baseline).
  # =====================================================================
  def proto_b do
    iters = 100_000
    r = LazyMemo.create(0)
    swap(r, fn _ -> 0 end)
    {t_cas, _} = :timer.tc(fn -> Enum.each(1..iters, fn _ -> swap(r, &(&1 + 1)) end) end)

    {:ok, ag} = Agent.start_link(fn -> 0 end)
    {t_ag, _} = :timer.tc(fn -> Enum.each(1..iters, fn _ -> Agent.update(ag, &(&1 + 1)) end) end)
    Agent.stop(ag)

    IO.puts("B|iters=#{iters}|cas_us=#{us(t_cas)}|agent_us=#{us(t_ag)}|cas_ops_per_s=#{round(iters/(t_cas/1_000_000))}|agent_ops_per_s=#{round(iters/(t_ag/1_000_000))}")
  end

  # =====================================================================
  # C. Herd protection: N concurrent forcers of ONE shared LazySeq
  #    compute the body ONCE; independent callers compute N times.
  # =====================================================================
  def proto_c do
  n = 200
  ctr = :counters.new(1, [])
  work = fn ->
    :counters.add(ctr, 1, 1)
    Process.sleep(30)
    :done
  end

  lazy = LazySeq.new(fn -> [work.()] end)
  parent = self()
  await = fn -> Enum.each(1..n, fn _ -> receive do (:ok -> :ok) end end) end
  {t_shared, _} = :timer.tc(fn ->
    for _ <- 1..n, do: spawn(fn -> LazySeq.to_list(lazy); send(parent, :ok) end)
    await.()
  end)
  shared_runs = :counters.get(ctr, 1)

  ctr2 = :counters.new(1, [])
  work2 = fn -> :counters.add(ctr2, 1, 1); Process.sleep(30); :done end
  {t_indep, _} = :timer.tc(fn ->
    for _ <- 1..n, do: spawn(fn -> work2.(); send(parent, :ok) end)
    await.()
  end)
  indep_runs = :counters.get(ctr2, 1)

  IO.puts("C|n=#{n}|shared_runs=#{shared_runs}|indep_runs=#{indep_runs}|shared_ms=#{round(t_shared/1000)}|indep_ms=#{round(t_indep/1000)}")
end

  # =====================================================================
  # D. Dependency graph: registration cost + cycle rejection.
  #    (Honest: reverse-edge invalidation is NOT in the NIF.)
  # =====================================================================
  def proto_d do
    depth = 2000
    {t_build, chain} = :timer.tc(fn ->
      Enum.reduce(1..depth, [], fn i, acc ->
        dep = case acc do [h | _] -> {:node, i, h}; [] -> {:node, i} end
        [LazyMemo.create(dep) | acc]
      end)
    end)
    # chain head depends transitively on all others; try to close a cycle:
    [head | _] = chain
    tail = List.last(chain)
    {t_cyc, res} = :timer.tc(fn ->
      LazyMemo.exchange(tail, LazyMemo.read(tail), {:back, head}, [])
    end)
    IO.puts("D|depth=#{depth}|build_us=#{us(t_build)}|cycle_check_us=#{us(t_cyc)}|cycle_result=#{inspect(res)}")
  end

  # =====================================================================
  # E. Off-heap cursor: consumer process heap when iterating 1M items.
  #    heap-resident list vs SeqCursor (<=1 chunk of 32 on heap).
  # =====================================================================
  def proto_e do
    big = Enum.to_list(1..1_000_000)
    parent = self()

    spawn(fn ->
      list = big
      _ = Enum.reduce(list, 0, &+/2)
      {:total_heap_size, words} = Process.info(self(), :total_heap_size)
      send(parent, {:list_heap, words * :erlang.system_info(:wordsize)})
    end)
    list_heap = receive do {:list_heap, b} -> b end

    spawn(fn ->
      cur = SeqCursor.new(big)
      _ = Enum.reduce(cur, 0, &+/2)
      {:total_heap_size, words} = Process.info(self(), :total_heap_size)
      send(parent, {:cur_heap, words * :erlang.system_info(:wordsize)})
    end)
    cur_heap = receive do {:cur_heap, b} -> b end

    IO.puts("E|items=1000000|list_consumer_heap_mb=#{mb(list_heap)}|cursor_consumer_heap_mb=#{mb(cur_heap)}|ratio=#{Float.round(list_heap/max(cur_heap,1),1)}")
  end

  # =====================================================================
  # F. Live memory accounting via nif_stats (no manual walking).
  # =====================================================================
  def proto_f do
  gc_all()
  s0 = LazyMemo.stats()
  # flat term (~100KB flat) so accounting reflects real retained size;
  # refc binaries live off the flat heap and would under-report.
  mk = fn seed -> Enum.map(1..3000, fn i -> {i, i * seed, i + seed} end) end
  k = 100
  cells = for j <- 1..k, do: LazyMemo.create({:blob, mk.(j)})
  Process.sleep(50)
  s1 = LazyMemo.stats()
  keep = :erlang.term_to_binary(length(cells))
  # drop references and let the reclaimer run
  _dropped = Enum.map(cells, fn _ -> nil end)
  gc_all(); Process.sleep(150); gc_all()
  s2 = LazyMemo.stats()
  _ = keep
  IO.puts("F|created=#{k}|cells_before=#{s0.live_cells}|cells_peak=#{s1.live_cells}|cells_after=#{s2.live_cells}|retained_before_mb=#{mb(s0.retained_bytes)}|retained_peak_mb=#{mb(s1.retained_bytes)}|retained_after_mb=#{mb(s2.retained_bytes)}")
end

  # =====================================================================
  # G. Off-scheduler reclaim: dropping a huge cell returns fast;
  #    actual free happens on the reclaimer thread (pending_reclaims).
  # =====================================================================
  def proto_g do
  # a large, deep term
  mk = fn -> Enum.map(1..200_000, fn i -> {i, "s#{i}", [i, i+1, i+2]} end) end
  huge = mk.()
  sz = flat_bytes(huge)

  # baseline: free a plain BEAM term of same shape on the caller — the walk
  # to free it happens inline on this scheduler.
  plain_owner = spawn(fn ->
    _t = mk.()
    receive do :go -> :ok end
    {t, _} = :timer.tc(fn -> :erlang.garbage_collect() end)
    send(:erlang.whereis(:proto_g_parent) || self(), {:plain, t})
  end)
  Process.register(self(), :proto_g_parent)
  send(plain_owner, :go)
  t_plain = receive do {:plain, t} -> t after 5000 -> -1 end

  # cell: dropping the handle returns immediately; free is deferred to the
  # reclaimer thread. Poll pending_reclaims to observe the deferral.
  cell_owner = spawn(fn ->
    c = LazyMemo.create(mk.())
    _ = c
    receive do :go -> :ok end
    {t, _} = :timer.tc(fn -> :erlang.garbage_collect() end)
    send(:erlang.whereis(:proto_g_parent), {:cell, t})
  end)
  send(cell_owner, :go)
  t_cell = receive do {:cell, t} -> t after 5000 -> -1 end
  max_pending = Enum.reduce(1..50, 0, fn _, acc ->
    p = LazyMemo.stats().pending_reclaims
    Process.sleep(1); max(acc, p)
  end)
  Process.unregister(:proto_g_parent)
  _ = huge
  IO.puts("G|huge_bytes=#{sz}|plain_owner_gc_us=#{us(t_plain)}|cell_owner_gc_us=#{us(t_cell)}|max_pending_observed=#{max_pending}")
end

  def run do
    IO.puts("=== MEMOCELL PROTOTYPES START ===")
    for {name, f} <- [a: &proto_a/0, b: &proto_b/0, c: &proto_c/0, d: &proto_d/0, e: &proto_e/0, f: &proto_f/0, g: &proto_g/0] do
      try do f.() rescue e -> IO.puts("#{name}|ERROR|#{Exception.message(e)}") catch k,v -> IO.puts("#{name}|CATCH|#{inspect({k,v})}") end
    end
    IO.puts("=== MEMOCELL PROTOTYPES END ===")
  end
end

BeamLisp.LazyMemo.ensure_loaded!()
MemoProto.run()
