defmodule BeamLisp.Daemon.WorkersTest do
  use ExUnit.Case, async: false

  # The defect this pins.
  #
  # Both workers were started with a bare `start_link` from the daemon's
  # `init/1`: linked, so a daemon stop takes them down (wanted), and with
  # nothing to bring them back (not wanted — a process that is only LINKED does
  # not restart).
  #
  # It is reachable from the outside because user code RUNS INSIDE the command
  # worker: `examples/mcp-demo.bl` starts an in-process MCP server with
  # `start-link`, and when that server crashed it took the worker with it. The
  # daemon stayed up — socket bound, `bl daemon status` fine, UI serving — while
  # every later command failed `:noproc`, permanently, until someone stopped and
  # restarted it. A daemon that looks alive and can do nothing is the worst way
  # to fail, which is this module's own stated rule.

  # Own the supervisor's lifecycle rather than sharing the global one. Another
  # file in the same VM — or a real daemon (`BeamLisp.Daemon.Server` calls the
  # same `Workers.ensure_started/1`) — registers this exact name and TAKES IT
  # DOWN when it stops, which is FUP-074's `(EXIT) shutdown` / `no process`
  # racing a lifecycle we do not own. Stop any existing instance, start a fresh
  # one, tear it down on exit.
  setup do
    if pid = Process.whereis(BeamLisp.Daemon.Workers), do: stop_sup(pid)

    {:ok, sup} = BeamLisp.Daemon.Workers.ensure_started()
    on_exit(fn -> stop_sup(sup) end)
    :ok
  end

  defp stop_sup(pid) do
    ref = Process.monitor(pid)
    # Unlink first: setup runs in the test process and `ensure_started` used
    # `start_link`, so a bare stop would deliver the supervisor's exit to us.
    Process.unlink(pid)
    Supervisor.stop(pid, :normal, 10_000)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      10_000 -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  test "all three workers run under the supervisor" do
    assert Process.whereis(BeamLisp.Daemon.Executor)
    assert Process.whereis(BeamLisp.Daemon.WatchRegistry)
    assert Process.whereis(BeamLisp.Daemon.IndexWorker)
    assert Supervisor.which_children(BeamLisp.Daemon.Workers) |> length() == 3
  end

  test "a killed worker is restarted, not lost" do
    before = Process.whereis(BeamLisp.Daemon.Executor)
    assert is_pid(before)

    Process.exit(before, :kill)

    assert wait_until(fn ->
             pid = Process.whereis(BeamLisp.Daemon.Executor)
             is_pid(pid) and pid != before
           end)

    assert Process.whereis(BeamLisp.Daemon.Executor) |> Process.alive?()
  end

  test "ensure_started is idempotent" do
    # The daemon's `init/1` can run twice in one VM; the second call must find
    # the first supervisor instead of failing on the name.
    {:ok, a} = BeamLisp.Daemon.Workers.ensure_started()
    {:ok, b} = BeamLisp.Daemon.Workers.ensure_started()
    assert a == b
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
