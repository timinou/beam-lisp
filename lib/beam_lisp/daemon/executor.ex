defmodule BeamLisp.Daemon.Executor do
  @moduledoc """
  The daemon's serialization point. Every command (and, later, every reload
  commit) runs through ONE worker at a time — because a beam-lisp program shares
  VM-global state with the daemon: loaded modules, the pinned Loader.Server, ETS
  tables, NIF state. Parallel requests would race namespace loads and module
  creation. Env vars ARE forked per request (`Env.isolated`), but the global
  layer cannot be; the FIFO is what keeps "one program at a time" honest while
  clients stay responsive via queue/heartbeat frames on their own sockets.

  A request is `%{argv, cwd, env_paths, tty}` plus the client socket and request
  id. The executor:

    1. installs a per-request group-leader proxy (BeamLisp.Daemon.IO) so the
       program's stdout/stdin become wire frames,
    2. binds the CLIENT's roots (`Loader.with_ambient_dirs`) and program argv
       (`BeamLisp.with_argv`) and a fresh forked env (`Env.isolated`),
    3. calls the language entry `bl.daemon/handle` with the raw argv + cwd,
    4. maps the returned exit code (or a caught fault → 1) to an `:exit` /
       `:failed` terminal frame ordered AFTER the last output.

  `System.halt` inside a program is NOT trappable and kills the whole daemon;
  that is the same trust level as a standalone run and is documented, not
  worked around. A client that loses the socket mid-request gets "unknown
  outcome"; the executor never replays.
  """

  use GenServer
  require Logger

  alias BeamLisp.Daemon.{IO, Protocol}

  # --- public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Submit a client request for serialized execution. `conn` is the connection
  handler pid (receives stdin routing); returns after the command completes and
  the terminal frame is sent. Blocking by design — the caller is the per-conn
  handler, one per client.
  """
  def run(server \\ __MODULE__, sock, id, req, conn) do
    GenServer.call(server, {:run, sock, id, req, conn}, :infinity)
  end

  @doc "Current queue depth (0 when idle)."
  def queue_depth(server \\ __MODULE__) do
    GenServer.call(server, :queue_depth)
  catch
    :exit, _ -> 0
  end

  # --- GenServer: a single worker, calls serialized by the mailbox ---

  @impl true
  def init(opts) do
    {:ok, %{active: 0, handler: Keyword.get(opts, :handler, &default_handler/2)}}
  end

  @impl true
  def handle_call(:queue_depth, _from, state) do
    {:reply, state.active, state}
  end

  @impl true
  def handle_call({:run, sock, id, req, conn}, _from, state) do
    # Serialized: this call blocks the executor until the command finishes, so
    # only one program runs at a time. Concurrent clients queue in the mailbox.
    code = execute(sock, id, req, conn, state.handler)
    {:reply, code, state}
  end

  # --- execution ---

  defp execute(sock, id, req, conn, handler) do
    proxy = IO.start(sock, id, self())
    # route this request's stdin replies from the connection handler to the proxy
    if is_pid(conn), do: send(conn, {:route_stdin, id, proxy})

    worker = self()
    prev_gl = Process.group_leader()
    :erlang.group_leader(proxy, worker)

    code =
      try do
        BeamLisp.Env.isolated(:global, fn ->
          BeamLisp.Loader.with_ambient_dirs(ambient_dirs(req), fn ->
            # The program argv (post-`--`) is bound by `bl.cli/cmd-run` from the
            # parsed `:dd`; the handler owns that. Here we only fix the roots
            # and the fresh env; the language dispatch does the rest.
            handler.(req.argv, req.cwd)
          end)
        end)
      rescue
        e ->
          msg = Exception.message(e)
          _ = :gen_tcp.send(sock, Protocol.stderr(id, 999_999, "bl: #{msg}\n"))
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

    # order the terminal frame after the last output flush
    _final_seq = IO.finish(proxy)

    frame = if is_integer(code), do: Protocol.exit(id, code), else: Protocol.exit(id, 0)
    _ = :gen_tcp.send(sock, frame)
    code
  end

  # The client's roots: its cwd first, then each `-p` path resolved to absolute
  # against that cwd, then the daemon's own extra dirs so libraries in the
  # checkout still resolve.
  defp ambient_dirs(req) do
    cwd = req.cwd
    paths = for p <- req.env_paths, do: Path.expand(p, cwd)
    [cwd | paths]
  end


  # The command handler: route through the beam-lisp `bl.daemon/handle`, which
  # binds cwd and dispatches via the SAME `bl.cli/run-argv` a standalone `bl`
  # runs. The worker's group leader is the IO proxy, so every print the program
  # performs becomes a client frame. The result is an exit-code integer.
  #
  # `cwd` is already bound linguistically inside handle/2; it is also passed so
  # a caller-injected test handler can use it directly.
  defp default_handler(argv, cwd) do
    BeamLisp.Loader.ensure_loaded("bl.daemon")
    handle = BeamLisp.Env.fetch!("bl.daemon", "handle")
    code = BeamLisp.RT.invoke(handle, [argv, cwd])
    if is_integer(code), do: code, else: 0
  end
end
