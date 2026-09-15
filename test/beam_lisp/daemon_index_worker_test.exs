defmodule BeamLisp.Daemon.IndexWorkerTest do
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

  # The worker boot-builds the index INSIDE `init` (`send(self(), :build)`), and
  # a build blocks the worker for its whole duration BY DESIGN — the moduledoc's
  # own rule: "a run/1 that arrives mid-build waits for it, and then finds a warm
  # index". `run/1` is therefore `:infinity`; a client that wants to watch reads
  # `progress/0`. Two consequences for these tests:
  #
  #   * we must OWN the supervisor's lifecycle, not share the global one another
  #     test file (or a live daemon in the same VM) started and will tear down —
  #     that shared teardown was FUP-074's `(EXIT) no process` / `shutdown`. So
  #     setup stops any existing instance and starts a fresh one, torn down on
  #     exit, giving every test a supervisor whose lifetime it controls.
  #   * we must let the boot build SETTLE before exercising `run`, or the call
  #     queues behind a multi-second build and a naive 5s `Task.await` times out
  #     mid-build. `wait_ready/0` polls the public progress row (which never
  #     queues) until the build has reached `:ready`/`:error`.
  setup do
    if pid = Process.whereis(BeamLisp.Daemon.Workers), do: stop_sup(pid)

    # An EMPTY temp root, not the checkout: the worker still boot-builds (it
    # always indexes the engine's own two namespaces), but over nothing else, so
    # the build is seconds not the whole tree's ~40s. This keeps the restart test
    # — which kills the worker and waits for its replacement's fresh build — well
    # under the ExUnit timeout even when the full suite has a real daemon churning
    # the same global name. The property under test is table-OWNERSHIP across a
    # process boundary, which an empty root exercises exactly as a full one does.
    tmp = Path.join(System.tmp_dir!(), "iw_root_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, sup} = BeamLisp.Daemon.Workers.ensure_started(root: tmp)
    on_exit(fn -> stop_sup(sup) end)
    wait_ready()
    :ok
  end

  defp stop_sup(pid) do
    ref = Process.monitor(pid)
    # Unlink first: the caller is the test process, and `ensure_started` used
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

  # Block until the worker's boot build has settled, so `run/1` in a test does
  # not queue behind it. `:ready`/`:error` are terminal; `:cold`/`:building` are
  # in flight. Bounded so a genuine wedge fails the test instead of hanging it.
  defp wait_ready(tries \\ 6000)
  defp wait_ready(0), do: :timeout

  defp wait_ready(tries) do
    case BeamLisp.Daemon.IndexWorker.progress() do
      %{phase: phase} when phase in [:ready, :error] -> :ok
      _ -> Process.sleep(10); wait_ready(tries - 1)
    end
  end

  test "run/2 executes the function on the worker, not the caller" do
    worker = Process.whereis(BeamLisp.Daemon.IndexWorker)
    assert is_pid(worker)

    ran_on = BeamLisp.Daemon.IndexWorker.run(fn -> self() end)
    assert ran_on == worker
    refute ran_on == self()
  end

  test "a table created during a request survives the requesting process" do
    # Stand in for the request/connection process: it asks, gets an answer,
    # and exits — exactly the HTTP lifecycle that used to kill the mount.
    Task.async(fn ->
      BeamLisp.Daemon.IndexWorker.run(fn ->
        :ets.new(:mcp_worker_test_mount, [:named_table, :public])
      end)
    end)
    # `:infinity`, matching `run/1`'s own contract: a `run` legitimately waits
    # for an in-flight build (the worker built at boot here), so a bounded await
    # would race the build rather than test ownership. `setup` already waited for
    # `:ready`, so in practice this returns at once.
    |> Task.await(:infinity)

    # The asker is gone (Task awaited = exited); what it built is not.
    assert :ets.info(:mcp_worker_test_mount) != :undefined

    :ets.delete(:mcp_worker_test_mount)
  end

  test "a killed worker is restarted, and the next request simply runs" do
    before = Process.whereis(BeamLisp.Daemon.IndexWorker)
    Process.exit(before, :kill)

    assert wait_until(fn ->
             pid = Process.whereis(BeamLisp.Daemon.IndexWorker)
             is_pid(pid) and pid != before
           end)

    # A restart loses the mount; the memo's alive? check rebuilds it. The
    # restarted worker boot-builds again, so wait for it to settle before the
    # call, then `run` on `:infinity` for the same reason as above.
    wait_ready()
    assert BeamLisp.Daemon.IndexWorker.run(fn -> :ok end) == :ok
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
