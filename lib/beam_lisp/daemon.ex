defmodule BeamLisp.Daemon do
  @moduledoc """
  The public facade for `bl daemon` lifecycle from the language CLI and the
  native launcher. Three verbs:

    * `start_foreground/1` — become the daemon (blocks). The launcher runs this
      in a detached OS process; `bl daemon start` in a terminal runs it in the
      foreground.
    * `status/1` — connect to a running daemon for `root` and print its status.
    * `stop/1` — ask a running daemon to drain and exit.

  All discovery goes through `BeamLisp.Daemon.Paths`; the socket is authority
  only after an authenticated hello. `status`/`stop` are ordinary clients that
  speak the wire protocol, so they exercise the same path a real client does.
  """

  alias BeamLisp.Daemon.{Paths, Protocol}

  @connect_timeout 500

  @doc """
  Run as the daemon for `root` (default: `BL_DAEMON_ROOT` or cwd), blocking the
  caller until the daemon stops. If one is already up for this tree, prints a
  notice and returns `:already_running` without starting a second.
  """
  def start_foreground(root \\ nil) do
    root = root || System.get_env("BL_DAEMON_ROOT") || File.cwd!()

    case probe(root) do
      {:ok, _meta} ->
        IO.puts("bl daemon: already running for #{root}")
        :already_running

      _ ->
        # PLAN-123 D3: the daemon is a pure-beam-lisp SESSION now — vm.session
        # composes vm.net (transport) + vm.io (proxy) + vm.manager (VMs) +
        # bl.daemon/handle-in-vm (commands). No Elixir Server. This boots it and
        # blocks until a :control :stop frame flips the persistent-term flag.
        BeamLisp.Loader.ensure_loaded("vm.session")
        start = BeamLisp.Env.fetch!("vm.session", "start")

        case BeamLisp.RT.invoke(start, [root]) do
          %{ok: _listener} = ok ->
            :persistent_term.put({:vm_session, :stop}, false)
            wait_for_stop()
            listener = Map.fetch!(ok, :ok)
            _ = BeamLisp.RT.invoke(BeamLisp.Env.fetch!("vm.session", "stop"), [listener])
            :ok

          other ->
            IO.puts(:stderr, "bl daemon: failed to start: #{inspect(other)}")
            {:error, other}
        end
    end
  end

  # Block the foreground caller until a :control :stop frame sets the flag.
  defp wait_for_stop do
    if :persistent_term.get({:vm_session, :stop}, false) do
      :ok
    else
      Process.sleep(200)
      wait_for_stop()
    end
  end

  @doc "Print the status of the daemon for `root`, or 'not running'. Returns 0/1."
  def status(root \\ nil) do
    root = resolve(root)

    case connect_hello(root) do
      {:ok, sock, _ready} ->
        id = :crypto.strong_rand_bytes(16)
        send_frame(sock, Protocol.encode({:bl, 1, :control, id, :status}))
        drain_to_exit(sock, id)
        :gen_tcp.close(sock)
        0

      {:error, reason} ->
        IO.puts("bl daemon: not running for #{root} (#{inspect(reason)})")
        1
    end
  end

  @doc "Stop the daemon for `root`. Returns 0 on stop, 1 if none was running."
  def stop(root \\ nil) do
    root = resolve(root)

    case connect_hello(root) do
      {:ok, sock, _ready} ->
        id = :crypto.strong_rand_bytes(16)
        send_frame(sock, Protocol.encode({:bl, 1, :control, id, :stop}))
        drain_to_exit(sock, id)
        :gen_tcp.close(sock)
        IO.puts("bl daemon: stopped (#{root})")
        0

      {:error, _} ->
        IO.puts("bl daemon: not running for #{root}")
        1
    end
  end

  @doc """
  Probe whether a live, authenticated daemon answers for `root`. Returns
  `{:ok, ready_meta}` or `{:error, reason}`. Used by the launcher's fast path
  and by `start_foreground` to avoid a double start.
  """
  def probe(root) do
    case connect_hello(resolve(root)) do
      {:ok, sock, ready} ->
        :gen_tcp.close(sock)
        {:ok, ready}

      err ->
        err
    end
  end

  # --- internals ---

  defp resolve(nil), do: System.get_env("BL_DAEMON_ROOT") || File.cwd!()
  defp resolve(root), do: root

  # Connect + hello handshake; returns the open socket on :ready.
  defp connect_hello(root) do
    with {:ok, ep} <- Paths.endpoints(root),
         true <- File.exists?(ep.sock) or {:error, :no_socket},
         {:ok, token} <- File.read(ep.token),
         {:ok, sock} <- do_connect(ep.sock) do
      tree = Paths.tree_fingerprint(root)
      send_frame(sock, Protocol.encode({:bl, 1, :hello, %{tree: tree, token: token}}))

      case recv_frame(sock) do
        {:ok, {:bl, 1, :ready, meta}} ->
          {:ok, sock, meta}

        {:ok, {:bl, 1, :reject, reason, _msg, _}} ->
          :gen_tcp.close(sock)
          {:error, {:reject, reason}}

        other ->
          :gen_tcp.close(sock)
          {:error, other}
      end
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :no_socket}
    end
  end

  defp do_connect(sock_path) do
    :gen_tcp.connect({:local, String.to_charlist(sock_path)}, 0, [
      {:inet_backend, :inet},
      :local,
      :binary,
      {:packet, 4},
      {:active, false}
    ], @connect_timeout)
  end

  defp drain_to_exit(sock, id) do
    case recv_frame(sock) do
      {:ok, {:bl, 1, :stdout, ^id, _seq, bytes}} ->
        IO.write(bytes)
        drain_to_exit(sock, id)

      {:ok, {:bl, 1, :stderr, ^id, _seq, bytes}} ->
        IO.write(:stderr, bytes)
        drain_to_exit(sock, id)

      {:ok, {:bl, 1, :accepted, ^id, _}} ->
        drain_to_exit(sock, id)

      {:ok, {:bl, 1, :exit, ^id, _code}} ->
        :ok

      {:ok, _other} ->
        drain_to_exit(sock, id)

      {:error, _} ->
        :ok
    end
  end

  defp send_frame(sock, bin), do: :gen_tcp.send(sock, bin)

  defp recv_frame(sock) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, bin} -> {:ok, :erlang.binary_to_term(bin)}
      other -> other
    end
  end
end
