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
  plug(Plug.Static, at: "/assets/phoenix", from: {:phoenix, "priv/static"}, gzip: false)

  plug(Plug.Static,
    at: "/assets/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false
  )

  plug(Plug.Static, at: "/assets", from: {:beam_lisp, "priv/static"}, gzip: false, only: ["js"])

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
