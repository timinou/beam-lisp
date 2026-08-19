defmodule BeamLisp.Spell.Mcp do
  @moduledoc """
  The model's face: the loop, exposed as an MCP server.

  W5 moved the model OUT of the image. The provider/cassette/credentials
  stack answered "how does this VM call an LLM API" — and the answer was
  hundreds of lines of auth, streaming, retry and recording machinery for a
  problem the host already solved: every serious model client (Claude Code,
  Tidewave's own audience, mcp-remote) already speaks MCP. So the loop stops
  DRIVING a model and starts ANSWERING one.

  Three tools, which is the whole surface a growing machine needs:

    * `run`        — the one verb: definition SOURCE in, the ladder's verdict
                     out. Identical to `Spell.Loop.run/3`, because it IS it.
    * `state`      — the machine's report: what exists, what it noticed.
    * `transcript` — the conversation so far.

  The briefing — what the model must know about the machine it is editing —
  rides in `initialize`'s `instructions` field, computed FROM THE MACHINE at
  session start, so it cannot describe a system that changed underneath it
  (the rule live.bl's machine-briefing established; same function).

  ## Protocol scope, honestly

  Streamable-HTTP POST, JSON responses (no SSE — the ladder's answers are
  single verdicts, not streams). `initialize`, `notifications/initialized`,
  `tools/list`, `tools/call`, `ping`. Anything else is a JSON-RPC
  -32601. One HTTP request is one JSON-RPC message; batching is not
  implemented because no client this server exists for sends it.

  ## Safety

  This endpoint is loopback-only by mount (the endpoint binds 127.0.0.1) and
  carries NO authentication, like Tidewave: the threat model is the
  operator's own machine. What it does NOT expose matters more: there is no
  eval here. The only write path is `run`, and `run` walks the ladder —
  read, machine, verse, ghosts, fence — the same five rungs regardless of
  whether the source came from a browser, a script, or this socket.
  """

  @behaviour Plug

  import Plug.Conn

  alias BeamLisp.Spell.{Data, Loop}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{path_info: ["spell", "mcp"]} = conn, _opts) do
    cond do
      # Streamable HTTP's MUST: a server without auth (this one — loopback is
      # the whole boundary) validates Origin on every request, or a browser on
      # a hostile page (DNS rebinding makes even loopback reachable) could call
      # `run`. Absent Origin is a non-browser client — curl, an MCP host — and
      # is allowed; present-and-not-loopback is refused.
      not origin_ok?(conn) ->
        conn |> send_resp(403, "untrusted origin") |> halt()

      # The transport is POST-only (no SSE): GET gets 405 + Allow, per spec.
      conn.method != "POST" ->
        conn |> put_resp_header("allow", "POST") |> send_resp(405, "POST only") |> halt()

      true ->
        handle_post(conn)
    end
  end

  def call(conn, _opts), do: conn

  defp handle_post(conn) do
    {:ok, body, conn} = read_body(conn)

    with {:ok, %{"jsonrpc" => "2.0", "method" => method} = msg} <- JSON.decode(body),
         :ok <- valid_id(msg),
         {:ok, reply} <- dispatch(method, msg) do
      respond(conn, msg, reply)
    else
      {:error, :no_reply} ->
        # A notification: acknowledged, no body.
        conn |> send_resp(202, "") |> halt()

      {:error, %{"code" => _} = err} ->
        # A notification (NO id key) gets no response — not even to an error:
        # the sender asked for none. An id of null DID ask (it is the invalid
        # id valid_id rejects), and JSON-RPC answers those with id: null.
        case JSON.decode(body) do
          {:ok, msg} when not is_map_key(msg, "id") -> conn |> send_resp(202, "") |> halt()
          {:ok, %{"id" => id}} -> respond_error(conn, id, err)
          _ -> respond_error(conn, nil, err)
        end

      _ ->
        respond_error(conn, nil, %{
          "code" => -32700,
          "message" => "parse error: one JSON-RPC 2.0 object per POST"
        })
    end
  end

  # JSON-RPC request ids are string or integer; MCP 2025-03-26 forbids null.
  # A message with NO id is a notification (handled by respond/2's fallback);
  # a message with id:null gets -32600, and the error reply carries id:null,
  # which is the one place JSON-RPC reserves that spelling.
  defp valid_id(%{"id" => nil}) do
    {:error, %{"code" => -32600, "message" => "invalid request: id must be a string or integer"}}
  end

  defp valid_id(%{"id" => id}) when is_binary(id) or is_integer(id), do: :ok
  defp valid_id(_no_id), do: :ok

  # ── dispatch ──────────────────────────────────────────────────────────────

  defp dispatch("initialize", _msg) do
    {:ok,
     %{
       "protocolVersion" => "2025-03-26",
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{"name" => "spell", "version" => "1.0.0"},
       "instructions" => briefing()
     }}
  end

  defp dispatch("notifications/" <> _rest, _msg), do: {:error, :no_reply}
  defp dispatch("ping", _msg), do: {:ok, %{}}
  defp dispatch("tools/list", _msg), do: {:ok, %{"tools" => tools()}}

  defp dispatch("tools/call", %{"params" => %{"name" => name, "arguments" => args}}) do
    case call_tool(name, args || %{}) do
      {:ok, text} -> {:ok, %{"content" => [%{"type" => "text", "text" => text}]}}
      {:error, text} -> {:ok, %{"content" => [%{"type" => "text", "text" => text}], "isError" => true}}
    end
  end

  defp dispatch("tools/call", %{"params" => %{"name" => name}}) when is_binary(name) do
    # `arguments` is optional per the spec; a call without it means {}.
    dispatch("tools/call", %{"params" => %{"name" => name, "arguments" => %{}}})
  end

  defp dispatch("tools/call", _malformed) do
    {:error, %{"code" => -32602, "message" => "invalid params: tools/call wants {name, arguments}"}}
  end

  defp dispatch(other, _msg) do
    {:error, %{"code" => -32601, "message" => "method not found: #{other}"}}
  end

  # ── the tools ─────────────────────────────────────────────────────────────

  defp tools do
    [
      %{
        "name" => "run",
        "description" =>
          "Grow the machine. Takes a definition's SOURCE — the same text a " <>
            "human author writes: `(defcontract name (assign @x :type init) " <>
            "(on :ev [param] (ok …)) …)` for server state and events, " <>
            "`(defview name (markup (template &shell [] [:div …]) …) (style " <>
            "[selector {rules}] …) (binds [selector (st/each @xs :as @x " <>
            ":template &row)] …))` for markup, style and bindings, and the " <>
            "code heads `(defn name [args] body)` / `(def name value)` for " <>
            "functions and values (they land in `spell.vars`). The source " <>
            "walks the validation ladder — read, machine, verse compile, " <>
            "ghost selectors, fence for code — and the verdict comes back " <>
            "with the rung named. A rejection leaves the machine unchanged; " <>
            "an acceptance rebuilds the page immediately.",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["source", "rationale"],
          "properties" => %{
            "source" => %{
              "type" => "string",
              "description" => "ONE definition form, exactly as an author writes it."
            },
            "rationale" => %{
              "type" => "string",
              "description" => "One sentence: why. It is journaled with the definition."
            }
          }
        }
      },
      %{
        "name" => "state",
        "description" =>
          "The machine's report: contracts, views, assigns, pushes, events, " <>
            "and everything the machine has noticed (orphan bindings, dead " <>
            "templates, stale publishes). Read this BEFORE defining — a " <>
            "definition that disagrees with what is registered is refused.",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "transcript",
        "description" => "The conversation so far: user turns, model turns, verdicts.",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    ]
  end

  defp call_tool(name, args) do
    # The whereis-then-call race is handled, not checked away: the loop can
    # exit between ANY availability check and the call, so the call itself is
    # what is guarded. A dead loop is a clean isError, never a crashed conn.
    if Process.whereis(Loop) do
      try do
        do_call_tool(name, args)
      catch
        :exit, reason -> {:error, "the loop did not answer: #{inspect(reason)}"}
      end
    else
      {:error,
       "the loop is not running — nothing to grow. Start BeamLisp.Spell.Loop first."}
    end
  end

  defp do_call_tool("run", %{"source" => source, "rationale" => rationale})
       when is_binary(source) and is_binary(rationale) do
    verdict = Loop.run(Loop, source, rationale)
    {:ok, JSON.encode!(Data.from_bl(verdict))}
  end

  defp do_call_tool("run", _args) do
    {:error, "run wants {source, rationale}, both strings"}
  end

  defp do_call_tool("state", _args) do
    # Loop.state's snapshot already carries the machine-report, converted to
    # plain data — asking live.bl to re-report it would report ON a report.
    snapshot = Loop.state(Loop)
    {:ok, JSON.encode!(%{version: snapshot.version, machine: snapshot.machine})}
  end

  defp do_call_tool("transcript", _args) do
    {:ok, JSON.encode!(Loop.transcript_messages(Loop))}
  end

  defp do_call_tool(other, _args), do: {:error, "no such tool: #{other}"}

  # ── briefing + plumbing ───────────────────────────────────────────────────

  # The briefing is computed at session start FROM THE MACHINE. When no loop
  # is running there is nothing to describe — and instructions that lie are
  # worse than none, so the field degrades to the generic rule.
  defp briefing do
    if Process.whereis(Loop) do
      machine = Loop.machine(Loop)

      machine
      |> then(&bl("spell.live", "machine-briefing", [&1]))
      |> Data.from_bl()
      |> to_string()
    else
      "You are editing a LIVE machine by calling the `run` tool with source. " <>
        "Call `state` first to see what exists."
    end
  end

  defp bl(ns, name, args) do
    fun = BeamLisp.Env.fetch!(ns, name)

    unless is_function(fun, length(args)) do
      raise ArgumentError,
            "#{ns}/#{name} is not a function of #{length(args)} argument(s) — got #{inspect(fun)}"
    end

    apply(fun, args)
  end

  defp respond(conn, %{"id" => id}, result) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
    |> halt()
  end

  # A request with no id is a notification EVEN when it names a method we
  # answered: JSON-RPC says no id means no response wanted.
  defp respond(conn, _no_id, _result) do
    conn |> send_resp(202, "") |> halt()
  end

  defp respond_error(conn, id, err) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => err}))
    |> halt()
  end


  # The whole boundary: no Origin header (curl, an MCP host process — not a
  # browser) or a loopback origin. Anything else is a browser on a page we did
  # not serve, and browsers are the only clients that send Origin on POST.
  defp origin_ok?(conn) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin] -> loopback_origin?(origin)
      _ -> false
    end
  end

  defp loopback_origin?(origin) do
    case URI.parse(origin) do
      %{host: host, scheme: scheme}
      when scheme in ["http", "https"] and host in ["127.0.0.1", "localhost", "::1", "[::1]"] ->
        true

      _ ->
        false
    end
  end
end
