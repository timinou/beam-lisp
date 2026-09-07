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
