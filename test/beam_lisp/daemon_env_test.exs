defmodule BeamLisp.DaemonEnvTest do
  @moduledoc """
  The warm path binds the tree's `env.bl` exactly as a standalone `bl` does.

  Warmth is an optimization, never a difference in meaning: a request the daemon
  serves runs `bl.cli/run-argv` — the same entry a cold run calls — so the
  project file a client's directory finds (its own, discovered from the CLIENT's
  cwd, not the daemon's checkout) is the one that binds. This test proves the
  two hosts agree by running the same tree through the daemon and asserting the
  declared library root resolved and the declared environment variable was set.
  """
  use ExUnit.Case, async: false

  alias BeamLisp.Daemon.{Paths, Protocol, Server}

  setup do
    root = File.cwd!()

    case Process.whereis(Server) do
      nil -> :ok
      old -> try do: GenServer.stop(old, :normal, 2_000), catch: (:exit, _ -> :ok)
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

    %{ep: ep, token: File.read!(ep.token), tree: Paths.tree_fingerprint(root)}
  end

  test "a request binds the env.bl of the CLIENT's tree", ctx do
    root = tree_fixture()
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} = request(ctx, ["run", "src/app.bl"], root)
    assert code == 0
    assert out =~ "hi from lib, mode=engaged"

    # and from a subdirectory: discovery walks up to the SAME file
    deep = Path.join([root, "sub", "dir"])
    File.mkdir_p!(deep)
    {out, 0} = request(ctx, ["run", "../../src/app.bl"], deep)
    assert out =~ "hi from lib, mode=engaged"
  end

  test "a tree the client runs in, not the daemon's own checkout", ctx do
    # the daemon's root is this repository; the client is somewhere else
    root = tree_fixture()
    on_exit(fn -> File.rm_rf!(root) end)

    # the repo has no env.bl, so a request from here binds nothing
    {out, code} = request(ctx, ["eval", "(println \"plain\")"], File.cwd!())
    assert code == 0
    assert out =~ "plain"
    refute out =~ "hi from lib"

    # while the same command shape in the client's tree uses ITS env.bl
    {out2, 0} = request(ctx, ["run", "src/app.bl"], root)
    assert out2 =~ "mode=engaged"
  end

  test "a task runs warm, and a :watch task is refused rather than parked", ctx do
    root = tasks_fixture()
    on_exit(fn -> File.rm_rf!(root) end)

    # a plain task is ordinary work: the warm VM runs it
    {out, 0} = request(ctx, ["hi"], root)
    assert out =~ "hi from a task"

    # a `:watch` task never returns. The daemon has ONE worker, so parking it
    # would block every later client behind a session with no end — it is
    # refused, and the refusal is the CLI's own judgment about the project.
    {out2, code} = request(ctx, ["dev"], root)
    assert code == 1
    assert out2 =~ "keeps its own process"
  end

  # ── helpers ──

  defp tasks_fixture do
    root =
      Path.join(System.tmp_dir!(), "bl_daemon_tasks_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "src"))

    File.write!(Path.join(root, "env.bl"), """
    {:paths ["src"]
     :tasks {:hi  "src/hi.bl"
             :dev {:run "src/hi.bl" :watch true}}}
    """)

    File.write!(Path.join(root, "src/hi.bl"), """
    (println "hi from a task")
    """)

    root
  end

  defp tree_fixture do
    root =
      Path.join(System.tmp_dir!(), "bl_daemon_env_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "src/lib"))

    File.write!(Path.join(root, "env.bl"), """
    {:name "probe"
     :paths ["src"]
     :env {"BL_DAEMON_ENV_MODE" "engaged"}}
    """)

    File.write!(Path.join(root, "src/lib/thing.bl"), """
    (ns lib.thing)
    (defn hi [] (str "hi from lib, mode=" (System/get_env "BL_DAEMON_ENV_MODE")))
    """)

    File.write!(Path.join(root, "src/app.bl"), """
    (ns app (:require [lib.thing :as t]))
    (println (t/hi))
    """)

    root
  end

  defp request(ctx, argv, cwd) do
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

  defp wait_for(_fun, 0), do: :timeout
  defp wait_for(fun, tries \\ 150) do
    if fun.(), do: :ok, else: (Process.sleep(20); wait_for(fun, tries - 1))
  end
end
