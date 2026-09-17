defmodule BeamLisp.Daemon.Executor do
  @moduledoc """
  The daemon's SEQUENCER for the two operations that must not run concurrently
  with a live program mutating the VM image: a reload commit and a dashboard
  intent. Commands themselves no longer pass through here — since PLAN-121 they
  run as per-request processes under their VM's capped env (see
  `BeamLisp.Daemon.Server.vm_execute` → `bl.daemon/handle-in-vm`), so there is
  no single serial command worker and nothing queues.

  What remains is a single GenServer whose mailbox orders exactly two things:

    * `run_reload/2` — a watcher's stage→commit, so it never interleaves with a
      program the daemon is running (PLAN-121 D3a: reload ordering is
      correctness, not a bottleneck);
    * `run_capture/2` — a dashboard intent, run with output captured, taking its
      turn against a reload the same way.

  Both are legitimately serial. Neither is the old command FIFO, which is gone.
  """

  use GenServer

  # --- public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Run `fun` on the sequencer — the same turn a dashboard intent takes — so a
  reload commit never races a program the daemon is running. Returns `fun`'s
  value.
  """
  def run_reload(server \\ __MODULE__, fun) when is_function(fun, 0) do
    GenServer.call(server, {:run_reload, fun}, :infinity)
  end

  @doc """
  Run `fun` on the sequencer with output CAPTURED, returning `{result, output}`.
  Capturing needs the group-leader swap to happen in the process that PRINTS —
  this one — so the caller cannot do it; hence a variant here.
  """
  def run_capture(server \\ __MODULE__, fun) when is_function(fun, 0) do
    GenServer.call(server, {:run_capture, fun}, :infinity)
  end

  # --- GenServer: a single sequencer, calls ordered by the mailbox ---

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:run_capture, fun}, _from, state) do
    {:ok, io} = StringIO.open("")
    prev = Process.group_leader()
    Process.group_leader(self(), io)

    result =
      try do
        fun.()
      rescue
        e -> {:error, Exception.message(e)}
      catch
        kind, v -> {:error, {kind, v}}
      end

    Process.group_leader(self(), prev)
    {_, output} = StringIO.contents(io)
    {:reply, {result, output}, state}
  end

  @impl true
  def handle_call({:run_reload, fun}, _from, state) do
    result =
      try do
        fun.()
      rescue
        e -> {:error, Exception.message(e)}
      catch
        kind, v -> {:error, {kind, v}}
      end

    {:reply, result, state}
  end
end
