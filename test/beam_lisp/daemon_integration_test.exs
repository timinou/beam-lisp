defmodule BeamLisp.DaemonIntegrationTest do
  use ExUnit.Case, async: false

  alias BeamLisp.Daemon.{Protocol, Paths, Server}

  setup do
    root = File.cwd!()
    # a prior test's named server may still be terminating; ensure a clean slate
    case Process.whereis(Server) do
      nil -> :ok
      old ->
        try do
          GenServer.stop(old, :normal, 2_000)
        catch
          :exit, _ -> :ok
        end
    end

    {:ok, pid} = Server.start_link(root: root, boot: true, idle_seconds: 0)
    {:ok, ep} = Paths.endpoints(root)
    wait_for(fn -> File.exists?(ep.token) end)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 2_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{root: root, ep: ep, token: File.read!(ep.token), tree: Paths.tree_fingerprint(root)}
  end

  test "probe finds the running daemon and returns ready meta", %{root: root} do
    assert {:ok, meta} = BeamLisp.Daemon.probe(root)
    assert is_map(meta)
    assert Map.has_key?(meta, :compiler_key)
  end

  test "status connects and reports a live daemon", %{root: root} do
    assert 0 = BeamLisp.Daemon.status(root)
  end

  test "a drifted daemon rejects hello with restart_required", %{ep: ep, tree: tree, root: root} do
    # A daemon that BOOTED with a key different from the live on-disk key is
    # stale: its self-drift check must refuse new work with restart_required.
    # Stop the real (non-drifted) server, boot one with a bogus startup key.
    GenServer.stop(Server, :normal)
    wait_for(fn -> not File.exists?(ep.sock) end)

    {:ok, pid} =
      Server.start_link(root: root, boot: false, idle_seconds: 0, compiler_key: "deadbeef-stale-key")

    wait_for(fn -> File.exists?(ep.token) end)
    token2 = File.read!(ep.token)

    {:ok, sock} = connect(ep.sock)
    send_frame(sock, Protocol.encode({:bl, 1, :hello, %{tree: tree, token: token2}}))
    assert {:ok, {:bl, 1, :reject, :restart_required, _, _}} = recv_frame(sock)
    :gen_tcp.close(sock)

    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 2_000)
      catch
        :exit, _ -> :ok
      end
    end

    wait_for(fn -> not File.exists?(ep.sock) end)
  end

  test "a z3-backed run executes INSIDE the daemon (native tier the escript lacks)", ctx do
    # z3 is a spawned port; this proves the daemon's release VM serves the
    # native tier the escript archive cannot carry. A file with an ns :require
    # is the honest entry (require is a top-level form, not an eval expression).
    dir = Path.join(System.tmp_dir!(), "blz3-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    prog =
      "(ns z3prog (:require [z3] [smt :as s]))\n" <>
      "(def p (z3/open))\n" <>
      "(println (z3/check p [(s/declare-const 'x 'Int) (s/assert '(> x 5)) (s/assert '(< x 7))]))\n"

    File.write!(Path.join(dir, "z3prog.bl"), prog)

    {out, code} = request(ctx, ["run", "z3prog.bl"], dir)
    assert code == 0
    assert out =~ "sat"
    File.rm_rf!(dir)
  end

  test "stop drains and removes the socket", %{root: root, ep: ep} do
    assert File.exists?(ep.sock)
    assert 0 = BeamLisp.Daemon.stop(root)
    wait_for(fn -> not File.exists?(ep.sock) end)
    refute File.exists?(ep.sock)
  end

  # ── helpers ──

  defp request(ctx, argv, cwd \\ nil) do
    cwd = cwd || ctx.root
    {:ok, sock} = connect(ctx.ep.sock)
    send_frame(sock, Protocol.encode({:bl, 1, :hello, %{tree: ctx.tree, token: ctx.token}}))
    {:ok, {:bl, 1, :ready, _}} = recv_frame(sock)
    id = :crypto.strong_rand_bytes(16)
    send_frame(sock, Protocol.encode({:bl, 1, :request, id, %{argv: argv, cwd: cwd, env_paths: []}}))
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
      {:inet_backend, :inet},
      :local,
      :binary,
      {:packet, 4},
      {:active, false}
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

  defp wait_for(fun, tries) do
    if fun.(), do: :ok, else: (Process.sleep(20); wait_for(fun, tries - 1))
  end
end
