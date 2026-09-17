defmodule BeamLisp.DaemonVmCutoverTest do
  @moduledoc """
  PLAN-121 cutover: the daemon's command path runs through the pure-beam-lisp
  global VM manager (vm.manager), one BEAM process per request, NOT a single
  serial worker. These tests drive the REAL AF_UNIX socket end-to-end
  (hello → request → frames), so they exercise server.ex `vm_execute` →
  `bl.daemon/handle-in-vm` → the manager, exactly as a client does.

  They enshrine the two guarantees the cutover is FOR:
    G1 CONCURRENCY — a slow request does not delay a concurrent one (no FIFO).
    G5 PROCESS-LOCAL ENV — a request's env is read process-locally; two
       concurrent requests with different env do not race on a node-global table.
  """
  use ExUnit.Case, async: false

  alias BeamLisp.Daemon.{Protocol, Paths, Server}

  setup do
    root = File.cwd!()

    case Process.whereis(Server) do
      nil -> :ok
      old -> (try do GenServer.stop(old, :normal, 2_000) catch :exit, _ -> :ok end)
    end

    {:ok, pid} = Server.start_link(root: root, boot: true, idle_seconds: 0)
    {:ok, ep} = Paths.endpoints(root)
    wait_for(fn -> File.exists?(ep.token) end)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do GenServer.stop(pid, :normal, 2_000) catch :exit, _ -> :ok end
      end
    end)

    %{root: root, ep: ep, token: File.read!(ep.token), tree: Paths.tree_fingerprint(root)}
  end

  test "a command round-trips through the VM manager and returns its output", ctx do
    {out, code} = request(ctx, ["eval", "(+ 40 2)"])
    assert code == 0
    assert out =~ "42"
  end

  test "G5: a request's env is readable PROCESS-LOCALLY via the osenv overlay", ctx do
    {out, code} = request(ctx, ["eval", ~s[(vm.osenv/get "BL_CUTOVER_KEY")]], ctx.root, %{"BL_CUTOVER_KEY" => "from-request"})
    assert code == 0
    assert out =~ "from-request"
  end

  test "G5: two concurrent requests with different env do NOT race", ctx do
    parent = self()

    spawn(fn ->
      send(parent, {:a, request(ctx, ["eval", ~s[(vm.osenv/get "BL_RACE")]], ctx.root, %{"BL_RACE" => "alpha"})})
    end)

    spawn(fn ->
      send(parent, {:b, request(ctx, ["eval", ~s[(vm.osenv/get "BL_RACE")]], ctx.root, %{"BL_RACE" => "beta"})})
    end)

    a = receive do {:a, r} -> r after 20_000 -> flunk("a timed out") end
    b = receive do {:b, r} -> r after 20_000 -> flunk("b timed out") end

    assert elem(a, 0) =~ "alpha"
    assert elem(b, 0) =~ "beta"
  end

  test "G1: a slow request does not delay a concurrent fast one (no serial worker)", ctx do
    parent = self()

    # a ~2s request in flight
    spawn(fn ->
      send(parent, {:slow, request(ctx, ["eval", "(do (erlang/apply :timer :sleep (list 2000)) (println :slow))"])})
    end)

    Process.sleep(200)

    # the fast request must complete well before the slow one's 2s — under a
    # single serial worker it would have queued behind it (>2000ms).
    t0 = System.monotonic_time(:millisecond)
    {fout, fcode} = request(ctx, ["eval", "(println :fast)"])
    dt = System.monotonic_time(:millisecond) - t0

    assert fcode == 0
    assert fout =~ "fast"
    assert dt < 1500, "fast request took #{dt}ms — a serial worker would force >2000ms"

    receive do {:slow, {sout, 0}} -> assert sout =~ "slow" after 6000 -> flunk("slow timed out") end
  end

  # ── helpers (mirror daemon_integration_test.exs) ──

  defp request(ctx, argv, cwd \\ nil, env \\ %{}) do
    cwd = cwd || ctx.root
    {:ok, sock} = connect(ctx.ep.sock)
    send_frame(sock, Protocol.encode({:bl, 1, :hello, %{tree: ctx.tree, token: ctx.token}}))
    {:ok, {:bl, 1, :ready, _}} = recv_frame(sock)
    id = :crypto.strong_rand_bytes(16)
    send_frame(sock, Protocol.encode({:bl, 1, :request, id, %{argv: argv, cwd: cwd, env_paths: [], env: env}}))
    r = collect(sock, id, "")
    :gen_tcp.close(sock)
    r
  end

  defp collect(sock, id, acc) do
    case recv_frame(sock) do
      {:ok, {:bl, 1, :stdout, ^id, _s, b}} -> collect(sock, id, acc <> b)
      {:ok, {:bl, 1, :stderr, ^id, _s, b}} -> collect(sock, id, acc <> b)
      {:ok, {:bl, 1, :exit, ^id, code}} -> {acc, code}
      {:ok, _} -> collect(sock, id, acc)
      {:error, _} -> {acc, :closed}
    end
  end

  defp connect(sock_path) do
    :gen_tcp.connect({:local, String.to_charlist(sock_path)}, 0, [
      {:inet_backend, :inet}, :local, :binary, {:packet, 4}, {:active, false}
    ])
  end

  defp send_frame(sock, bin), do: :gen_tcp.send(sock, bin)

  defp recv_frame(sock) do
    case :gen_tcp.recv(sock, 0, 20_000) do
      {:ok, bin} -> {:ok, :erlang.binary_to_term(bin)}
      other -> other
    end
  end

  defp wait_for(fun, tries \\ 150)
  defp wait_for(_fun, 0), do: :timeout
  defp wait_for(fun, tries), do: if(fun.(), do: :ok, else: (Process.sleep(20); wait_for(fun, tries - 1)))
end
