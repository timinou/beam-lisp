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

  alias BeamLisp.Daemon.{HTTP, Listener, Names, Paths, Ports, Protocol, WatchRegistry}

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

      # THE CUTOVER (PLAN-121): the COMMAND path is no longer a single serial
      # worker. Commands now run through the pure-beam-lisp global VM manager
      # (vm.manager) — one BEAM process per request, each under its project VM's
      # capped env, so N requests run concurrently with no FIFO and a program's
      # `System/halt` can only scope to its own VM.
      #
      # Workers still starts here for what remains legitimately serial or
      # node-global: StdErr (the node-wide stderr router), WatchRegistry (the
      # `bl watch` host), IndexWorker, and Executor — the latter now ONLY as the
      # reload-commit SEQUENCER (watch_registry → Executor.run_reload), whose
      # serialisation against a running program is load-bearing correctness
      # (PLAN-121 D3a), not the command bottleneck. No command takes its turn.
      {:ok, _} = BeamLisp.Daemon.Workers.ensure_started(root: root)
      boot_vm_manager()

      # The session's address. `:ui` is claimed first (the registry is what
      # decides whether a project's pinned port is free), then served — the page
      # and the MCP endpoint live on ONE port, because "where is this session"
      # should have one answer.
      ui = start_ui(root)

      state = %{
        root: root,
        ui: ui,
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
      IO.puts(startup_message(root, ui))
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
    Ports.release(:ui, root: state.root)
    ep = state.endpoints
    for f <- [ep.sock, ep.token, ep.pid, ep.meta, ep.lock], do: File.rm(f)
    :ok
  end

  # --- internals ---

  # ── the session's address ────────────────────────────────────────────────

  # Claim and serve `:ui`. A project pins it with `:ports {:ui 7700}` in env.bl;
  # without a pin the OS chooses, which is the right default — two trees on one
  # machine must never fight over a number nobody chose.
  #
  # A failure here does NOT stop the daemon: its job is serving commands, and the
  # page is a view. The startup message says what happened either way.
  defp start_ui(root) do
    want = project_port(root, "ui") || 0

    case Ports.claim(:ui, want, root: root, hosts: Names.hosts(root, "ui")) do
      {:ok, port} ->
        case serve_ui(port, root) do
          {:ok, pid} -> %{port: port, pid: pid, pinned: want != 0, error: nil}
          {:error, reason} -> %{port: port, pid: nil, pinned: want != 0, error: reason}
        end

      {:error, reason} ->
        %{port: nil, pid: nil, pinned: want != 0, error: reason}
    end
  end

  defp serve_ui(port, root) do
    opts = [
      plug:
        {HTTP,
         [
           status_fun: fn -> GenServer.call(__MODULE__, :status) end,
           tree_id: Paths.tree_id(root),
           # the intent guard: the page carries the daemon's own token, which a
           # cross-origin caller cannot read and cannot send without a preflight
           # this server never approves
           token: System.get_env("BL_DAEMON_TOKEN") || File.read!(elem(Paths.endpoints(root), 1).token)
         ]},
      port: port,
      ip: {127, 0, 0, 1},
      startup_log: false
    ]

    case Bandit.start_link(opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        # The port could have been taken between the claim's probe and this bind
        # (milliseconds). Take the failure as the answer rather than looping: the
        # message names it, and the next start tries again.
        {:error, reason}
    end
  end

  # The port a project declares for `name`: `:ports {:ui 7700}` or
  # `:ports {:ui {:port 7700}}`. nil when the tree declares none (the caller
  # then asks the OS).
  defp project_port(root, name) do
    BeamLisp.Loader.ensure_loaded("bl.env")
    p = BeamLisp.RT.invoke(BeamLisp.Env.fetch!("bl.env", "project"), [root])
    spec = Map.get(Map.get(p, :ports) || %{}, name)

    cond do
      is_integer(spec) -> spec
      # `{:port N}` from a project map. Matched, not `is_map`-tested: a bl
      # Vector or Set is a struct and would pass `is_map/1`.
      match?(%{port: _}, spec) -> Map.get(spec, :port)
      true -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  What the daemon says when it comes up. It names the tree, the session's NAME
  and the address behind it, and — because the port is ephemeral unless the
  project pins it — HOW to pin it. The MCP line matters for the same reason:
  the session's name is the one address an editor, an agent or a browser needs,
  and there is no second server behind it.

  Both spellings are printed on purpose. The name is what a human opens; the
  loopback address is the truth underneath it, and it keeps answering when the
  gateway is not running.
  """
  def startup_message(root, ui) do
    lines = ["bl daemon up for #{root}"]

    lines =
      case ui do
        %{port: port, error: nil} when is_integer(port) ->
          pin =
            if ui.pinned do
              "pinned by env.bl"
            else
              "ephemeral — pin it in env.bl with :ports {:ui 7700}"
            end

          host = Names.host(root, "ui")

          lines ++
            [
              "  ui:   http://#{host}   → 127.0.0.1:#{port}   (#{pin})",
              "  mcp:  http://#{host}/mcp   (the same MCP `bl mcp` serves over stdio)",
              "        no gateway yet? http://127.0.0.1:#{port} — start one with `bl gateway start`"
            ]

        %{error: error} ->
          lines ++ ["  ui:   not served — #{inspect(error)}"]

        _ ->
          lines
      end

    Enum.join(lines, "\n")
  end

  defp start_acceptor(state) do
    ctx = %{
      token: state.token,
      tree: state.tree,
      compiler_key: state.compiler_key,
      daemon_build_id: state.daemon_build_id,
      started_at: state.started_at,
      shutting_down: false,
      execute_fun: state.execute_fun,
      ui_port: (state.ui && state.ui.port) || nil,
      control_fun: fn :stop -> GenServer.cast(__MODULE__, :stop) end,
      queue_depth_fun: fn -> BeamLisp.Daemon.Executor.queue_depth() end,
      # What the worker is running, so the handshake can say "busy" before a
      # client sends anything (the launcher's busy → cold decision).
      executor_state_fun: fn -> BeamLisp.Daemon.Executor.state() end,
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

  @watch_heartbeat_ms 20_000

  # The default command path: hand the request to the Executor (one worker at a
  # time). `conn` is the connection handler pid, which routes stdin frames.
  #
  # A `bl watch` request is the ONE exception: the daemon HOSTS the watcher, so
  # the request must not hold the single Executor worker for the session's whole
  # life (it would block every later client forever). Only the reload APPLIES
  # ride the FIFO — the registry's apply_fun submits each through
  # `Executor.run_reload/2` — which is what orders a reload against the runs and
  # tests the daemon is serving. Every other argv path is unchanged.
  defp default_execute(sock, id, req, conn) do
    case watch_request(req.argv, req.cwd) do
      {:ok, st} ->
        watch_session(sock, id, req, conn, st)

      :refuse ->
        refuse_owning_verb(sock, id)

      :no ->
        vm_execute(sock, id, req, conn)
    end
  rescue
    e -> fail_execute(sock, id, Exception.message(e))
  catch
    # The WORKER's death, not the command's own failure. User code that links
    # (a `start-link` server, the demo's in-process MCP server) or a VM-level
    # fault takes the Executor down mid-request, and the `GenServer.call` above
    # exits — which `rescue` does not see. Uncaught, the CONNECTION dies with
    # it and the client is told "outcome unknown" about a reason this process
    # is holding in its hand. Report it: the worker is restarted by its
    # supervisor, and this frame is the difference between a diagnosis and a
    # mystery.
    :exit, reason -> fail_execute(sock, id, "the command worker died: #{inspect(reason)}")
  end

  # The commands that own their process for as long as it lives: a repl waiting
  # on stdin, a server, a watcher that repaints, an editor/agent transport, or a
  # project task declared `:watch`. The launcher already sends the first four to
  # a cold VM (see `owns_process` in tooling/drop/src/launcher.rs), so this is
  # the SAFETY NET for a spelling its own token test misses (`bl -p lib repl`)
  # and for the project-declared kind it cannot know about at all. Without it
  # the Executor would park on its single worker and every later client would
  # wait forever — the daemon would still look alive, which is the worst way to
  # fail.
  # THE VM COMMAND RUNNER (PLAN-121). Reuses the transport plumbing the old
  # Executor used — a per-request IO group-leader proxy so the program's stdout /
  # stdin become wire frames, and the client's `-p` roots bound as ambient search
  # dirs — but instead of a single serial GenServer it calls the pure-beam-lisp
  # `bl.daemon/handle-in-vm`, which resolves the request's project VM
  # (get-or-spawn, collision-proof id), binds the client's env PROCESS-LOCALLY
  # (never the node-global OS table), and runs `bl.cli/run-argv` under that VM's
  # capped env + scope. This body runs in the per-connection task the acceptor
  # spawned, so N concurrent requests are N processes — the FIFO is gone.
  defp vm_execute(sock, id, req, conn) do
    proxy = BeamLisp.Daemon.IO.start(sock, id, self())
    if is_pid(conn), do: send(conn, {:route_stdin, id, proxy})

    worker = self()
    prev_gl = Process.group_leader()
    :erlang.group_leader(proxy, worker)

    code =
      try do
        BeamLisp.Loader.with_ambient_dirs(vm_ambient_dirs(req), fn ->
          handle = BeamLisp.Env.fetch!("bl.daemon", "handle-in-vm")
          result =
            BeamLisp.RT.invoke(handle, [req.argv, req.cwd, Map.get(req, :env) || %{}])

          if is_integer(result), do: result, else: 0
        end)
      rescue
        e ->
          _ = :gen_tcp.send(sock, Protocol.stderr(id, 999_999, "bl: #{Exception.message(e)}\n"))
          1
      catch
        :throw, v ->
          _ = :gen_tcp.send(sock, Protocol.stderr(id, 999_999, "bl: uncaught throw: #{inspect(v)}\n"))
          1

        :exit, v ->
          _ = :gen_tcp.send(sock, Protocol.stderr(id, 999_999, "bl: process exit: #{inspect(v)}\n"))
          1
      after
        :erlang.group_leader(prev_gl, worker)
      end

    _final_seq = BeamLisp.Daemon.IO.finish(proxy)
    frame = if is_integer(code), do: Protocol.exit(id, code), else: Protocol.exit(id, 0)
    _ = :gen_tcp.send(sock, frame)
    code
  end

  # The client's library roots: its cwd first, then each `-p` path resolved
  # absolute against that cwd (same rule the old Executor used).
  defp vm_ambient_dirs(req) do
    cwd = req.cwd
    paths = for p <- Map.get(req, :env_paths, []), do: Path.expand(p, cwd)
    [cwd | paths]
  end

  # Start the pure-beam-lisp global VM manager (idempotent). Called once at
  # boot; the manager is a named defserver (:vm-manager) that hosts every
  # project VM for the life of the node.
  defp boot_vm_manager do
    BeamLisp.Loader.ensure_loaded("bl.daemon")
    boot = BeamLisp.Env.fetch!("bl.daemon", "boot-manager")
    BeamLisp.RT.invoke(boot, [])
    :ok
  rescue
    e -> Logger.error("bl daemon: vm.manager boot failed: #{Exception.message(e)}")
  end

  defp refuse_owning_verb(sock, id) do
    msg =
      "bl daemon: this command keeps its own process — run it without the daemon " <>
        "(BL_DAEMON=off bl ...)\n"

    _ = :gen_tcp.send(sock, Protocol.stderr(id, 0, msg))
    _ = :gen_tcp.send(sock, Protocol.exit(id, 1))
    1
  end

  # The message is a STRING, not an exception: two callers reach here — a
  # command that raised (message from the exception) and a command worker that
  # died (message from the exit reason).
  defp fail_execute(sock, id, message) when is_binary(message) do
    _ = :gen_tcp.send(sock, Protocol.stderr(id, 0, "bl daemon: #{message}\n"))
    _ = :gen_tcp.send(sock, Protocol.exit(id, 70))
    70
  end

  # Which of the three ways a request can go: a `bl watch` session the daemon
  # HOSTS, a command that keeps its own process (refused), or ordinary work for
  # the Executor.
  #
  # The decision is the CLI's OWN: `parse-argv` plus `bl.cli/owns-process?`, on
  # the CLIENT's cwd — the same grammar and the same project file a standalone
  # `bl` reads, so the two hosts cannot disagree about which spelling must go
  # cold. There is no cheap token pre-filter any more: a task name is only
  # knowable through the project, and a watch that fell through to the Executor
  # would park the single worker forever.
  defp watch_request(argv, cwd) do
    st = parse_argv(argv)

    cond do
      st.cmd == "watch" -> {:ok, st}
      owns_process?(argv, cwd) -> :refuse
      true -> :no
    end
  end

  # The CLI's answer to "does this command keep its process?"
  defp owns_process?(argv, cwd) do
    fun = BeamLisp.Env.fetch!("bl.cli", "owns-process?")
    BeamLisp.RT.invoke(fun, [argv, cwd]) == true
  rescue
    _ -> false
  end

  # A watch session. Frames it emits, all on the request id:
  #
  #   {:bl, 1, :stdout,    id, 0,   "bl watch: watching DIR — Ctrl+C to stop\n"}
  #   {:bl, 1, :stdout,    id, seq, rendered}        per reload commit
  #   {:bl, 1, :heartbeat, id, ms}                   every @watch_heartbeat_ms
  #
  # and NO terminal `:exit` frame — a watch stream is live until the client
  # disconnects, which is exactly what the launcher's `stream_until_exit` loops
  # on: it keeps reading (and printing `:stdout` bytes) until the socket is
  # lost, so Ctrl-C on the client is the end of the stream. The heartbeat keeps
  # that read from timing out while the watched directory is quiet. A usage or
  # registration error DOES send `:exit` (2 / 1) — the session never started.
  defp watch_session(sock, id, req, conn, st) do
    case watch_dir(st, req.cwd) do
      {:ok, dir} ->
        render = watch_renderer()
        seq = :atomics.new(1, [])

        notify = fn result ->
          # A render fault must not take the registry (every watcher) down.
          bytes =
            try do
              to_string(render.(result))
            rescue
              e -> "bl watch: render failed: #{Exception.message(e)}\n"
            end

          n = :atomics.add_get(seq, 1, 1)
          _ = :gen_tcp.send(sock, Protocol.stdout(id, n, bytes))
        end

        case WatchRegistry.watch(dir, {conn, id}, notify) do
          :ok ->
            line = "bl watch: watching #{dir} — Ctrl+C to stop\n"
            _ = :gen_tcp.send(sock, Protocol.stdout(id, 0, line))
            park_watch(sock, id, conn)
            0

          {:error, reason} ->
            _ = :gen_tcp.send(sock, Protocol.stderr(id, 0, watch_start_error(reason)))
            _ = :gen_tcp.send(sock, Protocol.exit(id, 1))
            1
        end

      {:error, :usage} ->
        _ = :gen_tcp.send(sock, Protocol.stderr(id, 0, "usage: bl watch FILE|DIR\n"))
        _ = :gen_tcp.send(sock, Protocol.exit(id, 2))
        2

      {:error, {:not_dir, arg}} ->
        _ = :gen_tcp.send(sock, Protocol.stderr(id, 0, "bl watch: not a directory: #{arg}\n"))
        _ = :gen_tcp.send(sock, Protocol.exit(id, 2))
        2
    end
  end

  # Park the session until the client is gone. The listener's connection
  # handler (`conn`) exits when its socket dies, so monitoring `conn` is the
  # teardown signal; the registry then drops this session's subscription on the
  # monitor it holds (see WatchRegistry). A heartbeat keeps the launcher's 30s
  # read timeout from expiring between commits.
  defp park_watch(sock, id, conn) do
    ref = Process.monitor(conn)

    try do
      loop_watch(sock, id, ref)
    after
      Process.demonitor(ref, [:flush])
    end
  end

  defp loop_watch(sock, id, ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} ->
        :ok
    after
      @watch_heartbeat_ms ->
        if :gen_tcp.send(sock, Protocol.heartbeat(id)) == :ok do
          loop_watch(sock, id, ref)
        else
          :ok
        end
    end
  end

  # The target is the CLI's own positional (the parse already happened in
  # `watch_request/1`), resolved against the CLIENT's cwd — never the daemon's
  # own checkout. A file names its own directory, so `bl watch foo.bl` and
  # `bl watch .` are the same request; a bad flag is the same usage error a
  # standalone `bl` would give.
  defp watch_dir(st, cwd) do
    cond do
      Map.get(st, :error) != nil ->
        {:error, :usage}

      Map.get(st, :unknown) != nil ->
        {:error, :usage}

      true ->
        case st |> Map.get(:args, []) |> Enum.to_list() do
          [target | _] -> resolve_watch_dir(target, cwd)
          _ -> {:error, :usage}
        end
    end
  end

  defp parse_argv(argv) do
    BeamLisp.Loader.ensure_loaded("bl.cli")
    parse = BeamLisp.Env.fetch!("bl.cli", "parse-argv")
    BeamLisp.RT.invoke(parse, [argv])
  end

  defp resolve_watch_dir(target, cwd) do
    path = Path.expand(target, cwd)

    cond do
      File.dir?(path) -> {:ok, path}
      File.regular?(path) -> {:ok, Path.dirname(path)}
      true -> {:error, {:not_dir, target}}
    end
  end

  # ONE renderer for both hosts: resolve `bl.watch/render` through the RT and
  # call it here, so the daemon's commit lines and a standalone `bl watch`'s are
  # produced by the same beam-lisp function and cannot drift.
  defp watch_renderer do
    BeamLisp.Loader.ensure_loaded("bl.watch")
    render = BeamLisp.Env.fetch!("bl.watch", "render")
    fn result -> BeamLisp.RT.invoke(render, [result]) end
  end

  defp watch_start_error(reason) do
    "bl watch: cannot start the watcher: #{inspect(reason)}\n" <>
      "  the live-reload engine needs the :file_system application; run `bl doctor`.\n"
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
