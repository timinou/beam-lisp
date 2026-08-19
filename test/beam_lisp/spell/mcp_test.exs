defmodule BeamLisp.Spell.McpTest do
  @moduledoc """
  The MCP face: JSON-RPC over POST, the three tools, and the two honest
  failure modes (no loop running; a method this server does not speak).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias BeamLisp.Spell.{Loop, Mcp}

  setup do
    dir = Path.join(System.tmp_dir!(), "spell-mcp-#{System.unique_integer([:positive])}")
    Application.put_env(:beam_lisp, :spell_state_dir, dir)

    on_exit(fn ->
      if pid = Process.whereis(Loop), do: GenServer.stop(pid)
      Application.delete_env(:beam_lisp, :spell_state_dir)
      File.rm_rf(dir)
    end)

    :ok
  end

  defp rpc(method, params \\ %{}, id \\ 1) do
    body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

    conn(:post, "/spell/mcp", body)
    |> put_req_header("content-type", "application/json")
    |> Mcp.call([])
  end

  defp result(conn), do: JSON.decode!(conn.resp_body)["result"]

  test "initialize carries the briefing as instructions, computed from the machine" do
    {:ok, _pid} = Loop.start_link(publish: false, persist: false)

    conn = rpc("initialize", %{"protocolVersion" => "2025-03-26", "capabilities" => %{}})

    assert conn.status == 200
    r = result(conn)
    assert r["serverInfo"]["name"] == "spell"
    assert r["instructions"] =~ "run"
    # read FROM the machine — the seed's contract is named
    assert r["instructions"] =~ "chat-live"
  end

  test "tools/list names exactly the three tools" do
    {:ok, _pid} = Loop.start_link(publish: false, persist: false)

    names = rpc("tools/list") |> result() |> Map.get("tools") |> Enum.map(& &1["name"])

    assert Enum.sort(names) == ["run", "state", "transcript"]
  end

  test "tools/call run is Loop.run — the ladder, nothing else" do
    {:ok, _pid} = Loop.start_link(publish: false, persist: false)

    accepted =
      rpc("tools/call", %{
        "name" => "run",
        "arguments" => %{"source" => "(def mcp-test-value 7)", "rationale" => "t"}
      })
      |> result()

    assert [%{"text" => text}] = accepted["content"]
    verdict = JSON.decode!(text)
    assert verdict["status"] == "ok"
    assert verdict["kind"] == "code"

    refused =
      rpc("tools/call", %{
        "name" => "run",
        "arguments" => %{"source" => "(defmacro sneaky [x] x)", "rationale" => "t"}
      })
      |> result()

    assert JSON.decode!(hd(refused["content"])["text"])["status"] == "rejected"
  end

  test "state answers with the machine report" do
    {:ok, _pid} = Loop.start_link(publish: false, persist: false)

    r = rpc("tools/call", %{"name" => "state", "arguments" => %{}}) |> result()
    state = JSON.decode!(hd(r["content"])["text"])

    assert is_integer(state["version"])
    assert %{"contracts" => _, "views" => _} = state["machine"]
  end

  test "every tool fails clean when no loop is running" do
    refute Process.whereis(Loop)

    for tool <- ["run", "state", "transcript"] do
      r = rpc("tools/call", %{"name" => tool, "arguments" => %{"source" => "x", "rationale" => "y"}}) |> result()
      assert r["isError"] == true
      assert hd(r["content"])["text"] =~ "not running"
    end
  end

  test "an unknown method is -32601, not a crash" do
    conn = rpc("definitely/not-a-method")
    assert conn.status == 200
    assert JSON.decode!(conn.resp_body)["error"]["code"] == -32601
  end

  test "a notification gets 202 and no body" do
    {:ok, _pid} = Loop.start_link(publish: false, persist: false)

    body = JSON.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    conn =
      conn(:post, "/spell/mcp", body)
      |> put_req_header("content-type", "application/json")
      |> Mcp.call([])

    assert conn.status == 202
  end

  test "other paths pass through untouched" do
    conn = conn(:get, "/elsewhere")
    assert Mcp.call(conn, []) == conn
  end
end
