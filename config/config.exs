import Config

# The seam's server half runs in THIS app: the emitted page declares
# `@host $chat : live("SpellWeb.ChatLive")` and its signals ride that
# LiveView's channel. Phoenix is a library here — one app, one supervision
# tree, no second deployment.
#
# The secrets are literals rather than generated at boot on purpose: a
# per-boot secret invalidates every open session on restart, which for a page
# that reloads itself as the machine grows means a reconnect storm mid-demo.
# They are development secrets for a loopback-only endpoint; a deployment
# would read them from the environment in config/runtime.exs.
# The listener. Without an `http:` key Phoenix starts NO listener at all and
# the endpoint silently serves nothing — which cost a debugging round here:
# port 4000 answered with somebody else's Phoenix app (an unrelated project's
# server was already bound), so every static route "404ed" from a server this
# app had never started. Port 4030 is uncommon enough to be ours, loopback
# only, and `PORT` overrides it.
config :beam_lisp, SpellWeb.Endpoint,
  # Bandit, not Phoenix's default Cowboy: this app already carries Bandit (the
  # Tidewave dev endpoint runs on it) and carrying two HTTP servers to serve
  # one page is exactly the kind of parallel implementation this codebase
  # refuses. Naming the adapter is required — the default is Cowboy and the
  # failure is an UndefinedFunctionError at boot.
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4030")],
  server: true,
  url: [host: "127.0.0.1"],
  secret_key_base: "Q6fe7LbG6KXu2sW8/hojavutCZwUqj8ubdwEVtNgCgGqPuBEge3T0fmkUO5fEx0j",
  render_errors: [formats: [html: SpellWeb.ErrorHTML], layout: false],
  pubsub_server: SpellWeb.PubSub,
  live_view: [signing_salt: "O+w+LiUZ8h0="]

# Where the compiled bundle lives. The live driver writes `page.st`,
# `spacetime.js`, `spacetime.css` and `report.json` here, and the endpoint
# serves that directory at `/spacetime` — the prefix the contract's
# `:bundle` option names.
config :beam_lisp, :spell_static_dir, "/tmp/chat-serve"
