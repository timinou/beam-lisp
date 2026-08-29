defmodule BeamLisp.Loader.Server do
  @moduledoc """
  The pinned process that runs `:global` library loads.

  Libraries load once, VM-wide, at `:global` (see `BeamLisp.Loader`). A
  load's top-level forms may create PROCESS-OWNED state — most sharply
  `:ets.new` tables. When the loading process was an async test fork's
  short-lived Task (PLAN-046/047), the table died with the task and every
  later access raised "the table identifier does not refer to an existing
  ETS table" (41 such errors in relay's BL_ASYNC=1 suite). Serial mode
  never saw it: loads ran in the long-lived main process.

  Routing `:global` loads (source eval AND AOT `__bl_init__/0` replays,
  which replay table-creating forms too) through this GenServer gives
  that state a lifetime bound to the VM, not to whichever process happened
  to require first. Nested requires detect they're already inside via the
  pdict flag and run inline — no self-call deadlock.

  Exceptions cross back to the caller as raises with their original
  stacktrace; the server survives (the load's `try/after` invariants ran
  inside, and a poisoned partial load is a loader-level concern, not a
  process-liveness one).
  """
  use GenServer

  @flag :bl_in_loader_server

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, :ok}

  @doc "Run `fun` in the loader process (inline if already inside it)."
  def run(fun) when is_function(fun, 0) do
    if Process.get(@flag) do
      fun.()
    else
      ensure_started()

      case GenServer.call(__MODULE__, {:run, fun}, :infinity) do
        {:ok, result} -> result
        {:raised, e, stacktrace} -> reraise(e, stacktrace)
        {:thrown, v} -> throw(v)
      end
    end
  end

  # `BeamLisp.init/0` runs in VMs with no application tree (the
  # compile.beam_lisp task's VM) — start on demand there, exactly as
  # AOT.boot starts Env. The registered name makes the race benign.
  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link([]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _ ->
        :ok
    end
  end

  @impl true
  def handle_call({:run, fun}, _from, state) do
    Process.put(@flag, true)

    reply =
      try do
        {:ok, fun.()}
      rescue
        e -> {:raised, e, __STACKTRACE__}
      catch
        :throw, v -> {:thrown, v}
      after
        Process.delete(@flag)
      end

    {:reply, reply, state}
  end
end
