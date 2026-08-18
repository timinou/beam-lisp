defmodule SpellWeb.ErrorHTML do
  @moduledoc "The smallest honest error page: the status, as text."
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule SpellWeb.Layouts do
  @moduledoc """
  The root layout: everything the compiled page needs to reach its server.

  Three scripts, in order, and the order is load-bearing:

    1. `phoenix.js`            — the channel client
    2. `phoenix_live_view.js`  — `LiveSocket`, which owns the connection
    3. `spacetime_bridge.js`   — the `SpacetimeBridge` hook + `liveSocket.connect()`

  All three are plain scripts (not modules) so they attach their globals before
  the bundle — which IS a module, and therefore deferred — starts looking for
  `window.__stLiveBridge`.
  """
  use Phoenix.Component

  def render("root.html", assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>spell</title>
        <style>
          html, body { margin: 0; background: #0b0d14; color: #e8eaf2;
            font: 16px/1.5 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif; }
        </style>
        <script src="/assets/phoenix/phoenix.js">
        </script>
        <script src="/assets/phoenix_live_view/phoenix_live_view.js">
        </script>
        <script src="/assets/js/spacetime_bridge.js">
        </script>
        <script>
          // THE PAGE RELOADS WHEN VERSE RECOMPILES IT.
          //
          // An accepted definition rewrites index.edn; the running
          // `spacetime serve` watches the site dir, recompiles, and announces
          // Reload on its dev websocket. This is verse's own mechanism (the
          // same message its served pages get) — there is no second reload
          // channel to disagree with it, and nothing polls.
          (function () {
            var url = "{BeamLisp.Spell.Build.ws_origin()}/ws";
            var connect = function () {
              var ws;
              try { ws = new WebSocket(url); } catch (err) { return; }
              ws.onmessage = function (e) {
                try {
                  var d = JSON.parse(e.data);
                  if (d.DevServer && d.DevServer.type === "Reload") location.reload();
                } catch (err) {}
              };
              // A dead serve (or a boot in progress) retries instead of
              // stranding the page on a stale bundle.
              ws.onclose = function () { setTimeout(connect, 2000); };
            };
            connect();
          })();
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end

defmodule SpellWeb.Router do
  @moduledoc """
  One route, because the machine has one page.

  `SpellWeb.ChatLive` is GENERATED from the contract
  (`spell.contract/elixir-module`) and compiled at boot by
  `scripts/serve_live.exs`. A placeholder module of the same name is compiled
  into the app so this router — and `mix compile` — have something to point at
  before the generator has run; the generated module replaces it in the code
  server, which is ordinary BEAM code loading and the reason this can be a
  live-updating system at all.
  """
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SpellWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SpellWeb do
    pipe_through(:browser)

    live("/", ChatLive)
  end
end
