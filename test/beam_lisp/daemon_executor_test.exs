defmodule BeamLisp.DaemonExecutorTest do
  use ExUnit.Case, async: false

  alias BeamLisp.Daemon.{Protocol, Paths, Server}

  setup do
    root = File.cwd!()
    {:ok, pid} = Server.start_link(root: root, boot: true, idle_seconds: 0)
    {:ok, ep} = Paths.endpoints(root)
    wait_for(fn -> File.exists?(ep.token) end)
    token = File.read!(ep.token)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 2_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{ep: ep, token: token, tree: Paths.tree_fingerprint(root), root: root}
  end

  describe "command execution over the daemon" do
    test "eval round-trips: stdout value + exit 0", ctx do
      {out, code} = request(ctx, ["eval", "(+ 1 2)"])
      assert code == 0
      assert out =~ "3"
    end

    test "a failed eval returns exit 1, and the daemon still serves the next", ctx do
      {_out, code1} = request(ctx, ["eval", "(throw :boom)"])
      assert code1 == 1
      # daemon must not have died — a fresh command succeeds
      {out2, code2} = request(ctx, ["eval", "(* 6 7)"])
      assert code2 == 0
      assert out2 =~ "42"
    end

    test "run resolves FILE against the CLIENT cwd, not the daemon's", ctx do
      dir = Path.join(System.tmp_dir!(), "bl-exec-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "prog.bl"), "(ns prog)\n(println \"from\" 99)\n")

      # cwd = the tmp dir; file arg is RELATIVE
      {out, code} = request(ctx, ["run", "prog.bl"], dir)
      assert code == 0
      assert out =~ "from 99"
      File.rm_rf!(dir)
    end

    test "a run resolves a library through the client's -p (env_paths)", ctx do
      lib = Path.join(System.tmp_dir!(), "bllib-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(lib)
      File.write!(Path.join(lib, "liba.bl"), "(ns liba)\n(defn who [] :alpha)\n")

      prog = Path.join(System.tmp_dir!(), "blprog-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(prog)
      File.write!(Path.join(prog, "main.bl"), "(ns main (:require [liba]))\n(println (liba/who))\n")

      # the client passes its -p root as env_paths; the daemon must resolve the
      # library against THAT, not its own cwd.
      {out, code} = request(ctx, ["run", "main.bl"], prog, [lib])
      assert code == 0
      assert out =~ "alpha"

      File.rm_rf!(lib)
      File.rm_rf!(prog)
    end

    test "a run sees its post-`--` args via BeamLisp/argv", ctx do
      dir = Path.join(System.tmp_dir!(), "blargv-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "args.bl"), "(ns args)\n(println (join \",\" (BeamLisp/argv)))\n")

      {out, code} = request(ctx, ["run", "args.bl", "--", "one", "two", "three"], dir)
      assert code == 0
      assert out =~ "one,two,three"
      File.rm_rf!(dir)
    end

    test "a bl test suite runs non-halting and maps pass to 0", ctx do
      dir = Path.join(System.tmp_dir!(), "bltest-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "ok_test.bl"), "(ns ok-test)\n(deftest passes (is (= 1 1)))\n")

      {_out, code} = request(ctx, ["test", "ok_test.bl"], dir)
      assert code == 0

      # a failing suite maps to 1 WITHOUT halting the daemon
      File.write!(Path.join(dir, "bad_test.bl"), "(ns bad-test)\n(deftest fails (is (= 1 2)))\n")
      {_o2, code2} = request(ctx, ["test", "bad_test.bl"], dir)
      assert code2 == 1
      # daemon survived: a fresh eval still works
      {o3, code3} = request(ctx, ["eval", "(+ 2 2)"])
      assert code3 == 0
      assert o3 =~ "4"
      File.rm_rf!(dir)
    end

    test "queue_depth is 0 when idle", _ctx do
      assert BeamLisp.Daemon.Executor.queue_depth() == 0
    end
  end

  # ── helpers ──

  defp tmp_tree(tag, src) do
    dir = Path.join(System.tmp_dir!(), "bl-#{tag}-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ns = src |> String.split("\n") |> hd() |> String.replace(~r/[()]/, "") |> String.replace("ns ", "")
    File.write!(Path.join(dir, "#{ns}.bl"), src)
    dir
  end

  # Send a full request and collect stdout until the terminal frame.
  defp request(ctx, argv, cwd \\ nil, env_paths \\ []) do
    cwd = cwd || ctx.root
    {:ok, sock} = connect(ctx.ep.sock)
    send_frame(sock, Protocol.encode({:bl, 1, :hello, %{tree: ctx.tree, token: ctx.token}}))
    {:ok, {:bl, 1, :ready, _}} = recv_frame(sock)

    id = :crypto.strong_rand_bytes(16)
    send_frame(sock, Protocol.encode({:bl, 1, :request, id, %{argv: argv, cwd: cwd, env_paths: env_paths}}))

    result = collect(sock, id, "")
    :gen_tcp.close(sock)
    result
  end

  defp collect(sock, id, acc) do
    case recv_frame(sock) do
      {:ok, {:bl, 1, :stdout, ^id, _seq, bytes}} -> collect(sock, id, acc <> bytes)
      {:ok, {:bl, 1, :stderr, ^id, _seq, bytes}} -> collect(sock, id, acc <> bytes)
      {:ok, {:bl, 1, :exit, ^id, code}} -> {acc, code}
      {:ok, {:bl, 1, :failed, ^id, code, _}} -> {acc, code}
      {:ok, _other} -> collect(sock, id, acc)
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

  defp send_frame(sock, bin), do: :ok = :gen_tcp.send(sock, bin)

  defp recv_frame(sock) do
    case :gen_tcp.recv(sock, 0, 15_000) do
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
