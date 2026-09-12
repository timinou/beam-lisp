defmodule BeamLisp.Z3.Pool do
  @moduledoc """
  N solvers, leased one conversation at a time.

  One z3 process is one conversation (`BeamLisp.Z3.Solver`), so a server that
  answers several clients at once wants more than one. This is that, and nothing
  else that OTP already does: a `Supervisor` over named solver instances plus a
  lease server that tracks WHO holds WHAT. Restarts are the supervisor's, and the
  lease server never looks at pids — instances are named, so a restart is
  invisible to it (it asks `Process.whereis/1` at checkout).

  Why a lease and not a queue of jobs: a conversation spans calls (assert once,
  push, check, read a core). Handing a solver to a *request* and taking it back
  at the end of that request is the whole trick, and it is the same contract the
  singleton offers — so `z3/with-solver` and `z3/check` keep one meaning whether
  the pool is up or not.

  - `start/1` sizes it. `up?/0` is how the language layer decides whether to lease
    from the pool or use the singleton, so nothing changes until someone starts
    one.
  - `check_one/2` is a one-shot conversation on a pool member: what an ordinary
    `z3/check` becomes once a pool exists.
  - `stats/0` reports `busy`/`free` and `high_water` — the observability the
    supervisor bundle asks for, and the number that says whether N is right.
  """

  @name __MODULE__
  @lease_name BeamLisp.Z3.Pool.Leases

  # ── lifecycle ────────────────────────────────────────────────────────────

  @doc "Start a pool of `n` solvers (idempotent: a running pool is returned)."
  def start(n) when is_integer(n) and n > 0 do
    case Process.whereis(@name) do
      nil ->
        children =
          [{BeamLisp.Z3.Pool.Leases, instance_names(n)}] ++
            for name <- instance_names(n),
                do: Supervisor.child_spec({BeamLisp.Z3.Solver, name}, id: name)

        case Supervisor.start_link(children, strategy: :one_for_one, name: @name) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end

      pid ->
        {:ok, pid}
    end
  end

  @doc "Is a pool running? The switch the language layer reads."
  def up?, do: Process.whereis(@name) != nil

  @doc "Stop the pool (its solvers and their z3 processes go with it)."
  def stop do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal, 10_000)
    end
  end

  @doc "How many solvers a pool was started with."
  def size do
    if up?(), do: length(instances()), else: 0
  end

  @doc "The instance names this pool supervises, in order."
  def instances do
    for i <- 0..255, name = instance_name(i), Process.whereis(name), do: name
  end

  defp instance_names(n), do: for(i <- 0..(n - 1), do: instance_name(i))
  defp instance_name(i), do: String.to_atom("#{@name}.s#{i}")

  # ── one-shot conversations (what `z3/check` uses when a pool is up) ──────

  @doc """
  One reset-assert-check conversation on a leased pool member. Fair: a saturated
  pool queues the call rather than failing it, exactly like the singleton lease.
  """
  def check_one(smt, model? \\ false) do
    with_solver(fn name -> BeamLisp.Z3.Solver.check(name, smt, model?) end)
  end

  @doc """
  Run `f` with an exclusive pool member (its NAME is passed to `f`). The lease is
  returned in `after`, and by monitor if the borrower dies — a crashed caller
  never strands a solver.
  """
  def with_solver(f) when is_function(f, 1) do
    lease = checkout()

    try do
      name = lease.name
      :ok = BeamLisp.Z3.Solver.acquire(name)

      try do
        f.(name)
      after
        BeamLisp.Z3.Solver.release(name)
      end
    after
      checkin(lease)
    end
  end

  def checkout, do: GenServer.call(@lease_name, {:checkout, self()}, 600_000)
  def checkin(lease), do: GenServer.call(@lease_name, {:checkin, lease, self()})
  def stats, do: GenServer.call(@lease_name, :stats)

  # ── the lease server ─────────────────────────────────────────────────────

  defmodule Leases do
    @moduledoc """
    Who holds what. Tracks LEASES, never pids: a solver that dies and is restarted
    by the supervisor comes back under the same name, so the only thing this
    process must get right is handing a free solver to exactly one borrower at a
    time — and taking it back when that borrower dies.
    """

    use GenServer

    def start_link(names), do: GenServer.start_link(__MODULE__, names, name: __MODULE__)

    @impl true
    def init(names), do: {:ok, %{names: names, free: MapSet.new(names), leases: %{}, mon: %{}, waiting: :queue.new(), high_water: 0}}

    @impl true
    def handle_call({:checkout, who}, from, state) do
      case take_free(state) do
        {:ok, name, state} ->
          lease = %{lease: make_ref(), name: name}
          ref = Process.monitor(who)
          state = %{state | leases: Map.put(state.leases, lease.lease, name), mon: Map.put(state.mon, ref, lease.lease), high_water: max(state.high_water, map_size(state.leases) + 1)}
          {:reply, lease, state}

        :none ->
          # Saturated: queue in arrival order. The supervisor bundle's Governor is
          # for crashing children; saturation is a queue, not a failure.
          {:noreply, %{state | waiting: :queue.in(from, state.waiting)}}
      end
    end

    def handle_call({:checkin, lease, _who}, _from, state) do
      {:reply, :ok, release(state, lease.lease)}
    end

    def handle_call(:stats, _from, state) do
      busy = map_size(state.leases)
      {:reply, %{n: length(state.names), busy: busy, free: MapSet.size(state.free), high_water: state.high_water}, state}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
      case Map.pop(state.mon, ref) do
        {nil, _} -> {:noreply, state}
        {lease_ref, mon} -> {:noreply, release(%{state | mon: mon}, lease_ref)}
      end
    end

    def handle_info(_msg, state), do: {:noreply, state}

    # The first FREE name that is actually alive. A name whose solver is being
    # restarted is skipped (never handed out as a corpse) and picked up on the
    # next checkout, when the supervisor has it back.
    defp take_free(%{free: free} = state) do
      case Enum.find(free, &(Process.whereis(&1) != nil)) do
        nil -> :none
        name -> {:ok, name, %{state | free: MapSet.delete(free, name)}}
      end
    end

    defp release(state, lease_ref) do
      case Map.pop(state.leases, lease_ref) do
        {nil, _} -> hand_over(state)
        {name, leases} ->
          state = %{state | leases: leases, free: MapSet.put(state.free, name)}
          state = drop_monitor(state, lease_ref)
          hand_over(state)
      end
    end

    defp drop_monitor(state, lease_ref) do
      case Enum.find(state.mon, fn {_ref, l} -> l == lease_ref end) do
        nil -> state
        {ref, _} ->
          Process.demonitor(ref, [:flush])
          %{state | mon: Map.delete(state.mon, ref)}
      end
    end

    defp hand_over(state) do
      waiting = state.waiting

      case :queue.out(waiting) do
        {:empty, _} ->
          state

        {{:value, from}, rest} ->
          state = %{state | waiting: rest}
          {who, _tag} = from

          if Process.alive?(who) do
            case take_free(state) do
              {:ok, name, state} ->
                lease = %{lease: make_ref(), name: name}
                ref = Process.monitor(who)

                state = %{
                  state
                  | leases: Map.put(state.leases, lease.lease, name),
                    mon: Map.put(state.mon, ref, lease.lease),
                    high_water: max(state.high_water, map_size(state.leases) + 1)
                }

                GenServer.reply(from, lease)
                state

              :none ->
                # The waiter is back in line; nothing is free yet.
                %{state | waiting: :queue.in(from, rest)}
            end
          else
            hand_over(state)
          end
      end
    end
  end
end
