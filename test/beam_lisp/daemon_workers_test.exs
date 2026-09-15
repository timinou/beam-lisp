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

  # The supervisor is OWNED by the test — see the note in
  # `daemon_index_worker_test.exs`. `ensure_started/1` LINKS it to the caller, so
  # the case that called it exited and took the supervisor with it; the next case
  # then raced a supervisor on its way down.
  setup do
    start_supervised!({BeamLisp.Daemon.Workers, root: File.cwd!(), build: false})
    :ok
  end

  test "every worker runs under the supervisor" do
    # The stderr device is nameless by design — it holds :standard_error.
    assert Process.whereis(:standard_error)
    assert Process.whereis(BeamLisp.Daemon.Executor)
    assert Process.whereis(BeamLisp.Daemon.WatchRegistry)
    assert Process.whereis(BeamLisp.Daemon.IndexWorker)
    assert Supervisor.which_children(BeamLisp.Daemon.Workers) |> length() == 4
  end

  test "the stderr device owns :standard_error, and gives it back on stop" do
    # A command's stderr is only forwarded if the daemon's device HOLDS the
    # global name: `IO.puts(:stderr, …)` resolves the atom, so a device that is
    # merely alive routes nothing.
    assert is_pid(Process.whereis(:standard_error))

    dev = BeamLisp.Daemon.StdErr.device()
    assert is_pid(dev)

    # Stop the tree the way the daemon does, and the name must go back to the
    # device that had it — otherwise every later `IO.puts(:stderr, …)` in this
    # VM raises, in callers that have nothing to do with the daemon.
    Supervisor.stop(BeamLisp.Daemon.Workers)
    assert Process.whereis(:standard_error) == dev
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
