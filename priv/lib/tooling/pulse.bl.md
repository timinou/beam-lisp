# tooling.pulse — watch your program's living state breathe

`pulse` is an **instrument**, not a building block. It belongs in `tooling`: a
thing you run to look at your program, the way a mechanic runs a diagnostic, not
a part you compose into the program itself.

What it shows is the living state — every atom, delay, derived, and cache is one
native cell, and pulse reveals them. It stands on a `data` pattern rather than
re-implementing one: the roll-call of tracked cells is a `data.registry`, the
same reusable roll-call any code can use. Pulse is the instrument; the registry
is the part. Keeping them separate is the whole point of the split.

Two truths, honestly separated:

- **Native vitals** \u2014 the runtime reports, exactly, how many cells are alive,
  how many bytes they retain, how many are pending reclaim. Ground truth.
- **The tracked roll-call** \u2014 cells that opt in with `track` appear as named,
  live rows. This is a `data.registry`, so it is a superset lens over the
  vitals, never a fabricated per-cell list.

And two shapes to view it in: a **full page**, and an **expandable chip** you
can drop into the corner of any live app.

```beam-lisp
(ns tooling.pulse
  (:require [data.registry :as registry]
            [tooling.trace :as trace]
            [tooling.incremental :as inc]
            [interop]))

;; One process-wide render trace, so the dashboard can narrate updates.
(def ^:private the-trace (atom nil))

(defn- tr []
  (or @the-trace
      (let [t (trace/open)]
        (if (compare-and-set! the-trace nil t) t @the-trace))))

;; Re-exported so an app writes its view against pulse directly:
;;   (pulse/traced :label [dep] (fn [] hiccup))  — a subtree that both
;;   recomputes only on change (incremental) AND records why (trace).
(defn traced
  "An incremental, traced view subtree. Recomputes only when a dep changes,
   and records each recompute into the dashboard's render trace under `label`."
  [label deps render]
  (trace/traced (tr) label deps render))

(defn component
  "A memoised view component (tooling.incremental/component): equal inputs
   return identical hiccup, so the differ prunes the subtree."
  [render-fn]
  (inc/component render-fn))

(defn note-patch!
  "Record that the last render shipped `n` patch ops (call after diffing)."
  [n]
  (trace/note-patch! (tr) n))

(defn clear-trace!
  "Clear the render trace (call after first paint to narrate updates only)."
  []
  (trace/clear! (tr)))
```

## The roll-call is a data.registry

Pulse holds one process-wide registry. `track` enrolls a cell with its kind,
name, and a zero-arg reader; `untrack` retires it. That is all pulse adds on top
of the pattern \u2014 the roster machinery is `data.registry`, not bespoke code.

```beam-lisp
(def ^:private the-registry (atom nil))

(defn- reg []
  (or @the-registry
      (let [r (registry/open)]
        (if (compare-and-set! the-registry nil r) r @the-registry))))

(defn track
  "Register a cell for the dashboard: `kind` keyword, `name` label, `reader` a
   zero-arg fn returning a snapshot of the cell's value. Returns an id for
   `untrack`. An untracked cell still counts in the native vitals; it simply
   has no labelled row."
  [kind name reader]
  (registry/enroll (reg) kind name {:reader reader}))

(defn untrack
  "Drop a tracked cell from the dashboard."
  [id]
  (registry/retire (reg) id))
```

## Vitals and snapshot

`vitals` reads the native aggregate directly; `cells` reads each tracked entry's
current value through its reader (a throwing reader is reported, never
propagated \u2014 observation must not perturb). `snapshot` is one frame: vitals,
kind histogram, and the tracked cells.

```beam-lisp
(defn vitals
  "The native cell aggregate: live cells, retained bytes, pending reclaims,
   plus how many cells are tracked. Ground truth from the runtime."
  []
  (let [s (BeamLisp.LazyMemo/stats)]
    {:live-cells (get s :live_cells)
     :retained-bytes (get s :retained_bytes)
     :pending (get s :pending_reclaims)
     :tracked (registry/size (reg))}))

(defn cells
  "Every tracked cell as a snapshot: id, kind, name, age-ms, and value. A
   reader that throws yields :unreadable rather than crashing the frame."
  []
  (let [now (System/system_time :millisecond)]
    (mapv (fn [e]
            {:id (:id e)
             :kind (:kind e)
             :name (:name e)
             :age-ms (- now (:since e))
             :value (try (pr-str ((:reader (:meta e)))) (catch _ ":unreadable"))})
          (registry/entries (reg)))))

(defn by-kind
  "How many tracked cells of each kind."
  []
  (registry/count-by-kind (reg)))

(defn snapshot
  "One complete frame for a view: vitals, kind histogram, tracked cells, and
   the render trace — which subtrees recomputed and how many ops shipped on the
   last update, so the dashboard narrates WHY the UI changed."
  []
  (let [u (trace/last-update (tr))
        recent (->> (trace/events (tr))
                    (filter (fn [e] (= :recompute (:kind e))))
                    (mapv (fn [e] (str (:label e)))))]
    {:vitals (vitals)
     :by-kind (by-kind)
     :cells (cells)
     :trace {:recomputed recent
             :patch-ops (:patch-ops u)
             :event-count (:event-count u)}
     :at (System/system_time :millisecond)}))

(defn frame-json
  "The snapshot as a JSON string, bl collections deep-converted so Jason can
   encode them. This is what a websocket ships each tick."
  []
  (Jason/encode! (interop/jsonable (snapshot))))
```

## Shape one: the full page

The full dashboard is a dark instrument panel: a gradient wordmark, big luminous
vitals, a kind histogram, and a live table of cells. One self-contained HTML
string \u2014 no build step, no assets \u2014 fed by a websocket.

```beam-lisp
(defn- page-shell []
  (str "<!doctype html><html><head><meta charset=utf-8><title>pulse</title>"
       "<style>" (page-css) "</style></head><body><div id=app>"
       "<header><h1>pulse</h1><span id=conn class=off>connecting</span></header>"
       "<section id=vitals></section><section id=kinds></section>"
       "<section id=trace></section>"
       "<main><table id=cells><thead><tr>"
       "<th>id</th><th>kind</th><th>name</th><th>age</th><th>value</th>"
       "</tr></thead><tbody></tbody></table></main></div>"
       "<script>" (page-js) "</script></body></html>"))

(defn- page-css []
  (str
   ":root{--bg:#0a0e14;--panel:#121821;--ink:#e6edf3;--dim:#7d8590;"
   "--hot:#ff5c8a;--cool:#39d0d8;--gold:#ffd166;--line:#1f2733}"
   "*{box-sizing:border-box;margin:0}"
   "body{background:var(--bg);color:var(--ink);font:14px/1.5 ui-monospace,Menlo,monospace}"
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
   "#kinds{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:20px}"
   ".kind{background:var(--panel);border:1px solid var(--line);border-radius:99px;padding:4px 12px;font-size:12px}.kind b{color:var(--cool)}"
   "table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}"
   "th{text-align:left;padding:10px 14px;font-size:11px;color:var(--dim);text-transform:uppercase;letter-spacing:.1em;border-bottom:1px solid var(--line)}"
   "td{padding:10px 14px;border-bottom:1px solid var(--line)}tr:last-child td{border-bottom:0}"
   "td.k{color:var(--gold)}td.v{color:var(--dim);max-width:420px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}"
   "#trace{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px 18px;margin-bottom:20px;min-height:44px}"
   "#trace .tl{font-size:11px;color:var(--dim);text-transform:uppercase;letter-spacing:.15em;margin-bottom:6px}"
   "#trace .why{font-size:15px}#trace .why b{color:var(--cool)}#trace .why .op{color:var(--gold)}"
   "#trace.flash{animation:tflash .5s ease}@keyframes tflash{0%{border-color:var(--gold)}100%{border-color:var(--line)}}"))

(defn- page-js []
  (str
   "const $=s=>document.querySelector(s);"
   "function fb(b){if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';return (b/1048576).toFixed(1)+' MB'}"
   "function v(n,l){return `<div class=vital><div class=n>${n}</div><div class=l>${l}</div></div>`}"
   "function render(s){"
   "$('#vitals').innerHTML=v(s.vitals['live-cells'],'live cells')+v(fb(s.vitals['retained-bytes']),'retained')+v(s.vitals['pending'],'pending')+v(s.vitals['tracked'],'tracked');"
   "$('#kinds').innerHTML=Object.entries(s['by-kind']||{}).map(([k,n])=>`<span class=kind>${k} <b>${n}</b></span>`).join('')||'<span class=kind>no tracked cells</span>';"
   "$('#cells tbody').innerHTML=(s.cells||[]).map(c=>`<tr><td>${c.id}</td><td class=k>${c.kind}</td><td>${c.name}</td><td>${(c['age-ms']/1000).toFixed(1)}s</td><td class=v>${c.value}</td></tr>`).join('');"
   "var t=s.trace||{},rc=(t.recomputed||[]);"
   "var why=rc.length? `<span class=why>recomputed <b>${rc.join(', ')}</b> → <span class=op>${t['patch-ops']} op${t['patch-ops']===1?'':'s'}</span></span>` : '<span class=why style=color:#7d8590>idle — nothing recomputed</span>';"
   "$('#trace').innerHTML='<div class=tl>why did the ui update?</div>'+why;"
   "$('#trace').classList.remove('flash');void $('#trace').offsetWidth;if(rc.length)$('#trace').classList.add('flash');"
   "}"
   "function conn(){const ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+location.pathname.replace(/\\/$/,'')+'/ws');"
   "ws.onopen=()=>{$('#conn').className='on';$('#conn').textContent='live'};"
   "ws.onclose=()=>{$('#conn').className='off';$('#conn').textContent='reconnecting';setTimeout(conn,1000)};"
   "ws.onmessage=e=>render(JSON.parse(e.data));}conn();"))

(defn page []
  "The full dashboard HTML page. Serve it at a route; its websocket lives at
   that route + /ws."
  (page-shell))
```

## Shape two: the expandable chip

The chip is the same instrument, shrunk to a corner. Collapsed, it is a small
glowing badge showing the live-cell count. Clicked, it expands into a compact
panel with the vitals and the tracked cells. It carries its own styles and
script so it can be dropped into *any* page \u2014 a standalone HTML fragment, or
(next section) injected straight into a live app's view.

```beam-lisp
(defn chip-html
  "A self-contained expandable chip fragment: a corner badge that expands into
   a mini-panel. `endpoint` is the websocket URL it connects to for live data.
   Drop this string into any page's body."
  [endpoint]
  (str
   "<div id=pulse-chip data-ep=\"" endpoint "\"><style>" (chip-css) "</style>"
   "<button id=pc-badge><span id=pc-dot></span><span id=pc-n>\u2014</span>"
   "<span id=pc-label>cells</span></button>"
   "<div id=pc-panel hidden><div id=pc-head>pulse</div>"
   "<div id=pc-vitals></div><div id=pc-trace></div><div id=pc-cells></div></div></div>"
   "<script>" (chip-js) "</script>"))

(defn- chip-css []
  (str
   "#pulse-chip{position:fixed;right:18px;bottom:18px;z-index:2147483000;"
   "font:12px/1.4 ui-monospace,Menlo,monospace}"
   "#pc-badge{display:flex;align-items:center;gap:8px;cursor:pointer;"
   "background:#0a0e14;color:#e6edf3;border:1px solid #1f2733;border-radius:99px;"
   "padding:8px 14px;box-shadow:0 6px 24px rgba(0,0,0,.4)}"
   "#pc-dot{width:8px;height:8px;border-radius:50%;background:#39d0d8;"
   "box-shadow:0 0 8px #39d0d8;animation:pcp 1.6s infinite}"
   "@keyframes pcp{0%,100%{opacity:1}50%{opacity:.35}}"
   "#pc-n{font-weight:700}#pc-label{color:#7d8590;text-transform:uppercase;letter-spacing:.1em;font-size:10px}"
   "#pc-panel{position:absolute;right:0;bottom:44px;width:300px;background:#0a0e14;"
   "border:1px solid #1f2733;border-radius:14px;padding:14px;box-shadow:0 12px 40px rgba(0,0,0,.55)}"
   "#pc-head{font-size:13px;letter-spacing:.3em;text-transform:uppercase;color:#39d0d8;margin-bottom:10px}"
   "#pc-vitals{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:10px}"
   ".pcv{background:#121821;border:1px solid #1f2733;border-radius:8px;padding:8px 10px}"
   ".pcv b{display:block;font-size:18px}.pcv i{color:#7d8590;font-style:normal;font-size:10px;text-transform:uppercase;letter-spacing:.1em}"
   "#pc-cells{max-height:180px;overflow:auto}"
   ".pcc{display:flex;justify-content:space-between;gap:8px;padding:4px 0;border-top:1px solid #1f2733}"
   ".pcc .k{color:#ffd166}.pcc .v{color:#7d8590;max-width:130px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}"
   "#pc-trace{font-size:11px;color:#39d0d8;margin-bottom:8px;min-height:14px}"))

(defn- chip-js []
  (str
   "(function(){var root=document.getElementById('pulse-chip');"
   "var ep=root.getAttribute('data-ep');"
   "var badge=document.getElementById('pc-badge'),panel=document.getElementById('pc-panel');"
   "badge.onclick=function(){panel.hidden=!panel.hidden};"
   "function fb(b){if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';return (b/1048576).toFixed(1)+' MB'}"
   "function render(s){document.getElementById('pc-n').textContent=s.vitals['live-cells'];"
   "document.getElementById('pc-vitals').innerHTML="
   "`<div class=pcv><b>${s.vitals['tracked']}</b><i>tracked</i></div>`+"
   "`<div class=pcv><b>${fb(s.vitals['retained-bytes'])}</b><i>retained</i></div>`;"
   "document.getElementById('pc-cells').innerHTML=(s.cells||[]).map(c=>"
   "`<div class=pcc><span class=k>${c.kind}:${c.name}</span><span class=v>${c.value}</span></div>`).join('');"
   "var t=s.trace||{},rc=(t.recomputed||[]);var tl=document.getElementById('pc-trace');"
   "if(tl)tl.innerHTML=rc.length?`↻ ${rc.join(', ')} → ${t['patch-ops']} op`:'idle';}"
   "function conn(){var ws=new WebSocket(ep);"
   "ws.onmessage=function(e){render(JSON.parse(e.data))};"
   "ws.onclose=function(){setTimeout(conn,1000)};}conn();})();"))
```

## The bold part: inject the chip into any live view, natively

The chip does not need its own page or its own transport. A live app's view is
just a function that returns hiccup, and the chip is just more hiccup. So the
maximalist move is a **view decorator**: `with-chip` wraps a view function so its
output becomes `[the original view, then the chip]`. The chip then rides the
app's existing render -> diff -> patch loop — it is diffed and patched like any
other node, over the connection the app already has. No new server, no second
socket for the chip itself; it simply becomes part of the tree.

`chip-hiccup` is the chip as a hiccup node (its `<style>` and `<script>` are
raw-text tags, emitted verbatim). `with-chip` is the decorator.

```beam-lisp
(defn chip-hiccup
  "The expandable chip as a hiccup node, connecting to `endpoint` for live
   data. Because it is hiccup, it composes into any live view and is diffed
   and patched like the rest of the tree."
  [endpoint]
  [:div {:id "pulse-chip" :data-ep endpoint}
   [:style (chip-css)]
   [:button {:id "pc-badge"}
    [:span {:id "pc-dot"}] [:span {:id "pc-n"} "\u2014"]
    [:span {:id "pc-label"} "cells"]]
   [:div {:id "pc-panel" :hidden true}
    [:div {:id "pc-head"} "pulse"]
    [:div {:id "pc-vitals"}]
    [:div {:id "pc-trace"}]
    [:div {:id "pc-cells"}]]
   [:script (chip-js)]])

(defn with-chip
  "Decorate a live view fn so every render also carries the pulse chip. The
   view keeps its own signature; the chip is appended as a sibling under a
   wrapping div. `endpoint` is the websocket the chip reads (default
   \"/__pulse/ws\"). In dev mode:

     (def view (tooling.pulse/with-chip my-view))

   and mount `view` as usual — the chip appears in the corner, live, with no
   other wiring."
  ([view] (with-chip view "/__pulse/ws"))
  ([view endpoint]
   (fn [& args]
     [:div (apply view args) (chip-hiccup endpoint)])))
```

The app still needs to serve the chip's websocket feed somewhere (the same
`ws-handlers` the page uses). But the *chip itself* — its markup, its expand
behaviour, its live updates — arrives through the app's own view, injected by a
function that wraps another function. That is the whole mechanism: reactivity
and composition, no framework.

## Serving it: the websocket both shapes share

Both the page and the chip read the same live feed: a websocket that pushes a
`frame-json` on a timer. `ws-handlers` is the handler map a host app wires into
its router; `mount` returns everything a host needs.

```beam-lisp
(defn- send-tick! []
  (erlang/send_after 500 (erlang/self) [:pulse/tick]))

(defn- ws-init [_state]
  (send-tick!)
  [:push (list (list :text (frame-json))) {}])

(defn- ws-info [msg state]
  (if (and (sequential? msg) (= :pulse/tick (first msg)))
    (do (send-tick!) [:push (list (list :text (frame-json))) state])
    [:ok state]))

(def ws-handlers
  {:init ws-init
   :handle-in (fn [_frame state] [:ok state])
   :handle-info ws-info})

(defn mount
  "Everything a host app wires into its own router (dev mode):

     (ns myapp (:require [web] [tooling.pulse :as pulse]))
     (def p (pulse/mount))
     (defn router [conn]
       (web/route conn
         [:get \"/__pulse\"]    (web/html conn (:page p))
         [:get \"/__pulse/ws\"] (web/upgrade conn (:ws-handlers p) nil)
         :else (web/text conn 404 \"nf\")))

   The chip is injected separately (see tooling.pulse.chip); it connects to the
   same /__pulse/ws feed."
  []
  {:page (page)
   :ws-handlers ws-handlers})
```
