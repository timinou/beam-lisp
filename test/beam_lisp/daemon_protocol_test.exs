defmodule BeamLisp.DaemonProtocolTest do
  use ExUnit.Case, async: false

  alias BeamLisp.Daemon.{Protocol, Paths, Server}

  # ── Protocol: encode/decode/validate ──────────────────────────────────

  describe "protocol validation" do
    test "a well-formed hello round-trips through decode" do
      tree = :crypto.strong_rand_bytes(32)
      token = :crypto.strong_rand_bytes(32)
      frame = Protocol.encode({:bl, 1, :hello, %{tree: tree, token: token, compiler_key: "ab", daemon_build_id: "1"}})

      assert {:ok, {:hello, %{tree: ^tree, token: ^token, compiler_key: "ab"}}} = Protocol.decode(frame)
    end

    test "hello with a wrong-sized tree is rejected" do
      frame = Protocol.encode({:bl, 1, :hello, %{tree: <<1, 2, 3>>, token: :crypto.strong_rand_bytes(32)}})
      assert {:error, _} = Protocol.decode(frame)
    end

    test "a request frame validates argv/cwd and defaults env_paths" do
      id = :crypto.strong_rand_bytes(16)
      frame = Protocol.encode({:bl, 1, :request, id, %{argv: ["eval", "(+ 1 2)"], cwd: "/tmp"}})
      assert {:ok, {:request, ^id, %{argv: ["eval", "(+ 1 2)"], cwd: "/tmp", env_paths: []}}} = Protocol.decode(frame)
    end

    test "a request with non-binary argv is rejected" do
      id = :crypto.strong_rand_bytes(16)
      frame = Protocol.encode({:bl, 1, :request, id, %{argv: [:eval], cwd: "/tmp"}})
      assert {:error, :malformed} = Protocol.decode(frame)
    end

    test "an argv over the length cap is rejected" do
      id = :crypto.strong_rand_bytes(16)
      argv = for _ <- 1..5000, do: "x"
      frame = Protocol.encode({:bl, 1, :request, id, %{argv: argv, cwd: "/tmp"}})
      assert {:error, :argv_too_long} = Protocol.decode(frame)
    end

    test "a control :status frame validates" do
      id = :crypto.strong_rand_bytes(16)
      frame = Protocol.encode({:bl, 1, :control, id, :status})
      assert {:ok, {:control, ^id, :status}} = Protocol.decode(frame)
    end

    test "an unknown-shape frame is rejected, not executed" do
      assert {:error, :unknown_frame} = Protocol.decode(Protocol.encode({:bl, 1, :nonsense, 42}))
    end

    test "a wrong-version frame is rejected" do
      frame = Protocol.encode({:bl, 2, :hello, %{tree: :crypto.strong_rand_bytes(32), token: :crypto.strong_rand_bytes(32)}})
      assert {:error, :unknown_frame} = Protocol.decode(frame)
    end

    test "an oversized frame is rejected before decoding" do
      big = :binary.copy(<<0>>, Protocol.max_frame() + 1)
      assert {:error, :frame_too_large} = Protocol.decode(big)
    end

    test "non-ETF bytes decode as malformed, never crash" do
      assert {:error, :malformed} = Protocol.decode(<<255, 254, 253, 0, 1, 2>>)
    end

    test "a [:safe]-unsafe term (never-seen atom) decodes as malformed, not a crash" do
      # ATOM_UTF8_EXT (tag 118) for an atom this VM has never interned. A plain
      # binary_to_term would create it; [:safe] refuses — the daemon must catch
      # that and report :malformed, never raise.
      name = "bl_daemon_zzq_never_seen_atom_00"
      bogus = <<131, 118, byte_size(name)::16>> <> name
      assert {:error, _} = Protocol.decode(bogus)
    end
  end

  # ── Paths: tree identity + endpoint security ──────────────────────────

  describe "paths" do
    test "tree_id is stable and 16 hex chars" do
      root = File.cwd!()
      id = Paths.tree_id(root)
      assert String.match?(id, ~r/^[0-9a-f]{16}$/)
      assert id == Paths.tree_id(root)
    end

    test "different roots get different tree ids" do
      refute Paths.tree_id("/tmp/a") == Paths.tree_id("/tmp/b")
    end

    test "endpoints returns a full 0700 runtime dir + socket under the length cap" do
      assert {:ok, ep} = Paths.endpoints(File.cwd!())
      assert byte_size(ep.sock) <= 100
      assert String.ends_with?(ep.sock, ".sock")
      assert String.ends_with?(ep.token, ".token")
      dir = Path.dirname(ep.sock)
      assert File.dir?(dir)
      {:ok, info} = :file.read_file_info(String.to_charlist(dir))
      mode = elem(info, 7)
      import Bitwise
      assert (mode &&& 0o077) == 0
    end

    test "resolve_root finds the checkout from a nested cwd" do
      nested = Path.join(File.cwd!(), "priv/std/bl")
      assert {:ok, root} = Paths.resolve_root(nested)
      assert File.exists?(Path.join([root, "priv", "boot", "core.bl"]))
    end
  end

  # ── Integration: in-VM server, real socket handshake ──────────────────

  describe "in-vm daemon over the socket" do
    setup do
      # A throwaway root so this test's daemon never collides with a real one.
      root = Path.join(System.tmp_dir!(), "bl-daemon-test-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([root, "priv", "boot"]))
      File.write!(Path.join([root, "priv", "boot", "core.bl"]), "(ns core)\n")

      {:ok, pid} = Server.start_link(root: root, boot: false, idle_seconds: 0)
      {:ok, ep} = Paths.endpoints(root)
      # token is written by the server on init
      wait_for(fn -> File.exists?(ep.token) end)
      token = File.read!(ep.token)

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{root: root, ep: ep, token: token, tree: Paths.tree_fingerprint(root)}
    end

    test "hello with the right token gets :ready", %{ep: ep, token: token, tree: tree} do
      {:ok, sock} = connect(ep.sock)
      send_frame(sock, Protocol.encode({:bl, 1, :hello, %{tree: tree, token: token}}))
      assert {:ok, {:bl, 1, :ready, meta}} = recv_frame(sock)
      assert is_map(meta)
      :gen_tcp.close(sock)
    end

    test "hello with a bad token is rejected :unauthorized", %{ep: ep, tree: tree} do
      {:ok, sock} = connect(ep.sock)
      send_frame(sock, Protocol.encode({:bl, 1, :hello, %{tree: tree, token: :crypto.strong_rand_bytes(32)}}))
      assert {:ok, {:bl, 1, :reject, :unauthorized, _, _}} = recv_frame(sock)
      :gen_tcp.close(sock)
    end

    test "hello with a wrong tree is rejected :wrong_tree", %{ep: ep, token: token} do
      {:ok, sock} = connect(ep.sock)
      send_frame(sock, Protocol.encode({:bl, 1, :hello, %{tree: :crypto.strong_rand_bytes(32), token: token}}))
      assert {:ok, {:bl, 1, :reject, :wrong_tree, _, _}} = recv_frame(sock)
      :gen_tcp.close(sock)
    end

    test "control :status after ready streams a status body + exit 0", %{ep: ep, token: token, tree: tree} do
      {:ok, sock} = connect(ep.sock)
      send_frame(sock, Protocol.encode({:bl, 1, :hello, %{tree: tree, token: token}}))
      assert {:ok, {:bl, 1, :ready, _}} = recv_frame(sock)
      id = :crypto.strong_rand_bytes(16)
      send_frame(sock, Protocol.encode({:bl, 1, :control, id, :status}))
      assert {:ok, {:bl, 1, :stdout, ^id, 0, body}} = recv_frame(sock)
      assert body =~ "bl daemon"
      assert {:ok, {:bl, 1, :exit, ^id, 0}} = recv_frame(sock)
      :gen_tcp.close(sock)
    end

    test "terminate removes the socket and token", %{ep: ep} do
      assert File.exists?(ep.sock)
      GenServer.stop(Server, :normal)
      wait_for(fn -> not File.exists?(ep.sock) end)
      refute File.exists?(ep.sock)
      refute File.exists?(ep.token)
    end
  end

  # ── helpers ──

  defp connect(sock_path) do
    :gen_tcp.connect({:local, String.to_charlist(sock_path)}, 0, [
      {:inet_backend, :inet},
      :local,
      :binary,
      {:packet, 4},
      {:active, false}
    ])
  end

  defp send_frame(sock, bin), do: :ok = :gen_tcp.send(sock, bin)

  defp recv_frame(sock) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, bin} -> {:ok, :erlang.binary_to_term(bin)}
      other -> other
    end
  end

  defp wait_for(fun, tries \\ 100)
  defp wait_for(_fun, 0), do: :timeout
  defp wait_for(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_for(fun, tries - 1)
    end
  end
end
