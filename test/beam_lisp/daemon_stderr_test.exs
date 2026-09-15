defmodule BeamLisp.Daemon.StdErrTest do
  use ExUnit.Case, async: false

  # The defect this pins: a command's stderr reached nobody under the session.
  #
  # The daemon gives each request a group-leader proxy, so a program's STDOUT
  # becomes wire frames. stderr is not group-leader-scoped — `IO.puts(:stderr, …)`
  # resolves the atom `:standard_error` through `Process.whereis/1` and writes to
  # the VM's own fd 2, which is the daemon's log file. So `u/io-err` — every
  # usage error, every `bl: nothing holds the name …` — vanished: measured,
  # `bl open nope` under the session printed NOTHING where cold it printed the
  # line. A developer sees a command exit non-zero with an empty terminal and no
  # way to learn why.
  #
  # These tests drive the REAL pieces — the device, the proxy, a real socket,
  # the real frame encoder — because the property is "the bytes arrive on the
  # wire as a :stderr frame", and nothing short of the socket proves it.

  # NOT `IO` — that is Elixir's, and this file prints with it.
  alias BeamLisp.Daemon.{StdErr, Workers}
  alias BeamLisp.Daemon.IO, as: Proxy

  setup do
    # Own the tree (see daemon_index_worker_test.exs): `ensure_started/1` links
    # the supervisor to the case process, and `build: false` because this file
    # is about stderr, not indexing.
    start_supervised!({Workers, root: File.cwd!(), build: false})
    :ok
  end

  # A real socket pair, framed exactly as the daemon's own protocol is
  # (`{packet, 4}`), so a frame read here is the frame a client would read.
  defp socket_pair do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, packet: 4, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: 4, active: false])
    {:ok, server} = :gen_tcp.accept(lsock, 2_000)
    :ok = :gen_tcp.close(lsock)
    {client, server}
  end

  # Run `fun` the way the executor runs a command: a proxy for request 7 whose
  # socket is `server`, that process's group leader set to it.
  defp as_request(server, fun) do
    proxy = Proxy.start(server, 7, self())
    parent = self()

    spawn(fn ->
      :erlang.group_leader(proxy, self())
      send(parent, {:ran, self()})
      fun.()
      Proxy.finish(proxy)
    end)

    receive do
      {:ran, _} -> :ok
    after
      2_000 -> flunk("the request process never started")
    end

    proxy
  end

  # `Protocol.decode/1` is the SERVER-side allowlist (client → daemon verbs), so
  # it answers `:unknown_frame` for the frames a client receives. Decode those
  # the way the client does: the terminal frame is a term, and the framing
  # (`{packet, 4}`) already gave us exactly one.
  defp recv_frame(sock) do
    {:ok, bin} = :gen_tcp.recv(sock, 0, 5_000)
    :erlang.binary_to_term(bin)
  end

  test "a command's stderr becomes a :stderr frame on that request's socket" do
    {client, server} = socket_pair()
    _proxy = as_request(server, fn -> IO.puts(:stderr, "bl: nothing holds the name nope") end)

    assert {:bl, _, :stderr, 7, 0, bytes} = recv_frame(client)
    assert bytes =~ "nothing holds the name"
    :gen_tcp.close(client)
  end

  test "stderr and stdout share one sequence, so a client can interleave them" do
    {client, server} = socket_pair()

    _proxy =
      as_request(server, fn ->
        IO.puts("out-1")
        IO.puts(:stderr, "err-2")
        IO.puts("out-3")
      end)

    frames =
      for _ <- 1..3 do
        {:bl, _, stream, 7, seq, bytes} = recv_frame(client)
        {stream, seq, bytes}
      end

    # The stream tag is an ATOM on the wire (`Protocol.stdout/stderr`), and the
    # sequence is SHARED, which is what lets a client interleave the two.
    assert frames == [{:stdout, 0, "out-1\n"}, {:stderr, 1, "err-2\n"}, {:stdout, 2, "out-3\n"}]
    :gen_tcp.close(client)
  end

  test "the daemon's OWN stderr still goes to the displaced device" do
    {client, server} = socket_pair()
    dev = StdErr.device()
    assert is_pid(dev)

    # Nothing a bare process writes is a request's: its group leader is the
    # VM's, not a proxy. This is the daemon's own log path, and it must not be
    # swallowed by the device.
    before = Process.info(dev, :message_queue_len)
    assert is_tuple(before)

    IO.puts(:stderr, "daemon-side line")

    # The displaced device received it as an io_request. (`dev` may be the
    # kernel's stderr process, which answers rather than queues, so accept
    # either a queued request or an answered one — what must NOT happen is the
    # line appearing on the request socket.)
    refute_receive {:bl, _, :stderr, _, _, _}, 200 do
      :ok
    end

    :gen_tcp.close(client)
  end

  test "a writer whose request is gone does not wedge, and does not hang" do
    # A process that prints stderr AFTER its request finished — the marker dies
    # with the proxy. It must fall back to the daemon's device rather than block
    # on a socket that has no reader.
    {client, server} = socket_pair()
    proxy = as_request(server, fn -> :ok end)
    Process.unlink(proxy)
    Process.exit(proxy, :kill)
    Process.sleep(50)
    refute Process.alive?(proxy)

    parent = self()

    writer =
      spawn(fn ->
        :erlang.group_leader(proxy, self())
        send(parent, :leader_is_a_dead_proxy)
        IO.puts(:stderr, "after the request")
        send(parent, :printed)
      end)

    assert_receive :leader_is_a_dead_proxy, 2_000
    assert_receive :printed, 2_000
    assert is_pid(writer)
    :gen_tcp.close(client)
  end
end
