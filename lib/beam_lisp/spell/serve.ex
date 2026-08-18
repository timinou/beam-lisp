defmodule BeamLisp.Spell.Serve do
  @moduledoc """
  The verse dev server as a supervised Port.

  One long-running `spacetime serve <site-dir>` — the warm compiler the FS
  protocol (`Spell.Build`) talks to. Started by the application in serve mode
  when the binary exists; when it does not, the child is `:ignore`d and the
  first publish says so through the build-status timeout, which names the fix.

  The port runs with `cd` = the verse root because spacetime resolves its
  stdlib registry relative to the cwd.
  """

  use GenServer

  require Logger

  alias BeamLisp.Spell.{Build, Verse}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    case Verse.binary() do
      {:ok, bin} ->
        site = Build.site_dir()
        File.mkdir_p!(site)
        port_num = Application.get_env(:beam_lisp, :spell_verse_port, 4444)

        port =
          Port.open({:spawn_executable, bin}, [
            :binary,
            :stderr_to_stdout,
            :exit_status,
            args: ["serve", Path.expand(site), "--port", to_string(port_num)],
            cd: Verse.verse_root()
          ])

        Logger.info("verse serve: #{Build.origin()} watching #{site}")
        {:ok, %{port: port, site: site}}

      {:error, reason} ->
        Logger.warning("verse serve not started: #{reason}")
        :ignore
    end
  end

  @impl true
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("verse serve exited with status #{code}")
    {:stop, {:exit_status, code}, state}
  end

  def handle_info({port, {:data, _}}, %{port: port} = state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    # The serve exits on its own when our port closes its stdin pipe (verse
    # watches for that EOF), but that contract is one binary rebuild old —
    # an older spacetime would orphan, holding port and watcher. SIGTERM is
    # the belt; a dead pid makes it a no-op.
    with {:os_pid, pid} <- Port.info(port, :os_pid) do
      System.cmd("kill", [to_string(pid)])
    end

    :ok
  end
end
