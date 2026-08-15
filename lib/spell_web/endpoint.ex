defmodule SpellWeb.BundlePlug do
  @moduledoc """
  Serve the compiled Spacetime bundle out of the live driver's output directory.

  Not `Plug.Static`: that takes its root when the plug is initialised, and this
  root is application configuration a script may set at boot (`--out`), so a
  compile-time capture would serve a directory the run is not writing to. The
  cost of reading it per request is one `Application.get_env`; the cost of
  getting it wrong is a browser holding a bundle from a previous run, which is
  precisely the class of confusion `scripts/serve_chat.sh` refuses ports over.

  Scope: `/spacetime/**` only, GET/HEAD only, and the joined path must stay
  inside the configured root — `Path.safe_relative/1` refuses `..` rather than
  trusting the request.
  """

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["spacetime" | rest], method: method} = conn, _opts)
      when method in ["GET", "HEAD"] do
    root = Application.get_env(:beam_lisp, :spell_static_dir, "/tmp/chat-serve")

    case Path.safe_relative(Path.join(rest)) do
      {:ok, safe} ->
        path = Path.join(root, safe)

        if File.regular?(path) do
          conn
          |> put_resp_content_type(MIME.from_path(path))
          # The bundle is rewritten on every accepted definition, so a cached
          # copy would show the machine as it was. No-store rather than a
          # revalidation header: the whole point of the loop is that the page
          # the browser holds is stale the moment the machine grows.
          |> put_resp_header("cache-control", "no-store")
          |> send_file(200, path)
          |> halt()
        else
          conn
          |> send_resp(404, "no such bundle file: #{safe} (looked in #{root})")
          |> halt()
        end

      _ ->
        conn |> send_resp(400, "unsafe path") |> halt()
    end
  end

  def call(conn, _opts), do: conn
end

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
    * `/spacetime/*`            — the compiled bundle (see `SpellWeb.BundlePlug`)
    * `/assets/js/*`            — the bridge hook
    * `/assets/phoenix*/…`      — the client JS, straight from the deps
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

  plug(SpellWeb.BundlePlug)

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
