defmodule BeamLisp.Daemon.HTTP do
  @moduledoc """
  The session's HTTP face, served on the port the daemon claims as `:ui`.

    * `GET  /`       — the dashboard: the session's read-model, rendered.
    * `GET  /model`  — the same read-model as JSON.
    * `GET  /ports`  — the port table alone, as JSON.
    * `POST /mcp`    — the SAME MCP server `bl mcp` serves over stdio: one
                       JSON-RPC message per request.
    * `POST /intent` — run a project task through the daemon's single worker.

  ## One model, two faces

  Everything rendered here comes from `BeamLisp.Daemon.Inspect`. The terminal's
  `bl daemon status` renders the same value, so the two faces cannot disagree:
  a pane added here is a field added there.

  ## Why the write path wants a header

  The listener is loopback-only, but loopback is not a trust boundary: any page
  a developer visits can POST to `127.0.0.1`, and running a project's tasks on
  someone else's say-so is exactly the hole this face must not open. So the page
  carries the daemon's own token (server-rendered, unreadable cross-origin) and
  every intent must present it in `x-bl-token`. A cross-origin caller cannot
  read the token, and cannot send a custom header without a preflight this
  server never approves.

  The dashboard is deliberately server-rendered: the read-model is the product,
  and a live diffing client is a follow-up, not a substitute for one.
  """

  @behaviour Plug

  import Plug.Conn

  alias BeamLisp.Daemon.{Gateway, Inspect, IndexWorker, Ports}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    case {conn.method, conn.request_path} do
      {"GET", "/"} -> dashboard(conn, opts)
      {"GET", "/model"} -> json(conn, 200, Inspect.json(conn_opts(opts)))
      {"GET", "/ports"} -> json(conn, 200, ports_json())
      {"GET", "/index"} -> json(conn, 200, index_json())
      {"POST", "/mcp"} -> mcp(conn, opts)
      {"POST", "/intent"} -> intent(conn, opts)
      {"POST", "/index"} -> index_now(conn, opts)
      _ -> not_found(conn)
    end
  end

  # --- the index ---

  # The tree's code index, as the index worker last reported it. `GET /index`
  # reads the worker's ETS row (never a call: the pane must stay readable while
  # the build it describes is running), and `POST /index` asks for a build — the
  # button the page shows when the tree has none, and the same call `bl ui`
  # makes on entry so opening a session starts the work.
  defp index_json do
    p = IndexWorker.progress()

    %{
      "phase" => to_string(p.phase),
      "done" => Map.get(p, :done, 0),
      "total" => Map.get(p, :total, 0),
      "file" => Map.get(p, :file),
      "from" => Map.get(p, :from),
      "ms" => Map.get(p, :ms),
      "hit" => Map.get(p, :hit),
      "message" => Map.get(p, :message),
      "at" => Map.get(p, :at),
      "stats" => index_stats(Map.get(p, :stats))
    }
  end

  # The beam-lisp stats map, as JSON: the numbers a reader wants (how many
  # files, how many were analyzed vs came from cache) with the internal ones
  # left out rather than rendered as `nil` fields.
  defp index_stats(nil), do: nil

  defp index_stats(s) when is_map(s) do
    %{
      "files" => to_int(Map.get(s, :files)),
      "functions" => to_int(Map.get(s, :functions)),
      "analyzed" => to_int(Map.get(s, :analyzed)),
      "cached" => to_int(Map.get(s, :cached)),
      "skipped" => length(List.wrap(Map.get(s, :skipped)))
    }
  end

  defp index_stats(_), do: nil

  defp to_int(n) when is_integer(n), do: n
  defp to_int(_), do: 0

  defp index_now(conn, opts) do
    {:ok, _body, conn} = read_body(conn)

    with :ok <- check_token(conn, opts) do
      IndexWorker.ensure_building()
      json(conn, 200, index_json())
    else
      {:error, :forbidden} -> json(conn, 403, %{"error" => "missing or wrong x-bl-token"})
    end
  end

  # --- the dashboard ---

  defp dashboard(conn, opts) do
    m = Inspect.model(conn_opts(opts))
    id = m.identity

    body = """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <title>bl session — #{esc(id.name)}</title>
    <style>
      :root { color-scheme: dark; }
      body { margin: 0; padding: 2.6rem 1.5rem 5rem; background: #0b0a10; color: #ece9f5;
             font: 15px/1.6 ui-sans-serif, system-ui, sans-serif; }
      main { max-width: 52rem; margin: 0 auto; }
      h1 { font-size: 1.4rem; margin: 0 0 .15rem; }
      .kicker { color: #b4551f; letter-spacing: .18em; font-size: .72rem;
                text-transform: uppercase; }
      .sub { color: #9891ad; margin: 0 0 2rem; }
      section { border-top: 1px solid #2c2838; padding: 1.1rem 0; }
      h2 { font-size: .74rem; letter-spacing: .13em; text-transform: uppercase;
           color: #9891ad; margin: 0 0 .8rem; font-weight: 600; }
      code, .mono, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                    font-size: .85rem; }
      table { border-collapse: collapse; width: 100%; }
      td { padding: .3rem 0; vertical-align: top; }
      td.name { width: 9rem; font-weight: 600; }
      td.port { width: 5rem; color: #b4551f; }
      td.note { color: #9891ad; }
      .empty { color: #9891ad; }
      a { color: #7c5cff; }
      button { font: inherit; font-size: .8rem; color: #ece9f5; background: #201d2c;
               border: 1px solid #2c2838; border-radius: 9999px; padding: .18rem .75rem;
               cursor: pointer; }
      button:hover { border-color: #7c5cff; }
      pre { background: #16141f; border: 1px solid #2c2838; border-radius: 8px;
            padding: .7rem .8rem; margin: .6rem 0 0; white-space: pre-wrap; }
      .ok { color: #46d18f; } .bad { color: #ff8f8f; }
      .bar { background: #201d2c; border: 1px solid #2c2838; border-radius: 9999px;
             height: .5rem; width: 100%; max-width: 28rem; overflow: hidden; margin: .5rem 0 .2rem; }
      .bar > i { display: block; height: 100%; background: #7c5cff; transition: width .3s; }
      .note { color: #9891ad; }
    </style></head><body><main>
      <div class="kicker">beam-lisp · warm session</div>
      <h1>#{esc(id.name)}</h1>
      <p class="sub">pid #{id.pid} · up #{uptime(id.uptime_ms)} ·
        <span class="mono">#{esc(id.root)}</span> ·
        <a href="/model">model.json</a></p>

      <section>
        <h2>Tasks</h2>
        #{tasks_pane(m.tasks)}
        #{intent_output()}
      </section>

      <section>
        <h2>Ports</h2>
        #{ports_pane(m.ports)}
      </section>

      <section>
        <h2>Index</h2>
        #{index_pane()}
      </section>

      <section>
        <h2>Image</h2>
        #{image_pane(m[:image])}
      </section>

      <section>
        <h2>Worker</h2>
        <table>
          <tr><td class="name">queue_depth</td><td class="note mono">#{m.queue.depth}</td></tr>
          <tr><td class="name">compiler_key</td><td class="note mono">#{esc(short(id.compiler_key))}</td></tr>
        </table>
      </section>

      <section>
        <h2>Transport</h2>
        <table>
          <tr><td class="name">mcp</td><td class="note"><span class="mono">POST /mcp</span> —
            the same server <span class="mono">bl mcp</span> serves over stdio</td></tr>
          <tr><td class="name">model</td><td class="note"><span class="mono">GET /model</span>
            — the read-model this page is rendered from</td></tr>
          <tr><td class="name">terminal</td><td class="note"><span class="mono">bl daemon status</span>
            — the same model, the terminal's face of it</td></tr>
        </table>
      </section>
    </main>
    <script>
      const TOKEN = #{js_token(opts)};
      async function runTask(name) {
        const out = document.getElementById("intent-out");
        out.textContent = "running " + name + " …";
        out.className = "mono";
        try {
          const r = await fetch("/intent", {
            method: "POST",
            headers: { "content-type": "application/json", "x-bl-token": TOKEN },
            body: JSON.stringify({ name })
          });
          const data = await r.json();
          out.className = data.exit === 0 ? "mono ok" : "mono bad";
          out.textContent =
            "$ bl " + name + "   (exit " + data.exit + ")" +
            String.fromCharCode(10) + data.output;
        } catch (e) {
          out.className = "mono bad";
          out.textContent = "intent failed: " + e;
        }
      }
      function refresh() { location.reload(); }

      // Ask for an index, then keep looking at it. The page is server-rendered,
      // so the bar advances by polling the same JSON the pane was rendered
      // from — no second source of truth about what the build is doing.
      async function indexNow() {
        const out = document.getElementById("index-out");
        out.textContent = "indexing…";
        try {
          await fetch("/index", {
            method: "POST",
            headers: { "content-type": "application/json", "x-bl-token": TOKEN },
            body: "{}"
          });
          pollIndex();
        } catch (e) { out.textContent = "index request failed: " + e; }
      }

      async function pollIndex() {
        const out = document.getElementById("index-out");
        try {
          const p = await (await fetch("/index")).json();
          if (p.phase === "building") {
            out.textContent = "indexing " + p.done + "/" + p.total + " — " + (p.file || "");
            setTimeout(pollIndex, 700);
          } else if (p.phase === "ready") {
            out.textContent = "index ready in " + p.ms + " ms — reload to see it";
            setTimeout(() => location.reload(), 700);
          } else if (p.phase === "error") {
            out.textContent = "index failed: " + (p.message || "");
          } else {
            out.textContent = "";
          }
        } catch (e) { out.textContent = "poll failed: " + e; }
      }

      // A session that has no index starts one by being opened. `:cold` means
      // this worker has never built; anything else is either done or in flight.
      (async function () {
        try {
          const p = await (await fetch("/index")).json();
          if (p.phase === "cold") indexNow();
          else if (p.phase === "building") pollIndex();
        } catch (e) { /* the pane stays empty; not worth a dialog */ }
      })();
    </script>
    </body></html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, body)
  end

  defp tasks_pane([]), do: ~s(<p class="empty">this tree declares no tasks — add a :tasks map to env.bl</p>)

  defp tasks_pane(tasks) do
    rows =
      Enum.map_join(tasks, "\n", fn t ->
        "<tr><td class=\"name\">#{esc(t.name)}</td><td class=\"note\">" <>
          "#{esc(t.doc)}<br><span class=\"mono\">#{esc(t.run)}</span>" <>
          "#{if t.watch, do: " · watch", else: ""}</td>" <>
          "<td style=\"text-align:right\">" <>
          # a :watch task owns its process — the daemon refuses it, and the page
          # says why instead of offering a button that cannot work
          if t.watch do
            "<span class=\"note\">run without the daemon</span>"
          else
            "<button onclick=\"runTask('#{esc(t.name)}')\">run</button>"
          end <>
          "</td></tr>"
      end)

    "<table>#{rows}</table>"
  end

  defp intent_output, do: ~s(<pre id="intent-out" class="mono"></pre>)

  # The tree's code index: what it cost, and — while it is being built — how far
  # along it is. The page polls `GET /index` rather than waiting on the worker,
  # because the worker is BUSY building; and when it finds no index at all it
  # asks for one, so entering a session is enough to start the work rather than
  # a fact you discover by asking a question and waiting a minute for silence.
  defp index_pane do
    p = IndexWorker.progress()
    done = Map.get(p, :done, 0)
    total = Map.get(p, :total, 0)

    body =
      case p.phase do
        :ready ->
          s = Map.get(p, :stats) || %{}
          hit = if Map.get(p, :hit) == true, do: " (unchanged)", else: ""

          "<p><span class=\"ok\">ready</span>#{hit} · " <>
            "#{to_int(Map.get(s, :files))} files · " <>
            "#{to_int(Map.get(s, :functions))} functions · " <>
            "#{to_int(Map.get(s, :analyzed))} analyzed now, " <>
            "#{to_int(Map.get(s, :cached))} from cache · " <>
            "built in #{uptime(Map.get(p, :ms))}</p>"

        :building ->
          count = if total > 0, do: "#{done} / #{total} files", else: "starting…"

          "<p>indexing — #{count}</p>" <> progress_bar(done, total) <>
            "<p class=\"note mono\">#{esc(Map.get(p, :file) || "")}</p>"

        :error ->
          "<p><span class=\"bad\">index failed</span> " <>
            "<span class=\"mono\">#{esc(Map.get(p, :message) || "")}</span></p>"

        _ ->
          "<p class=\"empty\">no index yet — " <>
            "<button onclick=\"indexNow()\">index this tree</button></p>"
      end

    body <> ~s(<pre id="index-out" class="mono"></pre>)
  end

  # A bar needs a denominator; a build that has not counted its files yet gets a
  # bar that says so rather than a division by zero rendered as 0%.
  defp progress_bar(_done, 0), do: ~s(<div class="bar"><i style="width:2%"></i></div>)

  defp progress_bar(done, total) do
    pct = min(100, round(done / max(total, 1) * 100))
    ~s(<div class="bar"><i style="width:#{pct}%"></i></div> <span class="note">#{pct}%</span>)
  end

  defp ports_pane([]), do: ~s(<p class="empty">no ports claimed</p>)

  defp ports_pane(ports) do
    rows =
      Enum.map_join(ports, "\n", fn p ->
        "<tr><td class=\"name\">#{esc(p.name)}</td>" <>
          "<td class=\"port\">#{p.port}</td>" <>
          "<td class=\"note\"><a href=\"#{esc(p.url)}\">#{esc(p.url)}</a><br>" <>
          "#{esc(Path.basename(p.root))} · pid #{p.pid}</td></tr>"
      end)

    "<table>#{rows}</table>"
  end

  defp image_pane(nil),
    do: ~s(<p class="empty">the reload image is not loaded in this session — run <span class="mono">bl watch</span> or <span class="mono">bl monitor</span> to give it one</p>)

  defp image_pane(image) do
    text = BeamLisp.Daemon.Inspect.render_text(%{
      identity: %{name: "", root: "", pid: "", tree_id: "", compiler_key: nil, daemon_build_id: nil, uptime_ms: 0},
      ports: [], tasks: [], queue: %{depth: 0}, image: image
    })

    "<pre>#{esc(String.trim(text))}</pre>"
  end

  # --- intents: run a task on the single worker ---

  defp intent(conn, opts) do
    {:ok, body, conn} = read_body(conn)

    with :ok <- check_token(conn, opts),
         {:ok, %{"name" => name}} <- decode(body),
         {:ok, task} <- task_spec(name, opts) do
      {exit, output} = run_task(name, opts)

      json(conn, 200, %{
        "name" => name,
        "exit" => exit,
        "output" => output,
        "run" => task.run
      })
    else
      {:error, :forbidden} ->
        json(conn, 403, %{"error" => "missing or wrong x-bl-token"})

      {:error, :bad_json} ->
        json(conn, 400, %{"error" => "expected {\"name\": \"<task>\"}"})

      {:error, :no_such_task} ->
        json(conn, 404, %{"error" => "this tree declares no such task"})

      {:error, :owns_process} ->
        json(conn, 400, %{
          "error" => "that task keeps its own process — run it without the daemon"
        })
    end
  end

  defp check_token(conn, opts) do
    want = session_token(opts)

    given =
      case get_req_header(conn, "x-bl-token") do
        [t | _] -> t
        _ -> ""
      end

    if is_binary(want) and byte_size(want) == byte_size(given) and
         :crypto.hash_equals(want, given) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  # The daemon token is 32 random BYTES and not necessarily valid UTF-8; the
  # page and the header both carry it hex-encoded, which is also what makes it
  # safe to embed in a script.
  defp session_token(opts) do
    case Keyword.get(opts, :token) do
      t when is_binary(t) -> Base.encode16(t, case: :lower)
      _ -> ""
    end
  end

  defp task_spec(name, opts) do
    m = Inspect.model(conn_opts(opts))

    case Enum.find(m.tasks, fn t -> t.name == name end) do
      nil -> {:error, :no_such_task}
      %{watch: true} -> {:error, :owns_process}
      task -> {:ok, task}
    end
  end

  # Through the Executor, like every other command: an intent never races a
  # reload commit or a run, and it goes through the CLI's OWN task path — so a
  # task's :paths, its :watch refusal and its exit code mean here exactly what
  # they mean at a terminal. No second implementation of "run a task".
  defp run_task(name, opts) do
    BeamLisp.Loader.ensure_loaded("bl.cli")
    root = Inspect.model(conn_opts(opts)).identity.root

    BeamLisp.Daemon.Executor.run_capture(fn ->
      BeamLisp.with_cwd(root, fn ->
        BeamLisp.RT.invoke(BeamLisp.Env.fetch!("bl.cli", "run-argv"), [[name]])
      end)
    end)
  end

  # --- MCP over HTTP ---

  # One JSON-RPC message per request, answered by the SAME dispatch the stdio
  # transport uses. The server state is built on the FIRST request and kept for
  # the daemon's life: mounting the codebase takes seconds, and a session nobody
  # asks for MCP should not pay for it — the same rule as every lazy verb.
  defp mcp(conn, opts) do
    {:ok, body, conn} = read_body(conn)

    case decode(body) do
      {:ok, request} ->
        # On the IndexWorker, not this per-request process: the index mount the
        # request may trigger builds ETS tables owned by their creator, and a
        # connection process dies with its response. See IndexWorker's moduledoc.
        json(conn, 200, IndexWorker.run(fn -> mcp_request(request, opts) end))

      {:error, _} ->
        json(conn, 400, %{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{"code" => -32700, "message" => "Parse error"}
        })
    end
  end

  defp mcp_request(request, opts) do
    state = mcp_state(opts)
    BeamLisp.RT.invoke(BeamLisp.Env.fetch!("mcp.server", "request-response"), [state, request])
  rescue
    e ->
      %{
        "jsonrpc" => "2.0",
        "id" => Map.get(request, "id"),
        "error" => %{"code" => -32603, "message" => "Internal error: #{Exception.message(e)}"}
      }
  end

  defp mcp_state(opts) do
    key = {__MODULE__, :mcp_state, Keyword.get(opts, :tree_id, "default")}

    case :persistent_term.get(key, nil) do
      nil ->
        BeamLisp.Loader.ensure_loaded("mcp.server")
        state = BeamLisp.RT.invoke(BeamLisp.Env.fetch!("mcp.server", "state"), [])
        :persistent_term.put(key, state)
        state

      state ->
        state
    end
  end

  # --- helpers ---

  defp conn_opts(opts), do: Keyword.take(opts, [:status_fun, :tree_id])

  defp ports_json do
    # One lookup and one probe for the whole table, for the reason the
    # read-model resolves it once: the live facts cost a runtime-dir read and a
    # port-80 probe, and a table of N names should not pay that N times.
    live = Gateway.live()

    Enum.map(Ports.list(), fn p ->
      hosts = Map.get(p, :hosts, [])

      url =
        if hosts == [] do
          "http://127.0.0.1:#{p.port}/"
        else
          Gateway.url(hd(hosts), live.port, live.fronted)
        end

      %{
        "name" => p.name,
        "port" => p.port,
        "hosts" => hosts,
        "url" => url,
        "tree" => p.tree_id,
        "root" => p.root,
        "pid" => p.pid,
        "claimed_at" => p.claimed_at
      }
    end)
  end

  defp json(conn, code, value) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(code, Jason.encode!(value))
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"error" => "not found", "path" => conn.request_path}))
  end

  defp decode(body) do
    {:ok, Jason.decode!(body)}
  rescue
    _ -> {:error, :bad_json}
  end

  defp uptime(ms) when is_integer(ms) do
    s = div(ms, 1000)
    if s < 60, do: "#{s}s", else: "#{div(s, 60)}m #{rem(s, 60)}s"
  end

  defp uptime(_), do: "?"

  defp short(nil), do: "(none)"

  defp short(key) when is_binary(key) do
    if byte_size(key) > 16, do: binary_part(key, 0, 16) <> "…", else: key
  end

  defp js_token(opts), do: Jason.encode!(session_token(opts))

  defp esc(nil), do: ""

  defp esc(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
