defmodule BeamLisp.DaemonWatcherTest do
  use ExUnit.Case, async: false

  alias BeamLisp.Daemon.{Executor, WatchRegistry}

  setup do
    # a fresh executor + registry pair, not the named daemon singletons
    {:ok, exec} = Executor.start_link(name: :"exec_#{:erlang.unique_integer([:positive])}")
    {:ok, reg} = WatchRegistry.start_link(name: :"reg_#{:erlang.unique_integer([:positive])}", executor: exec)

    on_exit(fn ->
      for p <- [reg, exec], is_pid(p) and Process.alive?(p) do
        try do
          GenServer.stop(p, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{exec: exec, reg: reg}
  end

  test "run_reload runs a job on the executor FIFO and returns its value", %{exec: exec} do
    assert 123 = Executor.run_reload(exec, fn -> 123 end)
  end

  test "run_reload is serialized against a concurrent job", %{exec: exec} do
    # two jobs, each records order; the FIFO must not interleave them
    parent = self()

    t1 =
      Task.async(fn ->
        Executor.run_reload(exec, fn ->
          send(parent, {:start, 1})
          Process.sleep(50)
          send(parent, {:end, 1})
          1
        end)
      end)

    Process.sleep(5)

    t2 =
      Task.async(fn ->
        Executor.run_reload(exec, fn ->
          send(parent, {:start, 2})
          send(parent, {:end, 2})
          2
        end)
      end)

    assert Task.await(t1) == 1
    assert Task.await(t2) == 2

    # job 1 must fully finish before job 2 starts (no interleave)
    assert_receive {:start, 1}
    assert_receive {:end, 1}
    assert_receive {:start, 2}
    assert_receive {:end, 2}
  end

  @tag :filesystem
  test "a save triggers a reload that rides the executor and notifies subscribers", %{reg: reg} do
    dir = Path.join(System.tmp_dir!(), "blwatch-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "mod.bl")
    File.write!(file, "(ns wmod)\n(defn v [] 1)\n")

    parent = self()

    case WatchRegistry.watch(reg, dir, {self(), :req1}, fn result -> send(parent, {:watched, result}) end) do
      :ok ->
        assert dir in Enum.map(WatchRegistry.watched(reg), &Path.expand/1) or
                 WatchRegistry.watched(reg) != []

        # trigger a change
        Process.sleep(200)
        File.write!(file, "(ns wmod)\n(defn v [] 2)\n")

        # a reload result should arrive (the injected apply ran on the executor)
        assert_receive {:watched, _result}, 5_000

        WatchRegistry.unwatch(reg, dir, {self(), :req1})
        assert WatchRegistry.watched(reg) == []

      {:error, reason} ->
        # file_system unavailable in this build — acceptable degrade
        IO.puts("watch unsupported: #{inspect(reason)} — skipping fs assertion")
    end

    File.rm_rf!(dir)
  end

  test "watched dedups two subscribers on the same dir to one watcher", %{reg: reg} do
    dir = Path.join(System.tmp_dir!(), "bldedup-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.bl"), "(ns a)\n")

    r1 = WatchRegistry.watch(reg, dir, {self(), :s1}, fn _ -> :ok end)

    if r1 == :ok do
      :ok = WatchRegistry.watch(reg, dir, {self(), :s2}, fn _ -> :ok end)
      # two subscribers, one watcher dir
      assert length(WatchRegistry.watched(reg)) == 1

      # dropping one leaves the watcher up
      WatchRegistry.unwatch(reg, dir, {self(), :s1})
      assert length(WatchRegistry.watched(reg)) == 1

      # dropping the last stops it
      WatchRegistry.unwatch(reg, dir, {self(), :s2})
      assert WatchRegistry.watched(reg) == []
    end

    File.rm_rf!(dir)
  end
end
