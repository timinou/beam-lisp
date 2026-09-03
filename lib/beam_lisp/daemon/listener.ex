defmodule BeamLisp.Daemon.Listener do
  @moduledoc """
  The `AF_UNIX` acceptor for a `bl` daemon. Binds a pathname stream socket at
  the tree's endpoint, spawns one handler process per accepted connection, and
  runs the hello handshake before any command is admitted.

  Framing is OTP `{packet, 4}` — a 4-byte big-endian length prefix per frame —
  over the legacy `inet` backend (the newer `socket` backend does not support
  local-domain `gen_tcp`). Each connection carries exactly one logical client
  session: hello → (request | control) → terminal frame.

  S1 scope: bind/accept/handshake/`:control :status`/`:control :stop`.
  Command execution (`:request`) is delegated to `execute_fun`, injected by the
  server so this module stays pure transport.
  """

  require Logger
  alias BeamLisp.Daemon.Protocol

  @accept_timeout 250

  @doc """
  Open a listening socket at `sock_path`. Returns `{:ok, lsock}` or
  `{:error, reason}`. Removes a stale socket node ONLY when it is a socket file
  in our own runtime dir (the caller has already proven no live daemon answers).
  """
  def listen(sock_path) when is_binary(sock_path) do
    _ = maybe_unlink_stale(sock_path)
    charlist = String.to_charlist(sock_path)

    :gen_tcp.listen(0, [
      {:inet_backend, :inet},
      :local,
      {:ifaddr, {:local, charlist}},
      :binary,
      {:packet, 4},
      {:packet_size, Protocol.max_frame()},
      {:active, false},
      {:reuseaddr, true},
      {:send_timeout, 5_000},
      {:send_timeout_close, true}
    ])
  end

  @doc """
  Loop accepting connections until `should_stop.()` returns true. Each accepted
  socket is handed to a spawned handler. `ctx` is the server context map passed
  to every handler (token, meta, execute_fun, control_fun).
  """
  def accept_loop(lsock, ctx, should_stop) when is_function(should_stop, 0) do
    if should_stop.() do
      :ok
    else
      case :gen_tcp.accept(lsock, @accept_timeout) do
        {:ok, sock} ->
          {pid, _ref} = spawn_monitor(fn -> handle_connection(sock, ctx) end)
          :ok = :gen_tcp.controlling_process(sock, pid)
          send(pid, :go)
          accept_loop(lsock, ctx, should_stop)

        {:error, :timeout} ->
          accept_loop(lsock, ctx, should_stop)

        {:error, :closed} ->
          :ok

        {:error, reason} ->
          Logger.debug("bl daemon accept error: #{inspect(reason)}")
          accept_loop(lsock, ctx, should_stop)
      end
    end
  end

  # --- per-connection handler ---

  def handle_connection(sock, ctx) do
    receive do
      :go -> :ok
    after
      1_000 -> :ok
    end

    with {:ok, frame} <- recv(sock),
         {:ok, {:hello, hello}} <- Protocol.decode(frame),
         :ok <- authorize(hello, ctx) do
      send_frame(sock, Protocol.ready(ready_meta(ctx)))
      serve(sock, ctx)
    else
      {:ok, _non_hello} ->
        send_frame(sock, Protocol.reject(:protocol_mismatch, "expected hello", %{}))
        close(sock)

      {:error, {:reject, reason, msg}} ->
        send_frame(sock, Protocol.reject(reason, msg, ready_meta(ctx)))
        close(sock)

      {:error, _reason} ->
        send_frame(sock, Protocol.reject(:malformed, "bad handshake", %{}))
        close(sock)
    end
  end

  # After a successful hello: one request or control op, then close.
  defp serve(sock, ctx) do
    case recv(sock) do
      {:ok, frame} ->
        case Protocol.decode(frame) do
          {:ok, {:control, id, :status}} ->
            send_frame(sock, Protocol.stdout(id, 0, status_text(ctx)))
            send_frame(sock, Protocol.exit(id, 0))
            close(sock)

          {:ok, {:control, id, :stop}} ->
            send_frame(sock, Protocol.accepted(id, 0))
            ctx.control_fun.(:stop)
            send_frame(sock, Protocol.exit(id, 0))
            close(sock)

          {:ok, {:request, id, req}} ->
            serve_request(sock, id, req, ctx)
            close(sock)

          {:ok, _other} ->
            close(sock)

          {:error, _} ->
            close(sock)
        end

      {:error, _} ->
        close(sock)
    end
  end

  # Run the command on the executor while concurrently pumping the client's
  # stdin frames to the IO proxy. The executor call blocks in a spawned task;
  # this process owns the socket and routes `:stdin_reply` frames it reads to
  # the proxy pid the executor registers via `{:route_stdin, id, proxy}`.
  defp serve_request(sock, id, req, ctx) do
    me = self()
    task = spawn_monitor(fn -> ctx.execute_fun.(sock, id, req, me) end)
    pump_stdin(sock, id, task, nil)
  end

  defp pump_stdin(sock, id, {task_pid, task_ref} = task, proxy) do
    receive do
      {:route_stdin, ^id, p} ->
        pump_stdin(sock, id, task, p)

      {:DOWN, ^task_ref, :process, ^task_pid, _reason} ->
        :ok
    after
      0 ->
        # non-blocking socket poll for a stdin frame; short timeout so we keep
        # checking the task's completion.
        case :gen_tcp.recv(sock, 0, 50) do
          {:ok, frame} ->
            case Protocol.decode(frame) do
              {:ok, {:stdin_reply, ^id, seq, data}} when is_pid(proxy) ->
                send(proxy, {:stdin_reply, seq, data})

              _ ->
                :ok
            end

            pump_stdin(sock, id, task, proxy)

          {:error, :timeout} ->
            pump_stdin(sock, id, task, proxy)

          {:error, _} ->
            # client vanished; wait for the task to notice via a failed send
            wait_task(task)
        end
    end
  end

  defp wait_task({task_pid, task_ref}) do
    receive do
      {:DOWN, ^task_ref, :process, ^task_pid, _} -> :ok
    after
      30_000 -> :ok
    end
  end

  # --- handshake authorization ---

  defp authorize(%{token: token, tree: tree} = hello, ctx) do
    cond do
      not secure_compare(token, ctx.token) ->
        {:error, {:reject, :unauthorized, "bad token"}}

      tree != ctx.tree ->
        {:error, {:reject, :wrong_tree, "tree mismatch"}}

      ctx[:shutting_down] == true ->
        {:error, {:reject, :shutting_down, "daemon draining"}}

      version_skew?(hello, ctx) ->
        {:error, {:reject, :restart_required, "compiler key / build id changed"}}

      true ->
        :ok
    end
  end

  # A client that knows its own tree's current key sends it; if the daemon's
  # startup key differs, the daemon is stale and MUST restart (never hot-swap).
  # A client that omits the key (nil) skips the check — the launcher fills it in
  # when the sidecar is present.
  defp version_skew?(%{compiler_key: ck}, ctx) when is_binary(ck) do
    is_binary(ctx[:compiler_key]) and ck != ctx.compiler_key
  end

  defp version_skew?(_, _), do: false

  defp ready_meta(ctx) do
    %{
      pid: :os.getpid() |> List.to_string(),
      compiler_key: ctx[:compiler_key],
      daemon_build_id: ctx[:daemon_build_id],
      uptime_ms: uptime_ms(ctx),
      queue_depth: (if is_function(ctx[:queue_depth_fun], 0), do: ctx.queue_depth_fun.(), else: 0)
    }
  end

  defp status_text(ctx) do
    meta = ready_meta(ctx)

    """
    bl daemon
      pid           #{meta.pid}
      tree          #{Base.encode16(ctx.tree, case: :lower) |> binary_part(0, 16)}
      compiler_key  #{meta.compiler_key || "(none)"}
      build_id      #{meta.daemon_build_id || "(none)"}
      uptime_ms     #{meta.uptime_ms}
      queue_depth   #{meta.queue_depth}
    """
  end

  defp uptime_ms(ctx) do
    case ctx[:started_at] do
      t when is_integer(t) -> System.monotonic_time(:millisecond) - t
      _ -> 0
    end
  end

  # --- socket io ---

  defp recv(sock), do: :gen_tcp.recv(sock, 0, 30_000)

  defp send_frame(sock, bin) do
    case :gen_tcp.send(sock, bin) do
      :ok -> :ok
      {:error, _} -> :error
    end
  end

  defp close(sock), do: :gen_tcp.close(sock)

  # constant-time token comparison
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _), do: false

  defp maybe_unlink_stale(sock_path) do
    case :file.read_link_info(String.to_charlist(sock_path)) do
      {:ok, info} ->
        # only unlink a real socket node we own; never a symlink/regular file
        case elem(info, 2) do
          :other -> File.rm(sock_path)
          _ -> :ok
        end

      _ ->
        :ok
    end
  end
end
