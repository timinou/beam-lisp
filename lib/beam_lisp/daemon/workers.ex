defmodule BeamLisp.Daemon.Workers do
  @moduledoc """
  The daemon's three stateful workers — the command `Executor`, the
  `WatchRegistry` and the tree's index owner (`IndexWorker`) — under ONE
  supervisor, so a death is a RESTART.

  ## Why this module exists

  They were started with a bare `start_link` from the daemon's `init/1`: linked,
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

  ## Who owns the tree

  `start_link/1` takes a `root` and a `build`, and is a real child spec, so the
  supervisor can be owned by whoever starts the daemon — the daemon links it
  from `init/1`; a TEST owns it through `start_supervised!`. That is not
  decoration: `ensure_started/1` LINKS the supervisor to its caller, so a caller
  that exits (every ExUnit case) takes the whole tree with it, and the next
  caller races a supervisor that is on its way down. Owning the lifecycle
  explicitly is the only shape that works for both.
  """

  @workers [BeamLisp.Daemon.Executor, BeamLisp.Daemon.WatchRegistry]

  @doc """
  The supervision tree — started by the daemon, owned by its caller.

  `root` is the tree the daemon serves, and it is handed to the index worker and
  NOWHERE else: the other two learn the tree per request (a command binds the
  caller's cwd), while the index is built by a BACKGROUND build that has no
  request to read it from. Without it, a daemon started in one directory would
  index whatever directory a later request happened to stand in.

  `build` is whether the index worker may index the tree on its own — TRUE in a
  daemon, whose whole point is that the work happened before anyone asked, and
  FALSE for a caller that owns the worker for one assertion: a test must not
  kick off a real tree index as a side effect of starting a supervisor.
  """
  def start_link(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())

    children =
      @workers ++
        [{BeamLisp.Daemon.IndexWorker, [root: root, build: Keyword.get(opts, :build, true)]}]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @doc """
  This supervisor as a child spec — what makes it usable as a CHILD:
  `start_supervised!({BeamLisp.Daemon.Workers, root: dir, build: false})` in a
  test, where ExUnit owns the lifecycle and stops it after the case.
  """
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Start the worker supervisor, or hand back the one already running.

  Idempotent by name: the daemon's `init/1` may run twice in one VM, and the
  second call must find the first supervisor rather than fail on it.

  A convenience over `start_link/1` for the daemon, and only for it — see the
  ownership note in the moduledoc.
  """
  def ensure_started(opts \\ []) do
    case start_link(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end
end
