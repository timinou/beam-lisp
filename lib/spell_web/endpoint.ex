defmodule SpellWeb.Endpoint do
  @moduledoc """
  The app's own HTTP endpoint — the thing that made the two-step serve
  unnecessary.

  Before this, `scripts/serve_chat.sh` emitted the page, built the bundle and
  then handed the directory to `python3 -m http.server`, because nothing in this
  app served HTTP. The bundle needs an origin (a `file://` page cannot load a
  module bundle), and the seam needs a socket — this endpoint is both, in the
  same BEAM node as the machine, the driver and the provider.

  Served surfaces:

    * `/`                       — the LiveView the contract generated
    * `/live/websocket`         — its channel; the seam's transport
    * `/assets/js/*`            — the bridge hook
    * `/assets/phoenix*/…`      — the client JS, straight from the deps

  The compiled bundle is NOT here: `spacetime serve` owns it (see
  `Spell.Build`/`Spell.Serve`), on its own loopback origin.
  """

  use Phoenix.Endpoint, otp_app: :beam_lisp

  @session_options [
    store: :cookie,
    key: "_spell_key",
    signing_salt: "gT4kQ9xZ",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  # The client JS ships PREBUILT inside the deps (`priv/static/phoenix.js`,
  # `priv/static/phoenix_live_view.js`), so this app needs no npm, no esbuild
  # and no vendored copies that can drift from the library version in mix.lock.
  # Tidewave: MCP access to THIS running image — an agent (or a human with
  # `mcp-remote`) can project_eval against the live loop, which is exactly
  # how the loop's own behaviour gets exercised end-to-end. Dev-only dep.
  if Code.ensure_loaded?(Tidewave) do
    plug(Tidewave)
  end

  # The model's face: the loop as an MCP server at /spell/mcp. An external
  # model client drives the machine through `run`/`state`/`transcript` —
  # the ONLY write path is the ladder, there is no eval here.
  plug(BeamLisp.Spell.Mcp)

  plug(Plug.Static, at: "/assets/phoenix", from: {:phoenix, "priv/static"}, gzip: false)

  plug(Plug.Static,
    at: "/assets/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false
  )

  # The bridge hook, from the library that defines it. The `.global.js` build is
  # the one to serve here: this app has no bundler, and in a plain <script> the
  # ESM `export` keyword is a syntax error that kills the whole file — which
  # presents as a page that hydrates and then answers no signal.
  plug(Plug.Static,
    at: "/assets/js",
    from: {:spacetime_phoenix, "priv/static/js"},
    gzip: false
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: JSON
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(SpellWeb.Router)
end
