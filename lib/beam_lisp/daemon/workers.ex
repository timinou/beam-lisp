defmodule BeamLisp.Daemon.Workers do
  @moduledoc """
  The daemon's three stateful workers — the command `Executor`, the
  `WatchRegistry` and the HTTP MCP mount owner (`McpWorker`) — under ONE
  supervisor, so a death is a RESTART.

  ## Why this module exists

  Both were started with a bare `start_link` from the daemon's `init/1`: linked,
  which is what makes a daemon stop take them down (wanted), and with nothing at
  all to bring them back (not wanted). A process that is only LINKED does not
  restart — the link propagates the exit, and the daemon simply continues
  without a worker.

  That is not hypothetical. User code RUNS INSIDE the command worker, so it can
  kill it: a `start-link` to a process that then crashes takes the worker with
  it, and `examples/mcp-demo.bl` does exactly that when it starts an in-process
  MCP server and that server dies. The first death took the worker down, and
  every command after it failed with `:noproc` — `bl daemon status` fine, socket
  bound, UI up, nothing runnable. "The daemon looks alive, which is the worst
  way to fail" is this file's own phrase; a worker that cannot come back is that
  failure wearing the other hat.

  The workers hold nothing worth preserving across a death — the Executor's
  state is `%{active, handler}`, the registry rebuilds its subscriptions as
  clients re-register — so a restart IS the fix, and `:one_for_one` keeps a
  crash in one from touching the other.

  Started from the daemon's `init/1` and linked to it, so `bl daemon stop` (or
  the idle timer) still takes the tree down with it.
  """

  @workers [BeamLisp.Daemon.Executor, BeamLisp.Daemon.WatchRegistry, BeamLisp.Daemon.McpWorker]

  @doc """
  Start the worker supervisor, or hand back the one already running.

  Idempotent by name: the daemon's `init/1` may run twice in one VM, and the
  second call must find the first supervisor rather than fail on it.
  """
  def ensure_started do
    case Supervisor.start_link(@workers, strategy: :one_for_one, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end
end
