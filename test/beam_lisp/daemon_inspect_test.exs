defmodule BeamLisp.DaemonInspectTest do
  @moduledoc """
  W5: one read-model, two faces.

  The claim is not "there is a status endpoint" — it is that the terminal text
  and the JSON the browser reads are two RENDERINGS of one value. These cases
  build the model once and assert both faces against it, so a field that reaches
  one face and not the other fails here rather than in a user's browser.
  """

  use ExUnit.Case, async: false

  alias BeamLisp.Daemon.{Inspect, Paths, Ports, Server}

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

    %{root: root, pid: pid}
  end

  test "the model carries identity, ports, tasks and the queue" do
    m = Inspect.model()
    assert m.identity.name == Path.basename(File.cwd!())
    assert is_integer(m.identity.uptime_ms)
    assert is_list(m.ports)
    assert Enum.any?(m.ports, fn p -> p.name == "ui" end)
    assert is_list(m.tasks)
    assert is_integer(m.queue.depth)
  end

  test "both faces are rendered from the same value" do
    m = Inspect.model()
    text = Inspect.render_text(m)
    js = Inspect.json()

    # the port table: every live claim appears in both, with the same number
    for p <- m.ports do
      assert text =~ "#{p.name} = #{p.port}"
      assert Enum.any?(js["ports"], fn j -> j["name"] == p.name and j["port"] == p.port end)
    end

    # and the model's own URL reaches both
    ui = Enum.find(m.ports, fn p -> p.name == "ui" end)
    assert text =~ ui.url
    assert text =~ ui.url <> "mcp"
  end

  test "the JSON face is JSON-safe: string keys, no structs" do
    js = Inspect.json()
    assert Map.keys(js) |> Enum.sort() == ["identity", "image", "ports", "queue", "tasks"]
    assert is_map(js["identity"])
    assert Enum.all?(Map.keys(js["identity"]), fn k -> is_binary(k) end)
    # encoding it is the proof it is JSON-safe
    assert is_binary(Jason.encode!(js))
  end

  test "a tree that declares tasks shows them in both faces" do
    root = tree_with_tasks()

    case Process.whereis(Server) do
      nil -> :ok
      old -> try do: GenServer.stop(old, :normal, 2_000), catch: (:exit, _ -> :ok)
    end

    {:ok, pid} = Server.start_link(root: root, boot: true, idle_seconds: 0)
    {:ok, ep} = Paths.endpoints(root)
    wait_for(fn -> File.exists?(ep.token) end)
    on_exit(fn -> File.rm_rf!(root) end)

    m = Inspect.model()
    assert Enum.map(m.tasks, & &1.name) == ["hi", "loop"]
    assert Enum.find(m.tasks, &(&1.name == "loop")).watch

    text = Inspect.render_text(m)
    assert text =~ "task          hi"
    assert text =~ "[watch]"
    assert Enum.map(Inspect.json()["tasks"], & &1["name"]) == ["hi", "loop"]

    _ = ep
    GenServer.stop(pid, :normal, 2_000)
  end

  test "the ports face names the owner of every claim" do
    {:ok, port} = Ports.claim("w#{:erlang.unique_integer([:positive])}", 0, root: "/tmp/somewhere")
    on_exit(fn -> Ports.list() |> Enum.filter(&(&1.port == port)) |> Enum.each(&Ports.release(&1.name)) end)

    m = Inspect.model()
    text = Inspect.render_text(m)
    claim = Enum.find(m.ports, &(&1.port == port))
    assert claim.root == "/tmp/somewhere"
    assert text =~ "(somewhere, pid #{claim.pid})"
  end

  # ── helpers ──

  # A tree the daemon accepts as a root: `priv/boot/core.bl` is the marker it
  # looks for. The daemon still boots the REAL substrate — this only decides
  # which tree's env.bl the session describes.
  defp tree_with_tasks do
    root = Path.join(System.tmp_dir!(), "bl_inspect_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "priv/boot"))
    File.write!(Path.join(root, "priv/boot/core.bl"), "; marker\n")

    File.write!(Path.join(root, "env.bl"), """
    {:name "tasks-tree"
     :tasks {:hi   "run.bl"
             :loop {:run "run.bl" :watch true :doc "the dev loop"}}}
    """)

    root
  end

  defp wait_for(_fun, 0), do: :timeout

  defp wait_for(fun, tries \\ 200) do
    if fun.(), do: :ok, else: (Process.sleep(20); wait_for(fun, tries - 1))
  end
end
