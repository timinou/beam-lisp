# data.pulse — watch your program's living state breathe

Every atom, delay, derived, memoize, and lazy sequence in a BeamLisp program is
one native cell. Those cells are the program's *living state* — the values that
change, remember, and relate. `pulse` makes them visible: a live dashboard,
served into any app in dev mode with one line, that shows the cells breathing in
real time.

There are two truths it shows, and it is honest about which is which:

- **The native vitals.** The runtime knows, exactly, how many cells are alive,
  how many bytes they retain, and how many are pending reclaim. This is ground
  truth from the garbage collector, not an estimate.
- **The labelled registry.** The language layer can *annotate* a cell with a
  kind and a name when it is created (`track`). That gives the rich, per-cell,
  named view — but only for cells that opted in. Pulse never pretends a cell it
  was not told about is one it knows; the registry is a superset lens, the
  vitals are the floor.

```beam-lisp
(ns data.pulse
  (:require [interop]))
```

## The registry: cells that introduce themselves

A cell can announce itself with `track`: its kind (`:atom`, `:derived`,
`:delay`, `:vault`, …), a human name, and a zero-arg reader that returns a
snapshot of its current value. The registry is itself an atom — the observer is
made of the thing it observes, which is exactly right.

```beam-lisp
(def ^:private registry (atom {}))
(def ^:private next-id (atom 0))

(defn track
  "Register a cell for the dashboard. `kind` is a keyword, `name` a label,
   `reader` a zero-arg fn returning a snapshot of the cell's value. Returns an
   id you can pass to `untrack`. A cell that never calls track still counts in
   the native vitals; it simply has no labelled row."
  [kind name reader]
  (let [id (swap! next-id inc)]
    (swap! registry assoc id {:id id :kind kind :name name :reader reader
                              :born (System/system_time :millisecond)})
    id))

(defn untrack
  "Drop a tracked cell from the dashboard (e.g. when it is retired)."
  [id]
  (swap! registry dissoc id))

(defn tracked
  "Every tracked cell as a snapshot map: id, kind, name, age-ms, and value.
   A reader that throws is reported as :unreadable rather than crashing the
   dashboard \u2014 observation must never perturb what it observes."
  []
  (let [now (System/system_time :millisecond)]
    (mapv (fn [entry]
            {:id (:id entry)
             :kind (:kind entry)
             :name (:name entry)
             :age-ms (- now (:born entry))
             :value (try (pr-str ((:reader entry))) (catch _ ":unreadable"))})
          (vals @registry))))
```

## The vitals: ground truth from the runtime

`vitals` reads the native aggregate directly. `live-cells` is every cell the VM
holds, including the thousands the compiler churns; `retained-bytes` is the
live-term estimate; `pending` is cells awaiting off-scheduler reclaim. A
`by-kind` histogram summarizes the registry so you can see the *shape* of your
state at a glance.

```beam-lisp
(defn vitals
  "The native cell aggregate: total live cells, retained bytes, pending
   reclaims. Ground truth, straight from the runtime."
  []
  (let [s (BeamLisp.LazyMemo/stats)]
    {:live-cells (get s :live_cells)
     :retained-bytes (get s :retained_bytes)
     :pending (get s :pending_reclaims)
     :tracked (count @registry)}))

(defn by-kind
  "How many tracked cells of each kind \u2014 the shape of your labelled state."
  []
  (reduce (fn [acc entry]
            (update acc (:kind entry) (fn [n] (+ 1 (or n 0)))))
          {}
          (vals @registry)))

(defn snapshot
  "One complete frame for the dashboard: vitals, kind histogram, and every
   tracked cell. This is the payload the websocket ships each tick."
  []
  {:vitals (vitals)
   :by-kind (by-kind)
   :cells (tracked)
   :at (System/system_time :millisecond)})
```

## The dashboard: bold, dark, alive

The page is deliberately unlike the rest of the stack — a dark instrument panel,
not a document. Big luminous vitals across the top, a kind histogram, and a live
table of cells that pulses as values change. It is one self-contained HTML
string with inline CSS and a tiny websocket client; no build step, no assets.

```beam-lisp
(defn- page []
  (str "<!doctype html><html><head><meta charset=utf-8>"
       "<title>pulse</title><style>" (css) "</style></head>"
       "<body><div id=app>"
       "<header><h1>pulse</h1><span id=conn class=off>connecting</span></header>"
       "<section id=vitals></section>"
       "<section id=kinds></section>"
       "<main><table id=cells><thead><tr>"
       "<th>id</th><th>kind</th><th>name</th><th>age</th><th>value</th>"
       "</tr></thead><tbody></tbody></table></main>"
       "</div><script>" (client-js) "</script></body></html>"))

(defn- css []
  (str
   ":root{--bg:#0a0e14;--panel:#121821;--ink:#e6edf3;--dim:#7d8590;"
   "--hot:#ff5c8a;--cool:#39d0d8;--gold:#ffd166;--line:#1f2733}"
   "*{box-sizing:border-box;margin:0}"
   "body{background:var(--bg);color:var(--ink);"
   "font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}"
   "#app{max-width:1100px;margin:0 auto;padding:24px}"
   "header{display:flex;align-items:baseline;gap:16px;margin-bottom:24px}"
   "h1{font-size:28px;letter-spacing:.3em;text-transform:uppercase;"
   "background:linear-gradient(90deg,var(--hot),var(--cool),var(--gold));"
   "-webkit-background-clip:text;background-clip:text;color:transparent}"
   "#conn{font-size:11px;padding:2px 8px;border-radius:99px;text-transform:uppercase;letter-spacing:.1em}"
   "#conn.on{background:rgba(57,208,216,.15);color:var(--cool)}"
   "#conn.off{background:rgba(255,92,138,.15);color:var(--hot)}"
   "#vitals{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-bottom:20px}"
   ".vital{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px 18px}"
   ".vital .n{font-size:32px;font-weight:700;font-variant-numeric:tabular-nums}"
   ".vital .l{font-size:11px;color:var(--dim);text-transform:uppercase;letter-spacing:.15em;margin-top:4px}"
   ".vital.pulse .n{animation:flash .4s ease}"
   "@keyframes flash{0%{color:var(--gold)}100%{color:var(--ink)}}"
   "#kinds{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:20px}"
   ".kind{background:var(--panel);border:1px solid var(--line);border-radius:99px;"
   "padding:4px 12px;font-size:12px}.kind b{color:var(--cool)}"
   "table{width:100%;border-collapse:collapse;background:var(--panel);"
   "border:1px solid var(--line);border-radius:12px;overflow:hidden}"
   "th{text-align:left;padding:10px 14px;font-size:11px;color:var(--dim);"
   "text-transform:uppercase;letter-spacing:.1em;border-bottom:1px solid var(--line)}"
   "td{padding:10px 14px;border-bottom:1px solid var(--line);vertical-align:top}"
   "tr:last-child td{border-bottom:0}"
   "td.k{color:var(--gold)}td.v{color:var(--dim);max-width:420px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}"
   "tr.changed td.v{color:var(--cool)}"))

(defn- client-js []
  (str
   "const $=s=>document.querySelector(s);"
   "let last={};"
   "function fmtBytes(b){if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';return (b/1048576).toFixed(1)+' MB'}"
   "function vital(n,l,id){return `<div class=vital id=${id}><div class=n>${n}</div><div class=l>${l}</div></div>`}"
   "function render(s){"
   "$('#vitals').innerHTML="
   "vital(s.vitals['live-cells'],'live cells','v-live')+"
   "vital(fmtBytes(s.vitals['retained-bytes']),'retained','v-bytes')+"
   "vital(s.vitals['pending'],'pending','v-pend')+"
   "vital(s.vitals['tracked'],'tracked','v-track');"
   "$('#kinds').innerHTML=Object.entries(s['by-kind']||{}).map(([k,n])=>`<span class=kind>${k} <b>${n}</b></span>`).join('')||'<span class=kind>no tracked cells</span>';"
   "const tb=$('#cells tbody');tb.innerHTML=(s.cells||[]).map(c=>{"
   "const ch=last[c.id]!==undefined&&last[c.id]!==c.value;last[c.id]=c.value;"
   "return `<tr class=${ch?'changed':''}><td>${c.id}</td><td class=k>${c.kind}</td><td>${c.name}</td><td>${(c['age-ms']/1000).toFixed(1)}s</td><td class=v>${c.value}</td></tr>`"
   "}).join('');"
   "}"
   "function connect(){"
   "const ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+location.pathname.replace(/\\/$/,'')+'/ws');"
   "ws.onopen=()=>{$('#conn').className='on';$('#conn').textContent='live'};"
   "ws.onclose=()=>{$('#conn').className='off';$('#conn').textContent='reconnecting';setTimeout(connect,1000)};"
   "ws.onmessage=e=>render(JSON.parse(e.data));"
   "}connect();"))
```

## Serving it: one line in dev

`routes` returns the two handlers a host app plugs into its router: the page and
the websocket. The websocket pushes a fresh `snapshot` on a timer so the panel
is always current. In a host app you add these to your existing `web/route`.

```beam-lisp
(defn- ws-init [_state]
  ; push one frame immediately so a fresh tab is never blank, then tick.
  (send-self-tick!)
  [:push (list (list :text (encode-frame))) {}])

(defn- encode-frame []
  ; deep-convert bl collections (vectors, keyword maps) so Jason can encode
  ; them — the same seam every bl JSON endpoint uses.
  (Jason/encode! (interop/jsonable (snapshot))))

(defn- send-self-tick! []
  ; a real host schedules :timer/send_interval; the tick handler repushes.
  (erlang/send_after 500 (erlang/self) [:pulse/tick]))

(defn- ws-info [msg state]
  (if (and (sequential? msg) (= :pulse/tick (first msg)))
    (do (send-self-tick!)
        [:push (list (list :text (encode-frame))) state])
    [:ok state]))

(def ws-handlers
  {:init ws-init
   :handle-in (fn [_frame state] [:ok state])
   :handle-info ws-info})

(defn mount
  "Return the two pieces a host app wires into its own router: the dashboard
   HTML and the websocket handler map. The host owns the web layer — pulse
   hands it content, never installs itself. In dev mode:

     (ns myapp (:require [web] [data.pulse :as pulse]))
     (def dash (pulse/mount))
     (defn router [conn]
       (web/route conn
         [:get \"/__pulse\"]    (web/html conn (:page-html dash))
         [:get \"/__pulse/ws\"] (web/upgrade conn (:ws-handlers dash) nil)
         :else (web/text conn 404 \"not found\")))

   Because the host calls its OWN `web/*` (already required), pulse needs no
   web dependency and stays a pure content provider."
  []
  {:page-html (page)
   :ws-handlers ws-handlers})
```

## What is honest here, and what is bold

**Bold:** any app gets a live, visual instrument panel of its state with two
route lines; the dashboard departs entirely from the document-like look of the
rest of the stack; and the registry lets you *name* your cells so the panel
reads like your domain, not like memory addresses.

**Honest:** the native layer reports an *aggregate* — it does not enumerate
individual cells, so the labelled table shows exactly the cells that called
`track`, never a fabricated per-cell list. The vitals are the floor of truth;
the registry is the lens you choose to add. Observation is careful never to
perturb: a reader that throws is reported, not propagated, so watching the
program can never change how it runs.
