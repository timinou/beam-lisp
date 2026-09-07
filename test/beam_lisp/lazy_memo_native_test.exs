defmodule BeamLisp.LazyMemoNativeTest do
  use ExUnit.Case, async: false
  alias BeamLisp.{LazyMemo, LazySeq}

  setup do
    LazyMemo.ensure_loaded!()
    :ok
  end

  test "CAS compares exactly and notifies only a committed transition" do
    resource = LazyMemo.create({:value, 1})
    tag = make_ref()
    assert :retry = LazyMemo.exchange(resource, {:value, 1.0}, :wrong, [{self(), tag}])
    refute_received ^tag
    assert {:value, 1} = LazyMemo.read(resource)
    assert :ok = LazyMemo.exchange(resource, {:value, 1}, :right, [{self(), tag}])
    assert_receive ^tag
    assert :right = LazyMemo.read(resource)
  end

  test "bare handles are tracked and cycles do not change the cell" do
    a = LazyMemo.create(:pending)
    b = LazyMemo.create({:child, a})
    assert LazyMemo.dependencies({b, make_ref()}) == [b]
    assert :cycle = LazyMemo.exchange(a, :pending, {:child, b})
    assert :pending = LazyMemo.read(a)
  end

  test "metadata dependencies cannot conceal a cycle" do
    root = LazySeq.new(fn -> :root end)
    other = LazySeq.new(fn -> :other end)
    wrapped = %{other | metadata: %{root: root}}

    assert :cycle =
             LazyMemo.exchange(root.resource, LazyMemo.read(root.resource), {:completed, wrapped})

    assert {:pending, _} = LazyMemo.read(root.resource)
  end

  test "a result that refers to its evaluator is rejected on the first force" do
    holder = :ets.new(:cyclic_result_fixture, [:public])

    lazy =
      LazySeq.new(fn ->
        [{:value, value}] = :ets.lookup(holder, :value)
        value
      end)

    :ets.insert(holder, {:value, lazy})
    assert_raise LazySeq.ForceError, ~r/cyclic_memo/, fn -> LazySeq.force(lazy) end
    assert {:terminal, :cyclic_memo} = LazySeq.memo_state(lazy)
    :ets.delete(holder)
  end

  test "failure diagnostics cannot retain their own memo" do
    holder = :ets.new(:cyclic_error_fixture, [:public])

    lazy =
      LazySeq.new(fn ->
        [{:value, value}] = :ets.lookup(holder, :value)
        throw(value)
      end)

    :ets.insert(holder, {:value, lazy})
    assert_raise LazySeq.ForceError, ~r/cyclic_memo/, fn -> LazySeq.force(lazy) end
    assert {:terminal, :cyclic_memo} = LazySeq.memo_state(lazy)
    :ets.delete(holder)
  end

  test "an attached waiter sees its failed attempt after owner exit and a successful retry" do
    parent = self()
    calls = :atomics.new(1, [])

    lazy =
      LazySeq.new(fn ->
        if :atomics.add_get(calls, 1, 1) == 1 do
          send(parent, {:started, self()})
          receive do: (:release -> raise("first attempt"))
        else
          :recovered
        end
      end)

    capture = fn ->
      try do
        {:ok, LazySeq.force(lazy)}
      rescue
        e -> {:error, Exception.message(e)}
      end
    end

    owner = Task.async(capture)
    assert_receive {:started, owner_pid}
    waiter = Task.async(capture)
    await_registered(lazy, System.monotonic_time(:millisecond) + 5000)
    :erlang.suspend_process(waiter.pid)
    send(owner_pid, :release)
    assert Task.await(owner) == {:error, "first attempt"}
    assert LazySeq.force(lazy) == :recovered
    :erlang.resume_process(waiter.pid)
    assert Task.await(waiter) == {:error, "first attempt"}
    assert :atomics.get(calls, 1) == 2
  end

  defp await_registered(lazy, deadline) do
    case LazySeq.memo_state(lazy) do
      {:running, _, _, _, [_ | _]} ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline, "waiter failed to register"
        :erlang.yield()
        await_registered(lazy, deadline)
    end
  end

  # ---- scheduler lanes: one cell, two lanes, chosen by measured size ----

  test "small cells route to the fast lane; large cells stay dirty" do
    small = LazyMemo.create({:value, 1})
    assert :fast = LazyMemo.nif_lane(small)

    big = LazyMemo.create(Map.new(1..50_000, fn i -> {i, i} end))
    assert :dirty = LazyMemo.nif_lane(big)
    # both lanes read the same value
    assert {:value, 1} = LazyMemo.read(small)
    assert LazyMemo.read(big) == LazyMemo.nif_read(big)
  end

  test "fast CAS reroutes on a large replacement and on a NEW dependency edge" do
    small = LazyMemo.create(:a)
    big_term = Map.new(1..50_000, fn i -> {i, i} end)
    big_bytes = LazyMemo.estimate_bytes(big_term)
    assert :reroute = LazyMemo.nif_compare_exchange_fast(small, :a, big_term, [], big_bytes, [])
    # untouched
    assert :a = LazyMemo.read(small)

    other = LazyMemo.create(:o)
    # adding a brand-new edge is unbounded cycle-walk work: not fast-lane
    assert :reroute = LazyMemo.nif_compare_exchange_fast(small, :a, {:dep, other}, [other], 16, [])
    assert :a = LazyMemo.read(small)

    # the public router transparently completes both through the dirty lane
    assert :ok = LazyMemo.exchange(small, :a, {:dep, other})
    assert {:dep, ^other} = LazyMemo.read(small)
  end

  test "fast lane preserves CAS exactness and single-shot notification" do
    r = LazyMemo.create(0)
    assert :fast = LazyMemo.nif_lane(r)
    tag = make_ref()
    assert :retry = LazyMemo.exchange(r, 0.0, 1, [{self(), tag}])
    refute_received ^tag
    assert :ok = LazyMemo.exchange(r, 0, 1, [{self(), tag}])
    assert_receive ^tag
    assert 1 = LazyMemo.read(r)
  end

  test "a cell that grows past the ceiling migrates lanes and stays correct" do
    r = LazyMemo.create(0)
    assert :fast = LazyMemo.nif_lane(r)
    big = Enum.to_list(1..100_000)
    assert :ok = LazyMemo.exchange(r, 0, big)
    assert :dirty = LazyMemo.nif_lane(r)
    assert ^big = LazyMemo.read(r)
    assert :ok = LazyMemo.exchange(r, big, 1)
    assert :fast = LazyMemo.nif_lane(r)
    assert 1 = LazyMemo.read(r)
  end

  test "fast lane ceiling is tunable and accounting survives inline reclaim" do
    old = LazyMemo.fast_lane_bytes()
    try do
      r = LazyMemo.create(0)
      # lower the ceiling below any real term: everything becomes dirty
      LazyMemo.set_fast_lane_bytes(0)
      assert :dirty = LazyMemo.nif_lane(r)
      assert :ok = LazyMemo.exchange(r, 0, 1)
      assert 1 = LazyMemo.read(r)
    after
      LazyMemo.set_fast_lane_bytes(old)
    end

    # churn a small cell through the fast lane; retained bytes must not drift
    r = LazyMemo.create(0)
    before = LazyMemo.stats().retained_bytes
    Enum.reduce(1..1000, 0, fn i, v -> :ok = LazyMemo.exchange(r, v, i); i end)
    after_bytes = LazyMemo.stats().retained_bytes
    assert abs(after_bytes - before) < 1024
  end

  test "finite inputs use immutable shared storage and preserve all values" do
    values = Enum.to_list(1..1000)
    input = LazySeq.input(values)
    assert %BeamLisp.SeqCursor{} = input
    source = LazyMemo.nif_dependency_resource(input.tail)
    assert_raise ArgumentError, fn -> LazyMemo.compare_exchange(source, values, [], [], 0) end
    assert Enum.to_list(input) == values
    assert BeamLisp.RT.map(&(&1 + 1), values) |> Enum.to_list() == Enum.to_list(2..1001)

    assert BeamLisp.RT.filter(&(rem(&1, 2) == 0), values) |> Enum.to_list() ==
             Enum.filter(values, &(rem(&1, 2) == 0))

    assert BeamLisp.RT.map_multi(&+/2, values, [values]) |> Enum.to_list() ==
             Enum.map(values, &(&1 * 2))

    assert BeamLisp.RT.concat([values, values]) |> Enum.to_list() == values ++ values
    assert BeamLisp.RT.take_while(&(&1 < 500), values) |> Enum.to_list() == Enum.to_list(1..499)
    assert BeamLisp.RT.cycle(values) |> Enum.take(2001) == values ++ values ++ [1]
  end

  test "lazy and improper inputs are not prematurely forced by cursor conversion" do
    calls = :atomics.new(1, [])

    tail =
      LazySeq.new(fn ->
        :atomics.add(calls, 1, 1)
        Enum.to_list(2..1000)
      end)

    mapped = BeamLisp.RT.map(&(&1 + 1), [1 | tail])
    assert :atomics.get(calls, 1) == 0
    assert Enum.to_list(mapped) == Enum.to_list(2..1001)
    assert :atomics.get(calls, 1) == 1
  end

  test "admission collects unreachable handles rather than rejecting reclaimable memory" do
    previous = Application.get_env(:beam_lisp, :lazy_cache_budget_bytes)
    on_exit(fn ->
      if previous == nil, do: Application.delete_env(:beam_lisp, :lazy_cache_budget_bytes),
        else: Application.put_env(:beam_lisp, :lazy_cache_budget_bytes, previous)
    end)
    baseline = LazyMemo.stats().retained_bytes
    Application.put_env(:beam_lisp, :lazy_cache_budget_bytes, baseline + 10_000)
    result = Task.async(fn ->
      Process.flag(:min_heap_size, 1_000_000)
      :erlang.garbage_collect()
      Enum.each(1..2000, fn _ -> LazyMemo.create(:discarded) end)
      LazySeq.new(fn -> :accepted end) |> LazySeq.force()
    end) |> Task.await(10_000)
    assert result == :accepted
  end

  @tag timeout: 60_000
  test "native library repeatedly unloads after reclamation without a stray thread" do
    script = """
    for _ <- 1..3 do
      parent = self()
      {pid, monitor} = spawn_monitor(fn ->
        for _ <- 1..1000, do: BeamLisp.LazyMemo.create(:temporary)
        send(parent, :created)
      end)
      receive do :created -> :ok end
      receive do {:DOWN, ^monitor, :process, ^pid, :normal} -> :ok end
      wait = fn wait, n ->
        stats = BeamLisp.LazyMemo.stats()
        if stats.live_cells == 0 and stats.pending_reclaims == 0 do
          :ok
        else
          if n == 0, do: raise("reclamation did not finish")
          Process.sleep(1)
          wait.(wait, n - 1)
        end
      end
      wait.(wait, 5000)
      true = :code.delete(BeamLisp.LazyMemo)
      :code.purge(BeamLisp.LazyMemo)
    end
    IO.puts("unload-ok")
    """

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        ["-pa", Mix.Project.compile_path(), "-e", script], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "unload-ok"
  end
end
