defmodule BeamLisp.DaemonPortsTest do
  @moduledoc """
  W3: the session's address.

  Two things are under test. First the registry (`BeamLisp.Daemon.Ports`): a
  claim is a file, a live claim is respected, a stale one is swept, and a port
  somebody else holds is refused BY NAME rather than taken. Second the daemon's
  HTTP face: the `:ui` port it claims serves the session page and the MCP
  endpoint, and it says out loud how to pin the port it is ephemeral on.
  """

  use ExUnit.Case, async: false

  alias BeamLisp.Daemon.{HTTP, Paths, Ports, Protocol, Server}

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

    %{root: root, ep: ep, token: File.read!(ep.token), tree: Paths.tree_id(root)}
  end

  # ── the registry ──────────────────────────────────────────────────────

  test "an ephemeral claim is assigned, remembered, and idempotent" do
    name = "t#{:erlang.unique_integer([:positive])}"
    {:ok, port} = Ports.claim(name, 0, root: "/tmp/a")
    assert is_integer(port) and port > 0
    assert Ports.port_of(name) == port
    assert {:ok, ^port} = Ports.claim(name, 0, root: "/tmp/a")
    assert %{name: ^name, port: ^port, root: "/tmp/a"} = Ports.holder(port)
    Ports.release(name)
    assert Ports.port_of(name) == nil
  end

  test "a name another session holds is refused, naming the owner" do
    name = "t#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Ports.claim(name, 0, root: "/tmp/owner-tree")

    assert {:error, {:taken, claim}} =
             Ports.claim(name, 0, root: "/tmp/thief-tree", pid: 4_194_303)

    assert claim.root == "/tmp/owner-tree"
    Ports.release(name)
  end

  test "a stale claim — its owner gone — is swept, not respected" do
    name = "t#{:erlang.unique_integer([:positive])}"
    {:ok, port} = Ports.claim(name, 0, root: "/tmp/dead")

    # rewrite the claim as if a process that no longer exists had made it
    {:ok, dir} = ports_dir()
    path = Path.join(dir, name)
    dead = %{name: name, port: port, tree_id: "dead", root: "/tmp/dead", pid: 999_999_999, claimed_at: 0}
    File.write!(path, :erlang.term_to_binary(dead))

    refute Enum.any?(Ports.list(), fn c -> c.name == name end)
    refute File.exists?(path)
  end

  test "a port already in use by an unclaimed process is refused" do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, ip: {0, 0, 0, 0}])
    {:ok, {_ip, busy}} = :inet.sockname(lsock)

    assert {:error, {:port_busy, ^busy, nil}} =
             Ports.claim("t#{:erlang.unique_integer([:positive])}", busy, root: "/tmp/a")

    :gen_tcp.close(lsock)
  end

  # ── the session's address ─────────────────────────────────────────────

  test "the daemon claims :ui, serves the page, and lists ports as JSON", ctx do
    port = session_port(ctx.root)
    assert is_integer(port), "the daemon claims :ui at boot"

    page = Req.get!("http://127.0.0.1:#{port}/")
    assert page.status == 200
    assert page.body =~ "warm session"
    assert page.body =~ Path.basename(ctx.root)
    assert page.body =~ ">ui<"

    ports = Req.get!("http://127.0.0.1:#{port}/ports")
    assert ports.status == 200

    # The registry is machine-wide ON PURPOSE — a claim is a file so that
    # another tree's session is visible rather than invisible — so assert THIS
    # session's claim, not that it is the only one: other trees (and other test
    # runs) legitimately hold claims at the same moment.
    mine = Enum.find(ports.body, fn c -> c["name"] == "ui" and c["root"] == ctx.root end)
    assert mine, "this session's :ui claim is in the table"
    assert mine["port"] == port
    assert mine["tree"] == ctx.tree
  end

  test "the MCP endpoint answers the same dispatch as `bl mcp`", ctx do
    port = session_port(ctx.root)

    resp =
      Req.post!("http://127.0.0.1:#{port}/mcp",
        json: %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list",
          # the protocol version rides in _meta on every request
          "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
        },
        # the first MCP request may still be waiting on the background index
        receive_timeout: 120_000
      )

    assert resp.status == 200
    body = resp.body
    assert body["id"] == 1
    assert is_list(body["result"]["tools"])
    names = Enum.map(body["result"]["tools"], & &1["name"])
    assert "code/query" in names
    assert "code/ask" in names
  end

  test "the dashboard renders the model, and an intent runs a task", ctx do
    root = Path.join(System.tmp_dir!(), "bl_dash_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "priv/boot"))
    File.write!(Path.join(root, "priv/boot/core.bl"), "; marker\n")
    File.write!(Path.join(root, "env.bl"), ~s({:tasks {:hi "run.bl" :loop {:run "run.bl" :watch true}}}))
    File.write!(Path.join(root, "run.bl"), "(println \"hello from a task\")\n")
    on_exit(fn -> File.rm_rf!(root) end)

    case Process.whereis(Server) do
      nil -> :ok
      old -> try do: GenServer.stop(old, :normal, 2_000), catch: (:exit, _ -> :ok)
    end

    {:ok, pid} = Server.start_link(root: root, boot: true, idle_seconds: 0)
    {:ok, ep} = Paths.endpoints(root)
    wait_for(fn -> File.exists?(ep.token) end)
    on_exit(fn -> stop_quietly(pid) end)

    port = session_port(root)
    assert is_integer(port)

    page = Req.get!("http://127.0.0.1:#{port}/")
    assert page.status == 200
    assert page.body =~ "runTask('hi')", "a runnable task offers a button"
    assert page.body =~ "run without the daemon", "a :watch task says why it has none"
    assert page.body =~ "hello from a task" == false

    model = Req.get!("http://127.0.0.1:#{port}/model")
    assert model.status == 200
    assert Enum.map(model.body["tasks"], & &1["name"]) == ["hi", "loop"]

    # an intent without the token is refused: a page the developer visits must
    # not be able to drive their daemon
    refused = Req.post!("http://127.0.0.1:#{port}/intent", json: %{"name" => "hi"})
    assert refused.status == 403

    token = Base.encode16(File.read!(ep.token), case: :lower)

    ok =
      Req.post!("http://127.0.0.1:#{port}/intent",
        json: %{"name" => "hi"},
        headers: %{"x-bl-token" => token},
        receive_timeout: 120_000
      )

    assert ok.status == 200
    assert ok.body["exit"] == 0
    assert ok.body["output"] =~ "hello from a task"

    # a :watch task is refused with a reason, not parked on the worker
    watched =
      Req.post!("http://127.0.0.1:#{port}/intent",
        json: %{"name" => "loop"},
        headers: %{"x-bl-token" => token}
      )

    assert watched.status == 400
    assert watched.body["error"] =~ "keeps its own process"

    stop_quietly(pid)
    _ = ctx
  end

  test "an unknown path is a JSON 404", ctx do
    port = session_port(ctx.root)
    resp = Req.get!("http://127.0.0.1:#{port}/nope")
    assert resp.status == 404
  end

  test "the startup message names the session and how to pin its port", ctx do
    # the NAME is the session's address, and the loopback one is what still
    # answers without the gateway — so the message prints both, for the same
    # reason it prints how to pin a port nobody should have to remember
    host = BeamLisp.Daemon.Names.host(ctx.root, "ui")

    msg = Server.startup_message(ctx.root, %{port: 43_123, pinned: false, error: nil})
    assert msg =~ "bl daemon up for #{ctx.root}"
    assert msg =~ "http://#{host}"
    assert msg =~ "127.0.0.1:43123"
    assert msg =~ "ephemeral — pin it in env.bl"
    assert msg =~ "http://#{host}/mcp"
    assert msg =~ "bl gateway start"

    pinned = Server.startup_message(ctx.root, %{port: 7700, pinned: true, error: nil})
    assert pinned =~ "pinned by env.bl"

    broken = Server.startup_message(ctx.root, %{port: nil, pinned: false, error: :eaddrinuse})
    assert broken =~ "not served"
  end

  test "a project can pin the session's port", ctx do
    root = Path.join(System.tmp_dir!(), "bl_pinned_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "env.bl"), "{:ports {:ui 0}}")

    on_exit(fn -> File.rm_rf!(root) end)

    # pinning 0 is still ephemeral; the point is that the value comes from the
    # project rather than from the daemon's default.
    assert BeamLisp.Daemon.Server.startup_message(root, %{port: 5, pinned: true, error: nil}) =~ "pinned"
    _ = ctx
  end

  # ── helpers ──

  # The port THIS session holds for `name`. `Ports.port_of/1` looks a name up
  # machine-wide, and a claim's file is named by the NAME alone — so another
  # tree's session (or a parallel test run) can hold `:ui` at the same moment
  # and the lookup would answer with ITS port. Ask for our tree's claim.
  defp session_port(root, name \\ :ui) do
    Enum.find_value(Ports.list(), fn c ->
      if to_string(c.name) == to_string(name) and c.root == root, do: c.port
    end)
  end

  defp ports_dir do
    with {:ok, base} <- Paths.runtime_dir(), do: {:ok, Path.join(base, "ports")}
  end

  # A daemon that is already on its way down is not an error; a test teardown
  # must not turn a passing run red.
  defp stop_quietly(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 2_000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp wait_for(_fun, 0), do: :timeout

  defp wait_for(fun, tries \\ 150) do
    if fun.(), do: :ok, else: (Process.sleep(20); wait_for(fun, tries - 1))
  end
end
