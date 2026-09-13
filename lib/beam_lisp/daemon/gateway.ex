defmodule BeamLisp.Daemon.Gateway do
  @moduledoc """
  The one listener that answers NAMES.

  DNS maps a name to an ADDRESS and never to a port. `*.test` and `*.localhost`
  already resolve to loopback, so a name can only reach the right listener if
  something reads the name off the request and hands it to the port behind it.
  That is this module: one gateway per USER — not per tree, because the whole
  point is to hold one port — routing `Host:` to the claim that owns it.

  ## Routing IS the registry

  The routing table is `BeamLisp.Daemon.Ports`. Every claim carries the hosts it
  answers to, because the process holding the port is the one that knows its
  name (`BeamLisp.Daemon.Names` derives them). So this module never reads a
  project file, never derives a name, and a claim that appears or dies changes
  routing on the very next request — no cache to invalidate, nothing to
  restart.

  ## Opaque after the head

  Only the request head is read, and only to learn the host. Once it is known
  the two sockets are spliced and every byte after it — a WebSocket upgrade, an
  Server-Sent-Event stream, a chunked upload, a keep-alive pipeline — is
  forwarded without being understood. That is what keeps this small enough to
  trust and complete enough to be useful: it is a TCP proxy that reads one
  header.

  ## Where it listens

  Loopback only, both families: `127.0.0.1` and `::1`. A name is a developer's
  own, and binding every interface would hand a LAN neighbour every dev server
  on the machine. `*.localhost` resolves to `::1` on a systemd host, so the v6
  listener is not a nicety.

  Port 80 is the one HTTP port a URL may omit. Binding it needs either privilege
  or the one sysctl that makes low ports unprivileged
  (`net.ipv4.ip_unprivileged_port_start=80`); without it an unpinned gateway
  falls back to #{7777} and says so, in as many words, with the fix. It never
  silently moves a port a caller PINNED — a pinned port that is taken is an
  error, not an inconvenience to paper over.
  """

  use GenServer
  require Logger

  alias BeamLisp.Daemon.{Paths, Ports}

  @preferred_port 80
  @fallback_port 7777
  @endpoint_name "gateway"
  @head_limit 32 * 1024
  @head_timeout 10_000
  @connect_timeout 2_000
  # A spliced connection with no bytes in either direction for this long is
  # dropped. Generous on purpose: a dev page holds a keep-alive or a WebSocket
  # open for a long time, and an abandoned socket is only worth reclaiming
  # eventually.
  @idle_ms 600_000
  @socket_opts [:binary, {:packet, :raw}, {:active, false}, {:nodelay, true}, {:reuseaddr, true}]
  @index_hosts ~w(localhost 127.0.0.1 [::1] ::1 0.0.0.0)
  @reasons %{200 => "OK", 400 => "Bad Request", 404 => "Not Found", 502 => "Bad Gateway"}

  # --- public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run the gateway in the foreground until it stops. This is what
  `bl gateway run` calls and what the systemd unit execs; it blocks on purpose,
  like `bl monitor` and `bl serve`.
  """
  def run(opts \\ []) do
    # `start`, not `start_link`: a foreground command's failure is a VALUE
    # (`{:error, reason}`), and a link turns it into a raw crash report —
    # `** (EXIT from #PID<…>) {:gateway_failed, {:port, 1, :eacces}}` — which
    # reads like the tool broke rather than like the port was wrong.
    case GenServer.start(__MODULE__, opts, name: __MODULE__) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} -> {:error, reason}
        end

      other ->
        other
    end
  end

  @doc """
  The endpoint of a LIVE gateway: `{:ok, %{pid, port, ips, started_at}}`, or
  `:error`. The endpoint file's existence is discovery; its owner's liveness is
  what makes it true, so a crashed gateway leaves nothing behind to trip over.
  """
  def endpoint do
    with {:ok, dir} <- Paths.runtime_dir(),
         path = Path.join(dir, @endpoint_name),
         {:ok, bin} <- File.read(path),
         {:ok, %{pid: pid} = ep} <- safe_term(bin) do
      if Ports.alive_pid?(pid) do
        {:ok, Map.merge(%{ips: [], port: nil, started_at: 0}, ep)}
      else
        _ = File.rm(path)
        :error
      end
    else
      _ -> :error
    end
  end

  @doc """
  The port the live gateway answers on, or nil when none is running.

  A gateway in THIS VM answers for itself; otherwise the endpoint file does,
  which is how a `bl` command that started no gateway still finds the one the
  machine is running.
  """
  def port do
    case Process.whereis(__MODULE__) do
      nil ->
        case endpoint() do
          {:ok, ep} -> ep.port
          :error -> nil
        end

      pid ->
        GenServer.call(pid, :port)
    end
  end

  @doc """
  The address `host` answers at — what a human should type, and what every verb
  prints.

  The port appears ONLY when it has to. On 80 (the one HTTP port a URL may
  leave out) the name stands alone: `http://web.pulse.test/`. Standing on the
  fallback it does not: `http://web.pulse.test:7777/`. A printed address that
  omits the port nothing is listening on is worse than no address at all — it
  looks clickable and answers `connection refused`.

  With no gateway running there is nothing to route, so the name is printed
  bare, and the caller is responsible for saying so: every verb that prints one
  pairs it with the loopback address that IS answering.
  """
  def url(host, port \\ nil)

  def url(host, nil), do: url(host, port())
  def url(host, port) when port == nil or port == @preferred_port, do: "http://#{host}/"
  def url(host, port), do: "http://#{host}:#{port}/"

  @doc """
  Stop the running gateway. A signal, not a protocol: the gateway is one OS
  process on this machine and `kill` is what a Unix has for this. Returns `:ok`
  when it is gone, `{:error, reason}` otherwise.
  """
  def stop(timeout \\ 5_000) do
    case Process.whereis(__MODULE__) do
      nil ->
        case endpoint() do
          :error ->
            :ok

          {:ok, %{pid: pid}} ->
            _ = System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
            wait_gone(pid, timeout)
        end

      pid ->
        # a gateway in this VM is stopped in-VM: signalling our own process
        # group would be a surprising way to answer "stop the gateway".
        GenServer.stop(pid, :normal, timeout)
    end
  end

  @doc """
  The live claims that answer to a name — the routes the gateway serves. A claim
  without hosts is a port nobody named, and is not routable.
  """
  def routes do
    Enum.filter(Ports.list(), fn c -> Map.get(c, :hosts, []) != [] end)
  end

  @doc """
  The command that starts THIS beam-lisp: `$BL_BIN`, else `bl` on the PATH,
  else nil (a checkout that is installed nowhere). The systemd unit and a
  detached start both go through here, so there is one answer to "which bl?".
  """
  def command do
    case System.get_env("BL_BIN") do
      bin when is_binary(bin) and bin != "" -> bin
      _ -> System.find_executable("bl")
    end
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    want = Keyword.get(opts, :port)

    case start_gateway(want) do
      {:ok, listeners, port, note} ->
        # Only a gateway that CHOSE its port is THE gateway of this machine.
        # An ephemeral one (`port: 0` — a test, or one deliberately moved
        # aside) publishing the single endpoint file would take over the
        # answer to "where is the gateway", and deleting it on exit would
        # leave the real one undiscoverable: `bl gateway stop` would report
        # "not running" while it kept serving every name.
        if want != 0, do: write_endpoint(port)

        state = %{
          listeners: listeners,
          port: port,
          note: note,
          ips: Enum.map(listeners, fn {_family, ip, _sock} -> ip end),
          started_at: System.system_time(:second)
        }

        Enum.each(state.listeners, fn {_family, _ip, sock} -> start_acceptor(sock) end)
        Logger.info("bl gateway on #{port}")
        IO.puts(banner(state))
        {:ok, state}

      {:error, reason} ->
        {:stop, {:gateway_failed, reason}}
    end
  end

  # One gateway, or an ephemeral one. The guard lives here (not in the verb)
  # because `bl gateway run` is also what a systemd unit execs and what a
  # second terminal can type: the rule belongs to the process that binds.
  defp start_gateway(want) do
    with :ok <- no_live_gateway(want), do: listen(want)
  end

  # ONE gateway per user: it holds the port a URL may omit, and its endpoint
  # file is the single answer to "where is it". A second one would bind
  # somewhere else and overwrite that answer, leaving the first serving names
  # nobody can reach — so a second start names the running one instead.
  #
  # `port: 0` is the exception, on purpose: an ephemeral gateway claims no port
  # anyone chose (a test, or one deliberately moved aside), and refusing it
  # would make the gateway untestable on a developer's machine.
  defp no_live_gateway(0), do: :ok

  defp no_live_gateway(_want) do
    case endpoint() do
      {:ok, ep} ->
        {:error,
         "a gateway is already up on port #{ep.port} (pid #{ep.pid}) — " <>
           "`bl gateway stop` first, or run one on an ephemeral port with `--port 0`"}

      :error ->
        :ok
    end
  end

  # A pinned port is a promise, and a promise that cannot be kept is a
  # SENTENCE — which port, why, and what to do — never a bare `:eacces`. The
  # caller is a developer reading `bl gateway run --port 80`'s last line.
  defp pinned_refusal(port, :eacces) do
    "port #{port} is privileged here — #{sysctl_advice()} " <>
      "(or run it unpinned: it prefers #{@preferred_port} and falls back to #{@fallback_port})"
  end

  defp pinned_refusal(port, :eaddrinuse) do
    "port #{port} is already held by something else — pick another, " <>
      "or run unpinned (prefers #{@preferred_port}, falls back to #{@fallback_port})"
  end

  defp pinned_refusal(port, reason) do
    "port #{port} cannot be bound (#{inspect(reason)})"
  end

  # The one root step that makes low ports the user's (a reboot-surviving copy
  # belongs in /etc/sysctl.d/). One sentence, used by the banner AND by a
  # refusal, so the two cannot drift.
  defp sysctl_advice do
    "sudo sysctl -w net.ipv4.ip_unprivileged_port_start=#{@preferred_port}"
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def terminate(_reason, _state) do
    # Delete the file only when it names US: a gateway that exits must not
    # erase another one's discovery, and an ephemeral one never wrote it.
    me = List.to_integer(:os.getpid())

    case endpoint() do
      {:ok, %{pid: ^me}} ->
        case Paths.runtime_dir() do
          {:ok, dir} -> File.rm(Path.join(dir, @endpoint_name))
          _ -> :ok
        end

      _ ->
        :ok
    end

    :ok
  end

  # --- listening ---

  # A pinned port is a promise: try it, and fail loudly if it is not ours to
  # take. An unpinned gateway prefers 80 (the port a URL may omit), degrades to
  # the fallback, and finally lets the OS choose — each step recorded in `note`
  # so the banner can say what happened and why.
  defp listen(want) when is_integer(want) do
    case bind_all(want) do
      {:ok, listeners, port} -> {:ok, listeners, port, nil}
      {:error, reason} -> {:error, pinned_refusal(want, reason)}
    end
  end

  defp listen(_unpinned) do
    Enum.reduce_while([@preferred_port, @fallback_port, 0], {:error, :no_port}, fn candidate, _ac ->
      case bind_all(candidate) do
        {:ok, listeners, port} ->
          note = if port == @preferred_port, do: nil, else: degraded_note(port)
          {:halt, {:ok, listeners, port, note}}

        {:error, reason} ->
          if candidate == 0, do: {:halt, {:error, reason}}, else: {:cont, {:error, reason}}
      end
    end)
  end

  # Loopback on both families. The v6 socket is optional: a host without IPv6
  # still gets a working gateway on v4.
  defp bind_all(port) do
    case :gen_tcp.listen(port, [{:ip, {127, 0, 0, 1}} | @socket_opts]) do
      {:ok, v4} ->
        actual = sock_port(v4, port)
        listeners = [{:inet, "127.0.0.1", v4}]

        listeners =
          case :gen_tcp.listen(actual, [{:ip, {0, 0, 0, 0, 0, 0, 0, 1}}, :inet6 | @socket_opts]) do
            {:ok, v6} -> listeners ++ [{:inet6, "::1", v6}]
            {:error, _} -> listeners
          end

        {:ok, listeners, actual}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sock_port(sock, fallback) do
    case :inet.sockname(sock) do
      {:ok, {_ip, port}} -> port
      _ -> fallback
    end
  end

  # Why the gateway is NOT on the port it wanted. The question is about the port
  # it wanted — not about the one it got, which by definition is fine, and whose
  # probe would happily answer "free" and produce a sentence about nothing.
  defp degraded_note(port) do
    why =
      case bind_error(@preferred_port) do
        :eacces ->
          """
          port #{@preferred_port} is privileged here — on #{port} for now.
            one root step frees it, for good:
              #{sysctl_advice()}  (in /etc/sysctl.d/ to survive a reboot)\
          """

        :eaddrinuse ->
          "port #{@preferred_port} is held by another process — on #{port} for now."

        :free ->
          "port #{@preferred_port} was not bindable — on #{port} for now."

        other ->
          "port #{@preferred_port} is not ours (#{inspect(other)}) — on #{port} for now."
      end

    # The fallback port is where ONE gateway per user is expected to live. If it
    # is busy too and we are somewhere else again, say who is likely sitting on
    # it: a gateway from a build that ran before the endpoint file existed for
    # it (or one whose file was removed) cannot be found by `bl gateway stop`,
    # and the remedy is a word, not a mystery.
    if port != @fallback_port and bind_error(@fallback_port) == :eaddrinuse do
      why <>
        "\n  port #{@fallback_port} is held by a process that is not the gateway this machine knows —" <>
        " an older one, most likely: pkill -f 'gateway run'"
    else
      why
    end
  end

  # Why the preferred port was refused. Asked separately because the reduce
  # above only keeps the last error, and "privileged" and "taken" deserve
  # different sentences.
  defp bind_error(port) do
    case :gen_tcp.listen(port, [{:ip, {127, 0, 0, 1}} | @socket_opts]) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :free

      {:error, reason} ->
        reason
    end
  end

  defp banner(state) do
    ips = state.ips |> Enum.map(&"#{&1}:#{state.port}") |> Enum.join("  ")

    ["bl gateway on #{ips}", "  names answer here: #{route_summary()}"]
    |> append_note(state.note)
    |> Enum.join("\n")
  end

  defp append_note(lines, nil), do: lines

  defp append_note(lines, note) do
    lines ++ Enum.map(String.split(String.trim(note), "\n"), &("  " <> &1))
  end

  defp route_summary do
    case routes() do
      [] -> "none yet (a claim that carries hosts registers one)"
      rs -> Enum.map_join(rs, ", ", fn c -> "#{List.first(c.hosts)} → #{c.port}" end)
    end
  end

  defp write_endpoint(port) do
    with {:ok, dir} <- Paths.runtime_dir() do
      path = Path.join(dir, @endpoint_name)
      tmp = path <> ".tmp"

      ep = %{
        pid: :os.getpid() |> List.to_integer(),
        port: port,
        started_at: System.system_time(:second)
      }

      _ = File.write(tmp, :erlang.term_to_binary(ep))
      _ = File.chmod(tmp, 0o600)
      File.rename(tmp, path)
    end

    :ok
  end

  defp safe_term(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    _ -> :error
  end

  defp wait_gone(_pid, timeout) when timeout <= 0, do: {:error, :still_running}

  defp wait_gone(pid, timeout) do
    if Ports.alive_pid?(pid) do
      Process.sleep(50)
      wait_gone(pid, timeout - 50)
    else
      :ok
    end
  end

  # --- accepting ---

  defp start_acceptor(sock) do
    spawn(fn -> accept_loop(sock) end)
  end

  defp accept_loop(sock) do
    case :gen_tcp.accept(sock, :infinity) do
      {:ok, client} ->
        # Unlinked: a client's problem is never the listener's problem.
        #
        # The handoff matters and is not ceremony: `active:` messages go to
        # the socket's CONTROLLING process, which an accept leaves as this
        # acceptor. A handler that only did passive reads would work by
        # accident — and then never see a byte the client sends after the
        # head, because those wake the acceptor's mailbox instead. So the
        # handler is spawned first and given the socket, then told to go.
        handler = spawn(fn -> wait_for_go(client) end)
        :ok = :gen_tcp.controlling_process(client, handler)
        send(handler, :go)
        accept_loop(sock)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(sock)
    end
  end

  defp wait_for_go(client) do
    receive do
      :go -> handle(client)
    after
      5_000 -> :gen_tcp.close(client)
    end
  end

  # --- one request ---

  defp handle(client) do
    case read_head(client, <<>>) do
      {:ok, head, rest} ->
        route(client, head, rest)

      {:error, _reason} ->
        # Not even a head: a port scan, a probe, a client that vanished. Say
        # nothing useful and close.
        :gen_tcp.close(client)
    end
  end

  defp route(client, head, rest) do
    host = host_of(head)

    cond do
      host == nil ->
        reply(
          client,
          400,
          page("no Host header", "<p>An HTTP/1.1 request must name the host it wants.</p>")
        )

      index_host?(host) ->
        reply(client, 200, page("beam-lisp gateway", index_body()))

      true ->
        case Ports.holder_of_host(host) do
          nil ->
            reply(
              client,
              404,
              page(
                "nothing answers to #{esc(host)}",
                "<p>No live port claims that name.</p>" <> index_body()
              )
            )

          claim ->
            splice(client, claim, host, head, rest)
        end
    end
  end

  defp splice(client, claim, host, head, rest) do
    case connect_backend(claim.port) do
      {:ok, backend} ->
        :ok = :gen_tcp.send(backend, [head, rest])
        pipe(client, backend)

      {:error, reason} ->
        name = to_string(claim.name)

        reply(
          client,
          502,
          page(
            "#{esc(host)} is claimed but not answering",
            "<p><code>#{esc(host)}</code> is the name of port #{claim.port} " <>
              "(the project calls it <code>#{esc(name)}</code>; pid #{claim.pid}) " <>
              "and nothing accepted the connection there (#{inspect(reason)}). The process may " <>
              "be on its way down; a claim is swept as soon as its owner is gone.</p>"
          )
        )
    end
  end

  # A backend listens on whatever its framework bound. Loopback v4 is the
  # common case (bandit's default takes every interface); a listener bound to
  # `::1` only is the other, so it is tried before giving up.
  defp connect_backend(port) do
    opts = [:binary, {:packet, :raw}, {:active, false}, {:nodelay, true}]

    case :gen_tcp.connect({127, 0, 0, 1}, port, opts, @connect_timeout) do
      {:ok, sock} ->
        {:ok, sock}

      {:error, _} ->
        case :gen_tcp.connect({0, 0, 0, 0, 0, 0, 0, 1}, port, [:inet6 | opts], @connect_timeout) do
          {:ok, sock} -> {:ok, sock}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # One process, both directions, `active: :once` on each socket so a close on
  # EITHER side is seen even while the other is quiet. A half-close is
  # propagated as a write-shutdown rather than a hang — which is what lets an
  # HTTP client that finished sending still read the whole response.
  defp pipe(client, backend) do
    arm(client)
    arm(backend)
    pump(client, backend, true, true)
  end

  defp arm(sock), do: :inet.setopts(sock, active: :once)

  defp pump(client, backend, client_open, backend_open) do
    receive do
      {:tcp, ^client, data} ->
        :gen_tcp.send(backend, data)
        arm(client)
        pump(client, backend, client_open, backend_open)

      {:tcp, ^backend, data} ->
        :gen_tcp.send(client, data)
        arm(backend)
        pump(client, backend, client_open, backend_open)

      {:tcp_closed, ^client} ->
        if backend_open do
          _ = :gen_tcp.shutdown(backend, :write)
          pump(client, backend, false, backend_open)
        else
          close_both(client, backend)
        end

      {:tcp_closed, ^backend} ->
        if client_open do
          _ = :gen_tcp.shutdown(client, :write)
          pump(client, backend, client_open, false)
        else
          close_both(client, backend)
        end

      {:tcp_error, sock, _reason} when sock == client or sock == backend ->
        close_both(client, backend)
    after
      @idle_ms -> close_both(client, backend)
    end
  end

  defp close_both(a, b) do
    _ = :gen_tcp.close(a)
    _ = :gen_tcp.close(b)
    :ok
  end

  # --- reading a head ---

  # Read until the blank line that ends the head. Everything after it is
  # payload, and is carried along untouched: a request body already in flight
  # must not be lost between the read and the splice.
  defp read_head(_sock, acc) when byte_size(acc) > @head_limit do
    {:error, :head_too_large}
  end

  defp read_head(sock, acc) do
    case :binary.match(acc, "\r\n\r\n") do
      {pos, 4} ->
        len = pos + 4
        {:ok, binary_part(acc, 0, len), binary_part(acc, len, byte_size(acc) - len)}

      :nomatch ->
        case :gen_tcp.recv(sock, 0, @head_timeout) do
          {:ok, data} -> read_head(sock, acc <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # --- the host ---

  defp host_of(head) do
    [request_line | headers] = String.split(head, "\r\n", trim: true)

    from_header =
      Enum.find_value(headers, fn line ->
        case String.split(line, ":", parts: 2) do
          [k, v] -> if String.downcase(String.trim(k)) == "host", do: String.trim(v)
          _ -> nil
        end
      end)

    normalize_host(from_header) || request_line_host(request_line)
  end

  defp normalize_host(nil), do: nil
  defp normalize_host(""), do: nil

  defp normalize_host(host) do
    h = host |> String.trim() |> String.downcase()

    if String.starts_with?(h, "[") do
      case String.split(h, "]", parts: 2) do
        [inside, _rest] -> inside <> "]"
        _ -> h
      end
    else
      h |> String.split(":") |> List.first() |> String.trim()
    end
  end

  # An absolute-form request line (`GET http://web.pulse.test/x HTTP/1.1`) names
  # the host without a header. Rare, legal, and one line to honour.
  defp request_line_host(line) do
    with [_method, target | _] <- String.split(line, " "),
         true <- String.starts_with?(target, "http://") or String.starts_with?(target, "https://"),
         [host | _] <- String.split(strip_scheme(target), "/") do
      normalize_host(host)
    else
      _ -> nil
    end
  end

  defp strip_scheme(url) do
    url |> String.replace_prefix("http://", "") |> String.replace_prefix("https://", "")
  end

  defp index_host?(host) do
    host in @index_hosts or String.starts_with?(host, "127.")
  end

  # --- answering ---

  defp reply(sock, status, body) do
    reason = Map.get(@reasons, status, "OK")

    resp = [
      "HTTP/1.1 #{status} #{reason}\r\n",
      "content-type: text/html; charset=utf-8\r\n",
      "x-bl-gateway: #{@preferred_port}\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]

    _ = :gen_tcp.send(sock, resp)
    _ = :gen_tcp.close(sock)
    :ok
  end

  defp page(title, body) do
    """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>#{esc(title)}</title>
    <style>
      body { font: 14px ui-monospace, monospace; margin: 3rem auto; max-width: 46rem; color: #ddd; background: #111 }
      h1 { font-size: 1.1rem; font-weight: 600 }
      a { color: #7bd }
      table { border-collapse: collapse; width: 100% }
      td, th { text-align: left; padding: .3rem .6rem; border-bottom: 1px solid #333 }
      code { color: #9e9 }
    </style></head>
    <body><h1>#{esc(title)}</h1>
    #{body}
    </body></html>
    """
  end

  defp index_body do
    case routes() do
      [] ->
        """
        <p>No port has a name yet. A project registers one by declaring
        <code>:ports</code> in its <code>env.bl</code> and serving through
        <code>bl serve</code>.</p>
        """

      rs ->
        rows =
          Enum.map_join(rs, "\n", fn c ->
            host = List.first(c.hosts)

            "<tr><td><code>#{esc(to_string(c.name))}</code></td>" <>
              "<td><a href=\"http://#{esc(host)}/\">#{esc(host)}</a></td>" <>
              "<td><code>#{c.port}</code></td>" <>
              "<td>#{esc(Path.basename(c.root))}</td></tr>"
          end)

        "<table><thead><tr><th>name</th><th>address</th><th>port</th><th>tree</th></tr></thead>" <>
          "<tbody>#{rows}</tbody></table>"
    end
  end

  defp esc(s) do
    s
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
