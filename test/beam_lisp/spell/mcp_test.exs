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

  test "GET on the endpoint is 405 with Allow: POST (no SSE transport)" do
    conn = conn(:get, "/spell/mcp") |> Mcp.call([])
    assert conn.status == 405
    assert get_resp_header(conn, "allow") == ["POST"]
  end

  test "a browser origin that is not loopback is refused before the body is read" do
    conn =
      conn(:post, "/spell/mcp", ~s({"jsonrpc":"2.0","id":1,"method":"tools/list"}))
      |> put_req_header("origin", "https://evil.example")
      |> Mcp.call([])

    assert conn.status == 403
  end

  test "loopback origins and no origin (curl, MCP hosts) pass" do
    {:ok, _pid} = Loop.start_link(publish: false, persist: false)

    for origin <- ["http://127.0.0.1:4173", "http://localhost:4000", nil] do
      conn = conn(:post, "/spell/mcp", ~s({"jsonrpc":"2.0","id":1,"method":"tools/list"}))
      conn = if origin, do: put_req_header(conn, "origin", origin), else: conn
      assert Mcp.call(conn, []).status == 200
    end
  end

  test "a notification naming an unknown method gets 202, not an error body" do
    body = ~s({"jsonrpc":"2.0","method":"no.such/method"})

    conn =
      conn(:post, "/spell/mcp", body)
      |> put_req_header("content-type", "application/json")
      |> Mcp.call([])

    assert conn.status == 202
  end

  test "id:null is -32600, answered with id null" do
    conn = rpc("tools/list", %{}, nil)
    decoded = JSON.decode!(conn.resp_body)
    assert decoded["error"]["code"] == -32600
    assert Map.has_key?(decoded, "id")
  end

  test "tools/call with malformed params is -32602, not -32601" do
    {:ok, _pid} = Loop.start_link(publish: false, persist: false)
    conn = rpc("tools/call", %{"name" => 42})
    assert JSON.decode!(conn.resp_body)["error"]["code"] == -32602
  end
end
