defmodule BeamLisp.Daemon.Server do
  @moduledoc """
  Lifecycle of a `bl` daemon: boot the beam-lisp substrate ONCE, bind the
  tree's `AF_UNIX` socket, accept clients, and serve until stopped or idle.

  One daemon per canonical tree (see `BeamLisp.Daemon.Paths`). The socket's
  existence is discovery; an authenticated hello is authority. On any exit the
  socket, token, pidfile and meta are removed so a later launcher sees a clean
  slate.

  S1 scope: start/status/stop over the socket, token minting, stale-endpoint
  handling, idle timer. Command execution arrives in S2/S3 via `execute_fun`.
  """

  use GenServer
  require Logger

  alias BeamLisp.Daemon.{Paths, Listener, Protocol}

  @default_idle_seconds 8 * 60 * 60

  # --- public API ---

  @doc """
  Start a daemon for `root` (a tree/payload dir). Options:
    * `:root` — required tree root (defaults to `File.cwd!()`)
    * `:idle_seconds` — auto-stop after inactivity (0 disables; env override
      `BL_DAEMON_IDLE_SECONDS`)
    * `:boot` — run `AOT.boot/0` (default true; tests may skip)
    * `:execute_fun` — `(sock, id, req) -> :ok` command handler (S2+)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Entry point for a detached daemon process launched by the client:
  `bin/bl daemon start` maps here through the CLI. Reads the root from
  `BL_DAEMON_ROOT`/cwd, starts the server, and blocks the calling process
  until the daemon stops.
  """
  def start_from_env! do
    root = System.get_env("BL_DAEMON_ROOT") || File.cwd!()
    {:ok, pid} = start_link(root: root, boot: true)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    end
  end

  @doc "Ask a running in-VM daemon to stop (used by tests and the control op)."
  def stop(reason \\ :normal), do: GenServer.stop(__MODULE__, reason)

  @doc "The server's current status map (in-VM callers)."
  def status, do: GenServer.call(__MODULE__, :status)

  # --- GenServer ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    root = Keyword.get(opts, :root) || File.cwd!()

    with {:ok, ep} <- Paths.endpoints(root),
         :ok <- if(Keyword.get(opts, :boot, true), do: safe_boot(), else: :ok),
         token <- mint_token(),
         :ok <- write_token(ep.token, token),
         {:ok, lsock} <- Listener.listen(ep.sock) do
      _ = File.chmod(ep.sock, 0o600)
      _ = write_pid(ep.pid, root)
      _ = write_meta(ep.meta, root, token)

      # The single-worker command serializer. Linked so a daemon stop takes it
      # down; a fresh one starts with each daemon.
      {:ok, _exec} =
        case Process.whereis(BeamLisp.Daemon.Executor) do
          nil -> BeamLisp.Daemon.Executor.start_link([])
          pid -> {:ok, pid}
        end

      # The watcher registry: `bl watch` clients register here; reload commits
      # ride the Executor FIFO. Optional — a build without :file_system still
      # serves every non-watch command.
      {:ok, _wreg} =
        case Process.whereis(BeamLisp.Daemon.WatchRegistry) do
          nil -> BeamLisp.Daemon.WatchRegistry.start_link([])
          pid -> {:ok, pid}
        end

      state = %{
        root: root,
        endpoints: ep,
        token: token,
        tree: Paths.tree_fingerprint(root),
        lsock: lsock,
        started_at: System.monotonic_time(:millisecond),
        idle_seconds: idle_seconds(opts),
        last_activity: System.monotonic_time(:millisecond),
        shutting_down: false,
        # The key we BOOTED with (frozen). Drift = this != the live on-disk key.
        # An explicit `:compiler_key` opt lets a test simulate a stale daemon.
        compiler_key: Keyword.get(opts, :compiler_key) || compiler_key(),
        daemon_build_id: build_id(),
        execute_fun: Keyword.get(opts, :execute_fun, &default_execute/4),
        stop_flag: :counters.new(1, [:atomics])
      }

      start_acceptor(state)
      schedule_idle_check(state)
      Logger.info("bl daemon up: tree #{ep.tree_id} at #{ep.sock}")
      {:ok, state}
    else
      {:error, reason} -> {:stop, {:daemon_init_failed, reason}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_map(state), state}
  end

  @impl true
  def handle_cast(:stop, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:idle_check, state) do
    now = System.monotonic_time(:millisecond)
    idle_ms = state.idle_seconds * 1000

    if state.idle_seconds > 0 and now - state.last_activity >= idle_ms do
      Logger.info("bl daemon idle-stop after #{state.idle_seconds}s")
      {:stop, :normal, state}
    else
      schedule_idle_check(state)
      {:noreply, state}
    end
  end

  def handle_info({:activity, _}, state) do
    {:noreply, %{state | last_activity: System.monotonic_time(:millisecond)}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :counters.put(state.stop_flag, 1, 1)
    _ = :gen_tcp.close(state.lsock)
    ep = state.endpoints
    for f <- [ep.sock, ep.token, ep.pid, ep.meta, ep.lock], do: File.rm(f)
    :ok
  end

  # --- internals ---

  defp start_acceptor(state) do
    ctx = %{
      token: state.token,
      tree: state.tree,
      compiler_key: state.compiler_key,
      daemon_build_id: state.daemon_build_id,
      started_at: state.started_at,
      shutting_down: false,
      execute_fun: state.execute_fun,
      control_fun: fn :stop -> GenServer.cast(__MODULE__, :stop) end,
      queue_depth_fun: fn -> BeamLisp.Daemon.Executor.queue_depth() end,
      # Self-drift: has the checkout changed under the running daemon? Compare
      # the key we booted with to the live on-disk key. If it moved, this VM is
      # stale and MUST be restarted, never trusted — hot-swapping would mix old
      # loaded code with new sources.
      drift_fun: fn ->
        try do
          is_binary(state.compiler_key) and
            state.compiler_key != BeamLisp.AOTCache.current_compiler_key()
        rescue
          _ -> false
        end
      end
    }

    flag = state.stop_flag
    lsock = state.lsock
    # Unlinked: the acceptor is bounded by the accept timeout and the stop flag,
    # so a handler fault or a server stop never propagates a link exit back into
    # the GenServer's own stop reason. Cleanup (socket close) happens in
    # terminate/2 regardless.
    spawn(fn -> Listener.accept_loop(lsock, ctx, fn -> :counters.get(flag, 1) == 1 end) end)
  end

  # The default command path: hand the request to the Executor (one worker at a
  # time). `conn` is the connection handler pid, which routes stdin frames.
  defp default_execute(sock, id, req, conn) do
    BeamLisp.Daemon.Executor.run(sock, id, req, conn)
  rescue
    e ->
      _ = :gen_tcp.send(sock, Protocol.stderr(id, 0, "bl daemon: #{Exception.message(e)}\n"))
      _ = :gen_tcp.send(sock, Protocol.exit(id, 70))
      70
  end

  defp safe_boot do
    BeamLisp.AOT.boot()
    :ok
  rescue
    e -> {:error, {:boot_failed, Exception.message(e)}}
  end

  defp mint_token, do: :crypto.strong_rand_bytes(32)

  defp write_token(path, token) do
    with :ok <- File.write(path, token) do
      File.chmod(path, 0o600)
    end
  end

  defp write_pid(path, root) do
    File.write(path, "#{:os.getpid()} #{root}\n")
  end

  defp write_meta(path, root, _token) do
    meta = %{
      pid: :os.getpid() |> List.to_string(),
      root: root,
      compiler_key: compiler_key(),
      daemon_build_id: build_id(),
      started_at: System.system_time(:second)
    }

    File.write(path, :erlang.term_to_binary(meta))
  end

  defp idle_seconds(opts) do
    case System.get_env("BL_DAEMON_IDLE_SECONDS") do
      v when is_binary(v) and v != "" ->
        case Integer.parse(v) do
          {n, _} -> n
          _ -> Keyword.get(opts, :idle_seconds, @default_idle_seconds)
        end

      _ ->
        Keyword.get(opts, :idle_seconds, @default_idle_seconds)
    end
  end

  defp schedule_idle_check(%{idle_seconds: 0}), do: :ok

  defp schedule_idle_check(_state) do
    Process.send_after(self(), :idle_check, 60_000)
  end

  defp status_map(state) do
    %{
      running: true,
      pid: :os.getpid() |> List.to_string(),
      root: state.root,
      tree_id: state.endpoints.tree_id,
      compiler_key: state.compiler_key,
      daemon_build_id: state.daemon_build_id,
      uptime_ms: System.monotonic_time(:millisecond) - state.started_at,
      idle_seconds: state.idle_seconds
    }
  end

  defp compiler_key do
    BeamLisp.AOTCache.compiler_key()
  rescue
    _ -> nil
  end

  defp build_id do
    case :application.get_key(:beam_lisp, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0"
    end
  end
end
