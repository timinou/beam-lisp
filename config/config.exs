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
  # A websocket origin is compared by SPELLING, not by resolved address, so a
  # bare `url: [host: "127.0.0.1"]` REFUSES a browser sitting on
  # `http://localhost:4030` — the same machine, the same port, the same
  # loopback interface, a different string. The refusal surfaces only in the
  # browser console, as `view crashed - {source: "transport", reason:
  # "connection_error"}` repeating forever while LiveView retries (observed at
  # 4072 mount attempts). The page still RENDERS, because the initial HTML is
  # an ordinary GET — only the live channel dies, so the composer accepts text
  # and nothing ever happens. Nothing in the server log names the browser's
  # spelling unless you read the `Could not check origin` block.
  #
  # Both spellings are listed rather than `check_origin: false`: the latter
  # accepts ANY origin, which is a CSWSH hole the moment this binds to
  # anything but loopback, and it would hide a genuinely wrong host later.
  check_origin: [
    "http://127.0.0.1:#{System.get_env("PORT") || "4030"}",
    "http://localhost:#{System.get_env("PORT") || "4030"}",
    # Some browser profiles reach loopback as `console.localhost` — the same
    # machine, a third spelling, refused without this line exactly as above.
    "http://console.localhost:#{System.get_env("PORT") || "4030"}"
  ],
  secret_key_base: "Q6fe7LbG6KXu2sW8/hojavutCZwUqj8ubdwEVtNgCgGqPuBEge3T0fmkUO5fEx0j",
  render_errors: [formats: [html: SpellWeb.ErrorHTML], layout: false],
  pubsub_server: SpellWeb.PubSub,
  live_view: [signing_salt: "O+w+LiUZ8h0="]

# The served site: the page (`index.edn`) the loop publishes and verse's
# `build-status.json` verdicts land here. PROJECT-LOCAL — the machine's
# growth is part of the project, not /tmp. `spacetime serve` watches this
# directory; the Phoenix endpoint serves only the shell and the channel.
config :beam_lisp, :spell_site_dir, "spell/ui"

# The verse dev server's loopback port. The browser loads the compiled bundle
# and stylesheet from this origin; the shell's reload script connects to its
# websocket. Both are plain loopback HTTP, no proxy. `VERSE_PORT` overrides,
# like `PORT` above: two beam-lisp projects on one machine otherwise fight
# for 4444, and the loser serves ANOTHER project's index.edn without a
# complaint — observed live as this shell's page loading an empty runtime
# ("No .st file found at …/fundamental_phone/spell/ui/index.edn").
config :beam_lisp, :spell_verse_port, String.to_integer(System.get_env("VERSE_PORT") || "4444")
