defmodule BeamLisp.Z3.Solver do
  @moduledoc """
  The VM's one z3 process, and the ONE process that talks to it.

  Why a process and not just a port. A port delivers its replies to the mailbox
  of the process driving it (`Z3Port.read_answer/2` receives `{port, {:data, …}}`),
  so a SHARED port cannot answer two callers: the second caller's read consumes
  the first caller's lines and both desync. Measured over the HTTP surface —
  1000 sequential `code/verify` calls failed none, the same 1000 with four
  threads failed 15, with `z3 timeout (acc: "")` and `argument error` in the
  daemon's log; in-process, 8 concurrent verifies produced ONE answer. A port is
  a single-writer resource, and the writer has to be a process that owns the
  port's mailbox.

  So this GenServer owns the port and serializes every conversation. One
  conversation is `(reset)` → assertions → `(check-sat)` → `(get-model)`: those
  lines must not interleave with another caller's, and here they cannot.

  Lifetime: started on demand, NOT linked. It must outlive the request that
  first needed it (a request handler dying must not take the solver with it),
  and it must die with the VM rather than leak a z3 process past it. If the
  solver itself dies, `ensure_started/0` starts a fresh one on the next call,
  and a port that died under it is reopened inside the callback.

  This is also the unit a pool would be built from: one solver process per z3
  process, checkout per conversation — which is what would let callers use z3's
  incremental features (push/pop, assumptions, unsat cores) that a reset-per-query
  API cannot express.
  """

  use GenServer

  @call_timeout 120_000

  @doc "Start the solver if it is not running. Idempotent by name."
  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> raise "cannot start the z3 solver: #{inspect(reason)}"
        end

      pid ->
        {:ok, pid}
    end
  end

  @doc """
  The port this solver owns. Callers may hold it as a handle, but every command
  must go through `check/3` — the port's replies come here, not to them.
  """
  def port do
    {:ok, _} = ensure_started()
    GenServer.call(__MODULE__, :port)
  end

  @doc """
  Run one check on the solver, serialized. `port` is accepted for call-site
  compatibility (it is provenance, not control): the solver owns the port, so a
  caller's stale handle cannot make this fail.

  A failure inside the solver (a z3 timeout, a badarg) is re-raised IN THE
  CALLER with its original class, reason and stacktrace, so callers keep seeing
  a normal exception rather than a protocol-shaped one.
  """
  def check(port, smt, model? \\ false) do
    {:ok, _} = ensure_started()

    case GenServer.call(__MODULE__, {:check, port, smt, model?}, @call_timeout) do
      {:ok, result} -> result
      {:error, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
    end
  end

  @doc "Is the solver (and the port it owns) reachable?"
  def alive?(_port \\ nil) do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> GenServer.call(pid, :alive, @call_timeout)
    end
  end

  # ── callbacks ─────────────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)

    case BeamLisp.Z3Port.open_port() do
      {:ok, port} -> {:ok, %{port: port}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, %{port: port} = state), do: {:reply, port, state}

  @impl true
  def handle_call(:alive, _from, %{port: port} = state) do
    {:reply, BeamLisp.Z3Port.alive?(port), state}
  end

  @impl true
  def handle_call({:check, _caller_port, smt, model?}, _from, state) do
    try do
      state = ensure_port(state)
      {:reply, {:ok, BeamLisp.Z3Port.raw_check(state.port, smt, model?)}, state}
    catch
      kind, reason -> {:reply, {:error, kind, reason, __STACKTRACE__}, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # z3 died under us: drop the port so the next check opens a fresh one rather
    # than writing into a closed one.
    {:noreply, %{state | port: nil} |> Map.put(:last_exit, status)}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # A dead port (z3 exited, or the VM closed it) is reopened here, in the owner,
  # where the lifetime is stable — the same "ask, do not assume" rule the codebase
  # memo follows, applied to the resource whose lifetime this process controls.
  defp ensure_port(%{port: port} = state) do
    if port != nil and BeamLisp.Z3Port.alive?(port) do
      state
    else
      case BeamLisp.Z3Port.open_port() do
        {:ok, fresh} -> %{state | port: fresh}
        {:error, reason} -> raise "cannot start z3: #{inspect(reason)}"
      end
    end
  end
end
