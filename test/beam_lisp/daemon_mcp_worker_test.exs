defmodule BeamLisp.Daemon.McpWorkerTest do
  use ExUnit.Case, async: false

  # The defect this pins (blueprint FUP-022).
  #
  # The daemon's HTTP MCP endpoint invoked `mcp.server/request-response` in
  # the PER-REQUEST connection process. The MCP server memoizes the tree's
  # codebase index — a datom conn whose store is ETS tables — behind a
  # `datom/alive?` check, and ETS tables die with their owner. So request 1
  # mounted the tree, answered, its process exited, the tables died, and
  # request 2 mounted AGAIN: every HTTP code question paid the full mount
  # (measured 95 s warm vs 3 s through the warm CLI, whose mount lives on the
  # long-lived Executor).
  #
  # `run/2` exists so every `/mcp` request executes on ONE long-lived worker;
  # these tests assert the property at the only level that matters — table
  # ownership — without standing up the bl runtime.

  setup do
    {:ok, _} = BeamLisp.Daemon.Workers.ensure_started()
    :ok
  end

  test "run/2 executes the function on the worker, not the caller" do
    worker = Process.whereis(BeamLisp.Daemon.McpWorker)
    assert is_pid(worker)

    ran_on = BeamLisp.Daemon.McpWorker.run(fn -> self() end)
    assert ran_on == worker
    refute ran_on == self()
  end

  test "a table created during a request survives the requesting process" do
    # Stand in for the request/connection process: it asks, gets an answer,
    # and exits — exactly the HTTP lifecycle that used to kill the mount.
    Task.async(fn ->
      BeamLisp.Daemon.McpWorker.run(fn ->
        :ets.new(:mcp_worker_test_mount, [:named_table, :public])
      end)
    end)
    |> Task.await()

    # The asker is gone (Task awaited = exited); what it built is not.
    assert :ets.info(:mcp_worker_test_mount) != :undefined

    :ets.delete(:mcp_worker_test_mount)
  end

  test "a killed worker is restarted, and the next request simply runs" do
    before = Process.whereis(BeamLisp.Daemon.McpWorker)
    Process.exit(before, :kill)

    assert wait_until(fn ->
             pid = Process.whereis(BeamLisp.Daemon.McpWorker)
             is_pid(pid) and pid != before
           end)

    # A restart loses the mount; the memo's alive? check rebuilds it. At this
    # level: the worker answers again.
    assert BeamLisp.Daemon.McpWorker.run(fn -> :ok end) == :ok
  end

  defp wait_until(fun, tries \\ 200)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end
end
