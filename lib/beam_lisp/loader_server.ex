defmodule BeamLisp.Loader.Server do
  @moduledoc """
  The pinned process that runs `:global` library loads.

  Libraries load once, VM-wide, at `:global` (see `BeamLisp.Loader`). A load's
  top-level forms may create process-owned state such as ETS tables. Routing
  source evaluation and AOT `__bl_init__/0` replay through this GenServer binds
  that state to the VM rather than whichever process required it first. Nested
  requires run inline to avoid a self-call deadlock.

  Exceptions cross back to the caller with their original stacktrace; the
  server survives.
  """
  use GenServer

  @flag :bl_in_loader_server

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, %{}}

  @doc false
  def in_server?, do: Process.get(@flag) == true

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
