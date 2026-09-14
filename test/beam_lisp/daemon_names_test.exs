defmodule BeamLisp.DaemonNamesTest do
  @moduledoc """
  The names a port answers to, and the one listener that routes them.

  Two halves. First `BeamLisp.Daemon.Names`: the derivation, which is a pure
  function of the tree (`env.bl`, the branch) and the port's name — so it is
  testable without a socket anywhere. Second `BeamLisp.Daemon.Gateway`: the
  routing, which reads the registry per request and splices bytes both ways.

  The gateway tests use a real backend and a real socket. A proxy that is only
  tested against itself proves nothing about the thing that matters — that the
  bytes on the other side are the bytes that were sent.
  """

  use ExUnit.Case, async: false

  alias BeamLisp.Daemon.{Gateway, Names, Paths, Ports}

  # Every claim in this file is made for one root. A claim is keyed by name AND
  # tree, so releasing with a different root removes nothing and leaves the
  # claim answering — a whole class of false test failures, closed by keeping
  # the root in one place. (The gateway test below caught it: a name that was
  # released still answered.)
  @claim_root "/tmp/names"

  # ── the derivation ────────────────────────────────────────────────────

  test "a project names its ports, and the bare name is the session's own" do
    root = tree(~s({:name "Pulse App"}))

    assert Names.base(root) == "pulse-app"

    assert Names.hosts(root, "web") == ["web.pulse-app.test", "web.pulse-app.localhost"]
    assert Names.hosts(root, :metrics) == ["metrics.pulse-app.test", "metrics.pulse-app.localhost"]

    # :ui is the session's own address, so it is the bare base — one answer to
    # "where is this session"
    assert Names.host(root, "ui") == "pulse-app.test"
    assert Names.host(root, :ui) == "pulse-app.test"
  end

  test "a tree with no env.bl is named by its directory" do
    root = tree(nil)

    assert Names.base(root) == Names.slug(Path.basename(root))
    assert Names.host(root, "web") == "web.#{Names.slug(Path.basename(root))}.test"
  end

  test "a declared instance qualifies every host" do
    root = tree(~s({:name "pulse" :instance "PR 42"}))

    assert Names.base(root) == "pulse-pr-42"
    assert Names.host(root, "web") == "web.pulse-pr-42.test"
    assert Names.host(root, "ui") == "pulse-pr-42.test"
  end

  test "two checkouts on different branches do not fight over one name" do
    if System.find_executable("git") do
      root = tree(~s({:name "pulse"}))

      if git(["-C", root, "init", "-q", "-b", "main"]) == 0 do
        # a branch only exists once there is a commit to be on it
        git(["-C", root, "-c", "user.email=t@t", "-c", "user.name=t",
             "commit", "-q", "--allow-empty", "-m", "init"])

        assert Names.base(root) == "pulse", "a default branch is not an instance"

        git(["-C", root, "checkout", "-q", "-b", "feat/websockets"])
        assert Names.base(root) == "pulse-feat-websockets"
      end
    else
      :ok
    end
  end

  test "a slug is a DNS label" do
    assert Names.slug("Feat/Web Sockets!") == "feat-web-sockets"
    assert Names.slug("  ..  ") == ""
    assert Names.slug("a.b") == "a-b"
    assert String.length(Names.slug(String.duplicate("x", 200))) == 63
    assert Names.slug("MiXeD") == "mixed"
  end

  test "the suffixes can be narrowed for a host that resolves only one" do
    root = tree(~s({:name "pulse"}))
    System.put_env("BL_NAMES_SUFFIXES", "localhost")
    on_exit(fn -> System.delete_env("BL_NAMES_SUFFIXES") end)

    assert Names.hosts(root, "web") == ["web.pulse.localhost"]
  end

  # ── the registry carries the names ────────────────────────────────────

  test "a claim carries its hosts, lowercased and deduped" do
    name = unique()
    {:ok, port} = Ports.claim(name, 0, root: @claim_root, hosts: ["Web.Pulse.Test", "web.pulse.test", "web.pulse.localhost"])
    on_exit(fn -> Ports.release(name, root: @claim_root) end)

    claim = Ports.holder(port)
    assert claim.hosts == ["web.pulse.test", "web.pulse.localhost"]

    assert Ports.holder_of_host("WEB.PULSE.TEST").port == port
    assert Ports.holder_of_host("web.pulse.localhost").port == port
    assert Ports.holder_of_host("other.test") == nil
  end

  test "a claim written before names existed still reads" do
    name = unique()
    {:ok, port} = Ports.claim(name, 0, root: "/tmp/old")
    {:ok, dir} = ports_dir()

    # The shape an older build wrote, in the file that build would have written
    # it to (a claim is keyed by name AND tree) — and no `:hosts` key at all.
    File.write!(Path.join(dir, "#{name}@#{Paths.tree_id("/tmp/old")}"), :erlang.term_to_binary(%{
      name: name,
      port: port,
      tree_id: "old",
      root: "/tmp/old",
      pid: :os.getpid() |> List.to_integer(),
      claimed_at: 0
    }))

    assert [claim] = Enum.filter(Ports.list(), fn c -> c.name == name end)
    assert claim.hosts == []
    refute Enum.any?(Gateway.routes(), fn c -> c.name == name end)

    Ports.release(name, root: "/tmp/old")
  end

  # ── the gateway ───────────────────────────────────────────────────────

  test "a name routes to the port that claimed it, and the bytes after the head ride along" do
    {name, backend_port} = claim_named("splice.test")
    {_lsock, _actual} = start_backend(backend_port, self())

    gw = start_gateway()

    sock = connect(Gateway.port())

    # The head AND a payload in one write: a WebSocket handshake that is
    # already followed by frames. The payload must arrive at the backend with
    # the head, not be swallowed by the read.
    :ok = :gen_tcp.send(sock, "GET /ws HTTP/1.1\r\nHost: splice.test\r\nUpgrade: websocket\r\n\r\nPING")

    assert_receive {:backend_first, first}, 3_000
    assert first =~ "Host: splice.test"
    assert String.ends_with?(first, "PING")

    assert recv_until(sock, "hello") =~ "200 OK"

    # both directions keep flowing after the head
    :ok = :gen_tcp.send(sock, "PONG")
    assert_receive {:backend_echo, "PONG"}, 3_000
    assert recv_until(sock, "PONG") =~ "PONG"

    :gen_tcp.close(sock)
    Ports.release(name, root: @claim_root)
    stop_gateway(gw)
  end

  test "the host is matched without its port, and in any case" do
    {name, backend_port} = claim_named("case.test")
    start_backend(backend_port, self())
    gw = start_gateway()
    sock = connect(Gateway.port())

    :ok = :gen_tcp.send(sock, "GET / HTTP/1.1\r\nHOST: CASE.TEST:80\r\n\r\n")
    assert recv_until(sock, "hello") =~ "200 OK"

    :gen_tcp.close(sock)
    Ports.release(name, root: @claim_root)
    stop_gateway(gw)
  end

  test "an unknown name is a 404 that lists what IS live" do
    {name, backend_port} = claim_named("listed.test")
    start_backend(backend_port, self())
    gw = start_gateway()

    sock = connect(Gateway.port())
    :ok = :gen_tcp.send(sock, "GET / HTTP/1.1\r\nHost: nope.test\r\n\r\n")
    body = recv_until(sock, "</html>")

    assert body =~ "404"
    assert body =~ "nothing answers to nope.test"
    assert body =~ "listed.test", "the page names what does answer"
    :gen_tcp.close(sock)

    # bare loopback is the gateway's own index, not an error
    sock2 = connect(Gateway.port())
    :ok = :gen_tcp.send(sock2, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    index = recv_until(sock2, "</html>")
    assert index =~ "200 OK"
    assert index =~ "listed.test"
    :gen_tcp.close(sock2)

    Ports.release(name, root: @claim_root)
    stop_gateway(gw)
  end

  test "routing reads the registry per request: a released claim stops answering at once" do
    {name, backend_port} = claim_named("live.test")
    start_backend(backend_port, self())
    gw = start_gateway()

    sock = connect(Gateway.port())
    :ok = :gen_tcp.send(sock, "GET / HTTP/1.1\r\nHost: live.test\r\n\r\n")
    assert recv_until(sock, "hello") =~ "200 OK"
    :gen_tcp.close(sock)

    Ports.release(name, root: @claim_root)

    sock2 = connect(Gateway.port())
    :ok = :gen_tcp.send(sock2, "GET / HTTP/1.1\r\nHost: live.test\r\n\r\n")
    assert recv_until(sock2, "</html>") =~ "404"
    :gen_tcp.close(sock2)

    stop_gateway(gw)
  end

  test "a request with no Host is refused, and a claimed-but-dead port is a 502" do
    {name, backend_port} = claim_named("dead.test")
    gw = start_gateway()

    sock = connect(Gateway.port())
    :ok = :gen_tcp.send(sock, "GET / HTTP/1.0\r\n\r\n")
    assert recv_until(sock, "</html>") =~ "400"
    :gen_tcp.close(sock)

    # nothing is listening on the claimed port: reported, never silently
    # redirected somewhere else
    sock2 = connect(Gateway.port())
    :ok = :gen_tcp.send(sock2, "GET / HTTP/1.1\r\nHost: dead.test\r\n\r\n")
    body = recv_until(sock2, "</html>")
    assert body =~ "502"
    assert body =~ "dead.test"
    assert body =~ to_string(backend_port)
    :gen_tcp.close(sock2)

    Ports.release(name, root: @claim_root)
    stop_gateway(gw)
  end

  test "an address carries the port only when it has to" do
    # The pure rule: three facts decide what a developer types. On 80 — the one
    # HTTP port a URL may leave out — the name stands alone; anywhere else the
    # port is printed, because an address that omits the port nothing is
    # listening on looks clickable and answers `connection refused`.
    assert Gateway.url("web.pulse.test", 80, false) == "http://web.pulse.test/"
    assert Gateway.url("web.pulse.test", 7777, false) == "http://web.pulse.test:7777/"

    # …and when port 80 IS answered — by this gateway, or by a loopback
    # redirect in front of it — the port drops out although the socket is
    # elsewhere. That is the whole point of `bl install redirect`.
    assert Gateway.url("web.pulse.test", 7777, true) == "http://web.pulse.test/"
    assert Gateway.url("web.pulse.test", nil, true) == "http://web.pulse.test/"

    # `url/1,2` answer that live question (a probe of port 80). What they
    # answer is asserted in the probe test below, against real sockets — a
    # fixture cannot stand in for evidence, and re-asking the machine here would
    # only make this test depend on whatever it is running.
    assert Gateway.url("web.pulse.test", nil, false) == "http://web.pulse.test/"
  end

  test "the port-80 probe answers for a gateway, and only for a gateway" do
    # `fronted_on?/1` asks a question about EVIDENCE, so the test answers it
    # with real sockets: a server that identifies itself the way the gateway
    # does, one that does not, and a port where nothing is listening at all.
    ours =
      start_socket_server(fn ->
        "HTTP/1.1 404 Not Found\r\nx-bl-gateway: beam-lisp\r\ncontent-length: 0\r\n\r\n"
      end)

    assert Gateway.ours_on?(ours)

    theirs =
      start_socket_server(fn ->
        "HTTP/1.1 200 OK\r\nserver: nginx\r\ncontent-length: 0\r\n\r\n"
      end)

    refute Gateway.ours_on?(theirs)
    refute Gateway.ours_on?(free_port()), "a refused connection is not us"

    # the classifier behind the probe
    assert Gateway.gateway_answer?("HTTP/1.1 200 OK\r\nX-BL-Gateway: beam-lisp\r\n\r\n")
    refute Gateway.gateway_answer?("HTTP/1.1 200 OK\r\nx-powered-by: beam-lisp\r\n\r\n")
    refute Gateway.gateway_answer?("")
    refute Gateway.gateway_answer?(nil)

    # port 80 itself is a fact, not a probe: holding it IS being answered there
    assert Gateway.fronted_on?(80)
    refute Gateway.fronted_on?(nil)
  end

  test "an ephemeral gateway answers in-VM but publishes no endpoint" do
    # The endpoint file is the machine's ONE answer to "where is the gateway",
    # and only a gateway that CHOSE its port may own it. An ephemeral one
    # (tests, a deliberately moved-aside gateway) must not take it over — nor
    # delete it on exit, which is how a real gateway became undiscoverable
    # while it kept serving names.
    # The invariant, stated so it cannot be confounded by whatever gateway the
    # machine already runs: starting an EPHEMERAL gateway neither creates the
    # endpoint nor takes one over — it answers in-VM only.
    before = Gateway.endpoint()

    gw = start_gateway()
    port = GenServer.call(gw, :port)
    assert is_integer(port)
    assert Gateway.port() == port
    assert Gateway.endpoint() == before, "an ephemeral gateway must not publish the endpoint"

    stop_gateway(gw)

    # Stopping THIS VM's gateway does not stop the machine's: a `bl` command
    # that started none still finds the one that is running (that is the whole
    # point of the endpoint file). So the assertion is that OUR port is gone
    # from the answer, not that there is no answer.
    assert Gateway.port() != port

    # its listener went with it: the port can be bound again
    {:ok, sock} = :gen_tcp.listen(port, [{:ip, {127, 0, 0, 1}}, :binary])
    :gen_tcp.close(sock)
  end

  # ── helpers ──
  defp git(args) do
    {_, code} = System.cmd("git", args, stderr_to_stdout: true)
    code
  end


  # Names must be unique across VMs, not just within one: the port registry and
  # the TLDs it serves are per USER, so a second checkout running its tests at
  # the same moment draws from the same `unique_integer` sequence and lands on
  # the same name. The OS pid separates the VMs; the integer separates the
  # tests inside one.
  defp unique, do: "t_names_#{:os.getpid()}_#{:erlang.unique_integer([:positive])}"

  # A claim on an EPHEMERAL port, then a backend bound exactly where the claim
  # points. That is the real order: an app asks for a named port and binds what
  # it was given, so the registry never has to take a port away from anyone.
  defp claim_named(host) do
    name = unique()
    {:ok, port} = Ports.claim(name, 0, root: @claim_root, hosts: [host])
    on_exit(fn -> Ports.release(name, root: @claim_root) end)
    {name, port}
  end

  defp start_backend(port, test) do
    opts = [:binary, {:packet, :raw}, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}]
    {:ok, lsock} = :gen_tcp.listen(port, opts)
    spawn_link(fn -> accept_loop(lsock, test) end)
    {lsock, port}
  end

  defp accept_loop(lsock, test) do
    case :gen_tcp.accept(lsock, 10_000) do
      {:ok, sock} ->
        serve_one(sock, test)
        accept_loop(lsock, test)

      _ ->
        :ok
    end
  end

  defp serve_one(sock, test) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, first} ->
        send(test, {:backend_first, first})

        :gen_tcp.send(
          sock,
          "HTTP/1.1 200 OK\r\ncontent-length: 5\r\nconnection: keep-alive\r\n\r\nhello"
        )

        echo(sock, test)

      _ ->
        :ok
    end

    :gen_tcp.close(sock)
  end

  defp echo(sock, test) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} ->
        send(test, {:backend_echo, data})
        :gen_tcp.send(sock, data)
        echo(sock, test)

      _ ->
        :ok
    end
  end

  defp start_gateway do
    case Process.whereis(Gateway) do
      nil -> :ok
      old -> stop_gateway(old)
    end

    {:ok, pid} = Gateway.start_link(port: 0)
    on_exit(fn -> stop_gateway(pid) end)
    pid
  end

  defp stop_gateway(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 2_000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp stop_gateway(_), do: :ok

  defp connect(port) do
    {:ok, sock} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:packet, :raw}, {:active, false}], 2_000)

    sock
  end

  defp recv_until(sock, needle, acc \\ "")

  defp recv_until(_sock, _needle, acc) when byte_size(acc) > 200_000, do: acc

  defp recv_until(sock, needle, acc) do
    if String.contains?(acc, needle) do
      acc
    else
      case :gen_tcp.recv(sock, 0, 5_000) do
        {:ok, data} -> recv_until(sock, needle, acc <> data)
        {:error, _} -> acc
      end
    end
  end

  # A one-shot server that answers with whatever `body` returns, on an
  # ephemeral port. The probe reads a response HEAD, so a test can be the thing
  # on the other end — the only way to test a question about evidence.
  defp start_socket_server(body) do
    opts = [:binary, {:packet, :raw}, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}]
    {:ok, lsock} = :gen_tcp.listen(0, opts)
    {:ok, {_ip, port}} = :inet.sockname(lsock)

    spawn_link(fn ->
      case :gen_tcp.accept(lsock, 5_000) do
        {:ok, sock} ->
          {:ok, _request} = :gen_tcp.recv(sock, 0, 5_000)
          :gen_tcp.send(sock, body.())
          :gen_tcp.close(sock)

        _ ->
          :ok
      end
    end)

    port
  end

  # A port nothing is listening on: bound, then released. The probe must answer
  # `false` on the refusal, not raise and not hang.
  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [{:ip, {127, 0, 0, 1}}, :binary])
    {:ok, {_ip, port}} = :inet.sockname(sock)
    :gen_tcp.close(sock)
    port
  end

  defp ports_dir do
    with {:ok, base} <- Paths.runtime_dir(), do: {:ok, Path.join(base, "ports")}
  end

  # A throwaway tree. Under the system temp dir on purpose: a fixture inside
  # the repository would inherit the repository's git branch, and the name
  # would depend on what the developer happens to be working on.
  defp tree(env) do
    root = Path.join(System.tmp_dir!(), "bl_names_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    if env, do: File.write!(Path.join(root, "env.bl"), env)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
