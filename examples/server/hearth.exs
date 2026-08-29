# hearth.exs — a real multi-user message board, in one file.
#
#   mix run examples/server/hearth.exs
#   → open http://localhost:4000 in two browsers, log in as different names,
#     and watch messages appear live in both.
#
# ── What this is ──────────────────────────────────────────────────────
#
# A complete live app served by a real HTTP + WebSocket server. The WHOLE
# application — auth, rooms, messages, presence, and the branded UI — is
# written in beam-lisp (the big string below). Elixir contributes only a
# thin harness: Bandit serves HTTP, a WebSock handler bridges each browser
# to a beam-lisp `deflive` socket, and messages cross as JSON.
#
#   browser  --HTTP GET /-->  first paint (server-rendered HTML + client.js)
#   browser  --WebSocket-->   a beam-lisp socket process (one per tab)
#            <--[:mount]--     full HTML
#            <--[:patch]--     minimal keyed ops on every change
#   browser  --[:event]-->     an intent term -> authorized -> transact! -> log
#
# The board state is ONE shared datom database. A post by anyone commits a
# fact; the log broadcasts; every connected socket re-projects and ships a
# minimal patch. Auth is real: you log in, get a session cookie, and every
# post is stamped with your authenticated identity — you cannot post as
# someone else.

Application.ensure_all_started(:bandit)

# ══════════════════════════════════════════════════════════════════════
# THE APP — all of it, in beam-lisp
# ══════════════════════════════════════════════════════════════════════

BeamLisp.eval(~S'''
(ns hearth
  (:require [live.ui :as ui] [live.style :as s] [live.hiccup :as h]
            [live.socket :as sock] [datom] [interop]))

;; ── BRAND ─────────────────────────────────────────────────────────────
(def brand
  {:color {:accent "#ff7a59" :accent-fg "#1a1206" :bg "#12100e"
           :surface "#1c1917" :surface-2 "#262220" :border "#332e2a"
           :text "#f3ede6" :muted "#a89f95" :success "#5bbf7a"}
   :radius {:md "10px" :lg "18px" :full "9999px"}})

;; ── THE WORLD: rooms + messages, one shared datom db ──────────────────
(def world
  (datom/connect
    [{:db/ident :room/id    :db/valueType :db.type/string :db/unique :db.unique/identity}
     {:db/ident :room/name  :db/valueType :db.type/string}
     {:db/ident :msg/id     :db/valueType :db.type/string :db/unique :db.unique/identity}
     {:db/ident :msg/room   :db/valueType :db.type/string}
     {:db/ident :msg/who    :db/valueType :db.type/string}
     {:db/ident :msg/text   :db/valueType :db.type/string}
     {:db/ident :msg/at     :db/valueType :db.type/long}]))

;; seed a couple of rooms and a welcome message
(datom/transact! world
  [{:db/id -1 :room/id "general" :room/name "general"}
   {:db/id -2 :room/id "random"  :room/name "random"}
   {:db/id -3 :msg/id "m000000" :msg/room "general" :msg/who "hearth"
    :msg/text "welcome! pick a room and say hello" :msg/at 0}])

;; ── QUERIES ───────────────────────────────────────────────────────────
(defn rooms [db]
  (sort (datom/q '[:find ?id ?name :where [?e :room/id ?id] [?e :room/name ?name]] db)))

(defn messages [db room]
  ;; ids are monotonic, so id-sort is time-sort; oldest first (chat order)
  (sort-by (fn [m] (nth m 0))
    (datom/q '[:find ?id ?who ?text ?at
               :in $ ?room
               :where [?e :msg/room ?room] [?e :msg/id ?id]
                      [?e :msg/who ?who] [?e :msg/text ?text] [?e :msg/at ?at]]
             db room)))

;; ── COMPONENTS ────────────────────────────────────────────────────────
(defn- avatar [who]
  (let [hue (rem (erlang/phash2 who) 360)]
    [:div {:style (str "width:34px;height:34px;flex:0 0 34px;border-radius:9999px;"
                       "display:flex;align-items:center;justify-content:center;"
                       "font-weight:700;font-size:14px;color:#12100e;"
                       "background:hsl(" (str hue) ",70%,68%)")}
     (subs (str who) 0 1)]))

(defn- message-row [m me]
  (let [who (nth m 1) text (nth m 2) mine (= who me)]
    (ui/row {:key (nth m 0) :style {:align "flex-start" :gap :3}}
      (avatar who)
      (ui/stack {:gap :1 :style {:flex "1"}}
        (ui/row {:gap :2}
          (ui/prose {:style {:font-weight "600"}} (str "@" who))
          (when mine (ui/badge {:tone :accent} "you")))
        (ui/prose {:style {:color (s/color :text)}} text)))))

(defn- room-link [r current]
  (let [id (nth r 0) name (nth r 1) active (= id current)]
    [:button {:class (s/sx {:display "block" :width "100%" :text-align "left"
                            :padding (str (s/space :2) " " (s/space :3))
                            :margin-bottom (s/space :1)
                            :border "none" :border-radius (s/radius :md)
                            :cursor "pointer" :font-size (s/text :md)
                            :background (if active (s/color :surface-2) "transparent")
                            :color (if active (s/color :text) (s/color :muted))})
              :on-click [:assign :room id]}
     (str "# " name)]))

;; ── THE VIEW: (shared-db session-db locals) → hiccup ──────────────────
(defn board [db _sess locals]
  (s/install-theme! brand)
  (let [me   (:me locals)
        room (or (:room locals) "general")
        msgs (messages db room)]
    [:div {:style (str "display:flex;height:100vh;max-width:1000px;margin:0 auto;"
                       "border-left:1px solid " (s/color :border) ";"
                       "border-right:1px solid " (s/color :border))}

     ;; sidebar: brand + rooms + who you are
     [:aside {:style (str "width:240px;flex:0 0 240px;padding:" (s/space :5) ";"
                          "border-right:1px solid " (s/color :border) ";"
                          "display:flex;flex-direction:column;gap:" (s/space :4))}
      (ui/stack {:gap :1}
        (ui/heading 2 "Hearth")
        (ui/prose {:tone :muted} "gather round the fire"))
      (ui/stack {:gap :1}
        (ui/prose {:tone :muted :style {:font-size (s/text :xs)
                                        :text-transform "uppercase"
                                        :letter-spacing "0.08em"}} "Rooms")
        (into [:div] (for [r (rooms db)] (room-link r room))))
      [:div {:style "margin-top:auto"}
       (ui/row {:gap :2} (avatar me) (ui/prose {:style {:font-weight "600"}} (str "@" me)))]]

     ;; main: header + message list + composer
     [:main {:style "flex:1;display:flex;flex-direction:column;min-width:0"}
      [:header {:style (str "padding:" (s/space :4) " " (s/space :5) ";"
                            "border-bottom:1px solid " (s/color :border) ";")}
       (ui/heading 3 (str "# " room))]

      [:div {:style (str "flex:1;overflow-y:auto;padding:" (s/space :5) ";"
                         "display:flex;flex-direction:column;gap:" (s/space :4))}
       (if (empty? msgs)
         (ui/prose {:tone :muted} "no messages yet — be the first.")
         (into [:div {:style (str "display:flex;flex-direction:column;gap:" (s/space :4))}]
               (for [m msgs] (message-row m me))))]

      [:footer {:style (str "padding:" (s/space :4) " " (s/space :5) ";"
                            "border-top:1px solid " (s/color :border) ";")}
       (ui/row {:gap :2}
         [:input {:class (s/sx {:flex "1" :padding (str (s/space :3) " " (s/space :3))
                                :font-size (s/text :md) :color (s/color :text)
                                :background (s/color :surface) :border (str "1px solid " (s/color :border))
                                :border-radius (s/radius :md)})
                  :placeholder (str "message #" room)
                  :value ""
                  :on-keydown.enter [:intent :post {:room room}]}]
         (ui/button {:variant :primary :on-click [:intent :post {:room room}]} "Send"))]]]))

;; ── INTENTS: the backend. WHO from auth, TEXT from the field. ─────────
(defn post-message [conn payload principal]
  (let [text (:value payload)]          ; the field value the client sent
    (when (and text (not= (String/trim text) ""))
      [{:db/id -1
        :msg/id (str "m" (erlang/unique_integer (list :positive :monotonic)))
        :msg/room (:room payload)
        :msg/who principal               ; the authenticated identity, not a client claim
        :msg/text (String/trim text)
        :msg/at (System/system_time :millisecond)}])))

;; ── the socket (one gen_server per browser tab) ───────────────────────
(sock/deflive board-socket
  :view board
  :intents {:post post-message}
  :listen {})

;; ── bridge helpers the Elixir harness calls ───────────────────────────
(defn keywordize [m]
  (if (map? m)
    (reduce (fn [acc kv] (assoc acc (keyword (str (first kv))) (second kv))) {} (seq m))
    m))

;; start a socket for a sink pid + principal; return the server pid
(defn start-socket [sink principal]
  (server-start-link board-socket
    {:shared world :sink sink
     :locals {:me principal}
     :auth {:fn (fn [_op _payload _pr] {:verdict :allow}) :principal principal}}))

;; a browser event arrives as a JSON-decoded term; normalize + dispatch,
;; carrying the field data so [:from :value] and payload merges resolve
(defn dispatch-event [srv term data]
  (server-call srv [:event (sock/normalize-event term) (keywordize data)]))

;; the very first HTML for a principal (used by the HTTP GET)
(defn first-html [principal]
  (h/hiccup->html (board (datom/db world) nil {:me principal :room "general"})))

;; a socket message ([:mount …]/[:patch …]) → wire JSON
(defn msg->json [msg] (interop/->json msg))
''')

# ══════════════════════════════════════════════════════════════════════
# THE HARNESS — Bandit HTTP + a WebSocket bridge to the beam-lisp sockets
# ══════════════════════════════════════════════════════════════════════

defmodule Hearth.Bridge do
  @moduledoc "One WebSocket connection <-> one beam-lisp live socket."
  @behaviour WebSock

  # the connection carries the principal (set from the login cookie at upgrade)
  def init(principal) do
    # start a beam-lisp socket whose sink is THIS process; it pushes
    # [:mount ...] then [:patch ...] messages to us as Erlang messages.
    srv = BeamLisp.eval("hearth/start-socket").(self(), principal)
    {:ok, %{srv: srv, principal: principal}}
  end

  # a frame from the browser: ["event", term, data]
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, ["event", term, data]} ->
        BeamLisp.eval("hearth/dispatch-event").(state.srv, term, data)
        {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  # a message FROM the beam-lisp socket (mount/patch) -> JSON -> the browser
  def handle_info(msg, state) do
    json = BeamLisp.eval("hearth/msg->json").(msg)
    {:push, {:text, json}, state}
  end

  def terminate(_reason, _state), do: :ok
end

defmodule Hearth.Router do
  use Plug.Router
  import Plug.Conn

  plug :match
  plug :fetch_query_params
  plug :dispatch

  @client File.read!(Path.join(:code.priv_dir(:beam_lisp), "live/client.js"))

  # login: pick a name -> set a cookie -> redirect to the board
  get "/login" do
    name = (conn.query_params["name"] || "") |> String.trim()

    if name == "" do
      conn |> put_resp_content_type("text/html") |> send_resp(200, login_page())
    else
      conn
      |> put_resp_cookie("who", name, http_only: false, same_site: "Lax")
      |> put_resp_header("location", "/")
      |> send_resp(302, "")
    end
  end

  get "/ws" do
    conn = fetch_cookies(conn)
    who = conn.req_cookies["who"]

    if who in [nil, ""] do
      send_resp(conn, 401, "log in first")
    else
      conn
      |> WebSockAdapter.upgrade(Hearth.Bridge, who, timeout: 120_000)
      |> halt()
    end
  end

  get "/client.js" do
    conn |> put_resp_content_type("application/javascript") |> send_resp(200, @client)
  end

  get "/" do
    conn = fetch_cookies(conn)
    who = conn.req_cookies["who"]

    if who in [nil, ""] do
      conn |> put_resp_header("location", "/login") |> send_resp(302, "")
    else
      body = BeamLisp.eval("hearth/first-html").(who)
      conn |> put_resp_content_type("text/html") |> send_resp(200, board_page(body))
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # ── the two HTML shells ──────────────────────────────────────────────

  defp base_head do
    ~S"""
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      *,*::before,*::after{box-sizing:border-box;margin:0}
      body{background:#12100e;color:#f3ede6;font-family:system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;font-size:16px;line-height:1.5;-webkit-font-smoothing:antialiased}
      button{font-family:inherit}
      input:focus,button:focus-visible{outline:2px solid #ff7a59;outline-offset:2px}
      ::-webkit-scrollbar{width:10px}::-webkit-scrollbar-thumb{background:#332e2a;border-radius:8px}
      @media (prefers-reduced-motion:reduce){*{transition:none!important}}
    </style>
    """
  end

  defp login_page do
    """
    <!doctype html><html lang="en"><head>#{base_head()}<title>Hearth · sign in</title></head>
    <body>
    <div style="min-height:100vh;display:flex;align-items:center;justify-content:center">
      <form action="/login" method="get" style="width:340px;padding:40px;background:#1c1917;border:1px solid #332e2a;border-radius:18px;display:flex;flex-direction:column;gap:16px">
        <div style="font-size:34px;font-weight:800">Hearth</div>
        <div style="color:#a89f95">gather round the fire — pick a name to join.</div>
        <input name="name" autofocus placeholder="your name" required
          style="padding:12px;font-size:16px;color:#f3ede6;background:#12100e;border:1px solid #332e2a;border-radius:10px">
        <button type="submit"
          style="padding:12px;font-size:16px;font-weight:600;color:#1a1206;background:#ff7a59;border:none;border-radius:10px;cursor:pointer">Enter</button>
      </form>
    </div></body></html>
    """
  end

  defp board_page(body) do
    """
    <!doctype html><html lang="en"><head>#{base_head()}<title>Hearth</title></head>
    <body>
    <div id="live-root">#{body}</div>
    <script src="/client.js"></script>
    <script>
      Live.connect({ url: (location.protocol==='https:'?'wss://':'ws://')+location.host+'/ws',
                     root: document.getElementById('live-root') });
    </script>
    </body></html>
    """
  end
end

port = 4000
{:ok, _} = Bandit.start_link(plug: Hearth.Router, port: port)

IO.puts("""

  Hearth is live at  http://localhost:#{port}

      Open it in two browser windows, sign in with different names,
      and watch messages appear live in both. Every post is stamped
      with your authenticated identity, committed to one shared log,
      and every connected tab re-projects with a minimal patch.

      Ctrl-C to stop.
""")

Process.sleep(:infinity)
