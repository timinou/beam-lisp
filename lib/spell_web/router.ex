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
          // THE PAGE REBUILDS ITSELF WHEN THE MACHINE GROWS.
          //
          // An accepted definition re-emits the page, rebuilds the bundle and
          // bumps a version in `report.json`. Without this poll the browser
          // keeps running the bundle it loaded: the model says "✓ defined view
          // clock", the machine really did grow, and the page shows no clock
          // — which reads as the definition having done nothing.
          //
          // Polling the VERSION rather than the bundle's Last-Modified: the
          // build is not byte-stable across runs (timestamps move), so the
          // bundle would reload the page on every emit, while the version only
          // moves when the machine did.
          //
          // Cache-busted because a 304 would freeze the version at whatever
          // the browser first saw. `no-store` is set server-side too; both,
          // because either alone has been observed to lose this race.
          (function () {
            var seen = null;
            setInterval(function () {
              fetch("/spacetime/report.json?t=" + Date.now(), { cache: "no-store" })
                .then(function (r) { return r.ok ? r.json() : null; })
                .then(function (report) {
                  if (!report) return;
                  // The FIRST reading establishes the baseline. Reloading on
                  // it would reload every fresh tab exactly once, which looks
                  // like a flicker nobody can explain.
                  if (seen === null) { seen = report.version; return; }
                  if (report.version !== seen) location.reload();
                })
                .catch(function () {});
            }, 1000);
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
