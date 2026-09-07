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
            [data.tap :as tap]
            [tooling.trace :as trace]
            [tooling.incremental :as inc]
            [live.hiccup :as h]
            [web]
            [interop]))

;; One process-wide tap: the live socket publishes a frame per mount/commit
;; here (hand it to the app as `:tap`), and the dashboard subscribes so every
;; frame reaches the browser the instant it lands — no polling, no missed
;; updates between ticks.
(declare ensure-watcher!)
(def ^:private the-tap (atom nil))

(defn tap
  "The dashboard's data.tap. Give it to a live app: `{:tap (pulse/tap)}`."
  []
  (or @the-tap
      (let [t (tap/open {:cap 300})]
        (if (compare-and-set! the-tap nil t)
          (do (ensure-watcher!) t)
          @the-tap))))

(defn frames
  "Every retained frame the live socket published (oldest first)."
  []
  (tap/frames (tap)))

;; Per-frame attribution: which traced subtrees recomputed FOR this frame.
;; A single process-wide watcher subscribes to the tap; on each frame it
;; takes the recompute labels recorded since the previous frame, stores them
;; under that frame's :t, and clears the trace. Chips then read attribution
;; by :t, so many chips never race to clear one trace.
(def ^:private by-frame (atom {}))
(def ^:private watcher (atom nil))

(defn- attribute! [f]
  (let [labels (mapv (fn [e] (str (:label e)))
                     (filter (fn [e] (= :recompute (:kind e))) (trace/events (tr))))]
    (swap! by-frame (fn [m]
                      (let [m2 (assoc m (:t f) {:recomputed (distinct labels) :ops (count (:ops f))})]
                        ;; bounded like the ring
                        (if (> (count m2) 400) (into {} (drop (- (count m2) 400) (sort-by key m2))) m2))))
    (trace/clear! (tr))))

(defn- ensure-watcher! []
  (when (nil? @watcher)
    (let [pid (spawn (fn []
                       (tap/subscribe! (tap))
                       (loop []
                         (receive
                           [:tap/frame f] (do (attribute! f) (recur))))))]
      (if (compare-and-set! watcher nil pid) pid (do (erlang/exit pid :normal) @watcher)))))

(defn attribution
  "{:recomputed [labels] :ops n} for frame `t`, or nil."
  [t]
  (get @by-frame t))

;; One process-wide render trace, so the dashboard can narrate updates.
(def ^:private the-trace (atom nil))

(defn- tr []
  (or @the-trace
      (let [t (trace/open)]
        (if (compare-and-set! the-trace nil t) t @the-trace))))

;; Re-exported so an app writes its view against pulse directly:
;;   (pulse/traced :label [dep] (fn [] hiccup))  — a subtree that both
;;   recomputes only on change (incremental) AND records why (trace).
;; The dependency graph: label → the names of the cells it reads. `traced`
;; accepts deps as a vector (anonymous edges) or a MAP {name ref} (named
;; edges, drawn in the studio's cell graph). The graph is a value in a cell,
;; so the studio renders it as SVG hiccup like everything else.
(def ^:private the-graph (atom {}))

(defn graph
  "The declared dependency graph: {label [dep-name …]}."
  []
  @the-graph)

(defn traced
  "An incremental, traced view subtree. Recomputes only when a dep changes,
   and records each recompute into the dashboard's render trace under `label`.
   `deps` is a vector of refs, or a map {name ref} to name the edges."
  [label deps render]
  (swap! the-graph assoc label
         (if (map? deps) (mapv (fn [[k _]] (name k)) deps)
             (mapv (fn [i] (str "dep" i)) (range (count deps)))))
  (trace/traced (tr) label (if (map? deps) (into [] (vals deps)) deps)
    (fn []
      ;; stamp the subtree root with its label. A paint/inspect tool reads
      ;; data-tr up the DOM to name the OWNER of any changed element.
      (let [h (render)]
        (if (and (vector? h) (keyword? (first h)))
          (if (map? (second h))
            (assoc h 1 (assoc (second h) :data-tr (name label)))
            (into [(first h) {:data-tr (name label)}] (rest h)))
          h)))))

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
   zero-arg fn returning a snapshot of the cell's value. An optional `writer`
   (fn [new-value]) lets the studio SET the cell from the chip — the cell is
   then driveable, not just visible. Returns an id for `untrack`. An
   untracked cell still counts in the native vitals; it simply has no row."
  ([kind name reader] (track kind name reader nil))
  ([kind name reader writer]
   (registry/enroll (reg) kind name {:reader reader :writer writer})))

(defn set!
  "Write `value` (an EDN string, read here) into the tracked cell `name`
   through its writer. Returns {:ok name} or {:error why}."
  [cell-name edn]
  (let [e (first (filter (fn [e] (= (str (:name e)) (str cell-name))) (registry/entries (reg))))
        w (when e (:writer (:meta e)))]
    (cond
      (nil? e) {:error (str "no tracked cell " cell-name)}
      (nil? w) {:error (str cell-name " is read-only (tracked without a writer)")}
      ;; the chip is a DEV instrument with full authority (it can already fire
      ;; any intent); the value is evaluated as bl, so `(range 3)` works too.
      :else (try (w (BeamLisp/eval edn)) {:ok cell-name}
                 (catch err {:error (str err)})))))

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
             :writable (some? (:writer (:meta e)))
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
        latest (tap/latest (tap))
        attr (when latest (attribution (:t latest)))
        recent (if attr
                 (into [] (:recomputed attr))
                 (->> (trace/events (tr))
                      (filter (fn [e] (= :recompute (:kind e))))
                      (mapv (fn [e] (str (:label e))))))]
    {:vitals (vitals)
     :by-kind (by-kind)
     :cells (cells)
     :trace {:recomputed recent
             :patch-ops (if attr (:ops attr) (:patch-ops u))
             :event-count (:event-count u)}
     :frame (frame-summary (tap/latest (tap)))
     :cost (h/hiccup->html (cost-hiccup))
     :graph (h/hiccup->html (graph-hiccup))
     :at (System/system_time :millisecond)}))

(defn frame-summary
  "A tap frame without its tree (the tree is large; a tool fetches it on
   demand by :t). Ops are kept: they are what a paint overlay flashes."
  [f]
  (when f
    {:t (:t f) :kind (:kind f) :ms (:ms f) :basis (:basis f)
     :event (pr-str (:event f))
     :op-count (count (:ops f))
     :ops (:ops f)}))

(defn frame-json
  "The snapshot as a JSON string, bl collections deep-converted so Jason can
   encode them. This is what a websocket ships each tick."
  []
  (Jason/encode! (interop/jsonable (assoc (snapshot) :msg "snapshot"))))
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
   "#pc-trace{font-size:11px;color:#39d0d8;margin-bottom:8px;min-height:14px}"
   "#pc-tools{display:flex;gap:6px;margin-bottom:10px;flex-wrap:wrap}"
   ".pct{background:#121821;color:#7d8590;border:1px solid #1f2733;border-radius:99px;"
   "padding:3px 10px;font:inherit;font-size:10px;text-transform:uppercase;letter-spacing:.1em;cursor:pointer}"
   ".pct.on{color:#0a0e14;background:#39d0d8;border-color:#39d0d8;font-weight:700}"
   "#pc-timeline{margin-bottom:10px;background:#121821;border:1px solid #1f2733;border-radius:8px;padding:8px 10px}"
   "#pc-scrub{width:100%;accent-color:#39d0d8}"
   "#pc-tl-info{font-size:11px;color:#e6edf3;min-height:14px}#pc-tl-info b{color:#39d0d8}"
   "#pc-tl-ticks{display:flex;gap:2px;margin-top:6px;height:18px;align-items:flex-end}"
   ".tlt{flex:1;min-width:2px;background:#1f2733;border-radius:1px;cursor:pointer}.tlt.cur{background:#39d0d8}.tlt.mount{background:#7d8590}"
   "#pc-inspect{margin-bottom:10px;background:#121821;border:1px solid #1f2733;border-radius:8px;padding:8px 10px;font-size:11px}"
   "#pc-in-head{color:#ffd166;font-weight:700;margin-bottom:4px}"
   "#pc-in-body .row{padding:3px 0;border-top:1px solid #1f2733;color:#e6edf3;word-break:break-all}"
   "#pc-in-body .k{color:#7d8590;margin-right:6px}#pc-in-body .ev{color:#c084fc}"
   "#pc-in-body button{background:#1f2733;color:#e6edf3;border:1px solid #2b3542;border-radius:6px;padding:2px 8px;font:inherit;cursor:pointer;margin-left:6px}"
   "#pc-in-body input{background:#0a0e14;color:#e6edf3;border:1px solid #2b3542;border-radius:6px;padding:2px 6px;font:inherit;width:100%;margin-top:3px}"
   ".pcc .set{background:none;border:none;color:#39d0d8;cursor:pointer;font:inherit;padding:0 0 0 6px}"
   ".studio-pick{outline:2px solid #ffd166!important;outline-offset:2px}"
   "#pc-cost{margin-bottom:10px;background:#121821;border:1px solid #1f2733;border-radius:8px;padding:8px 10px;font-size:11px}"
   ".pcost{display:flex;align-items:center;gap:8px;padding:2px 0}.pcost .l{color:#7d8590;width:30px}"
   ".pcost svg{flex:1;height:18px}.pcost b{width:56px;text-align:right;color:#e6edf3}.pcost i{color:#7d8590;font-style:normal;font-size:9px;margin-left:2px}"
   ".pcidle{margin-top:4px;color:#46d18f}.pcidle.bad{color:#ff5c8a;font-weight:700}"
   "#pc-graph{margin-bottom:10px;background:#121821;border:1px solid #1f2733;border-radius:8px;padding:6px 10px}"
   "#pc-graph svg{display:block}#pc-graph text{font-family:inherit}.pcempty{color:#7d8590;font-size:10px}"))

(defn- chip-js []
  (str
   "(function(){var root=document.getElementById('pulse-chip');"
   "var ep=root.getAttribute('data-ep');"
   "var badge=document.getElementById('pc-badge'),panel=document.getElementById('pc-panel');"
   "badge.onclick=function(){panel.hidden=!panel.hidden};"
   ;; instrument toggles → Studio.toggle; reflect state (incl. restored) on the buttons
   "function syncTools(){if(!window.Studio)return;root.querySelectorAll('.pct').forEach(function(b){"
   "var i=Studio.instruments[b.getAttribute('data-tool')];b.classList.toggle('on',!!(i&&i.on))})}"
   "root.querySelectorAll('.pct').forEach(function(b){b.onclick=function(){"
   "if(window.Studio){Studio.toggle(b.getAttribute('data-tool'));syncTools()}}});"
   "document.addEventListener('studio:toggle',syncTools);setTimeout(syncTools,50);"
   "function fb(b){if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';return (b/1048576).toFixed(1)+' MB'}"
   "function render(s){document.getElementById('pc-n').textContent=s.vitals['live-cells'];"
   "document.getElementById('pc-vitals').innerHTML="
   "`<div class=pcv><b>${s.vitals['tracked']}</b><i>tracked</i></div>`+"
   "`<div class=pcv><b>${fb(s.vitals['retained-bytes'])}</b><i>retained</i></div>`;"
   "document.getElementById('pc-cells').innerHTML=(s.cells||[]).map(c=>"
   "`<div class=pcc><span class=k>${c.kind}:${c.name}</span><span class=v title=\"${String(c.value).replace(/\"/g,'&quot;')}\">${c.value}</span>${c.writable?`<button class=set data-cell=\"${c.name}\" data-val=\"${String(c.value).replace(/\"/g,'&quot;')}\">✎</button>`:''}</div>`).join('');"
   "document.querySelectorAll('#pc-cells .set').forEach(function(b){b.onclick=function(){var v=prompt('set '+b.getAttribute('data-cell')+' to (edn):',b.getAttribute('data-val'));if(v!=null)send(['set',b.getAttribute('data-cell'),v])}});"
   "var t=s.trace||{},rc=(t.recomputed||[]);var tl=document.getElementById('pc-trace');"
   "var ce=document.getElementById('pc-cost');if(ce&&s.cost)ce.innerHTML=s.cost;"
   "var ge=document.getElementById('pc-graph');if(ge&&s.graph)ge.innerHTML=s.graph;"
   "var f=s.frame;var fl=f?`t${f.t} · ${f.kind} · ${f['op-count']} op · ${(+f.ms).toFixed(1)}ms`+(f.event&&f.event!=='nil'?` · ${f.event}`:''):'';"
   "if(tl)tl.innerHTML=rc.length?`↻ ${rc.join(', ')} → ${t['patch-ops']} op<br>${fl}`:(fl||'idle');}"
   "var ws=null;function send(m){if(ws&&ws.readyState===1)ws.send(JSON.stringify(m))}"
   "function conn(){ws=new WebSocket(ep);window.__pulseWs=ws;"
   "ws.onmessage=function(e){var m=JSON.parse(e.data);"
   "if(m.msg==='snapshot'){render(m);if(window.Studio&&Studio.onSnapshot)Studio.onSnapshot(m)}"
   "else if(window.Studio&&Studio.onMessage)Studio.onMessage(m)};"
   "ws.onclose=function(){setTimeout(conn,1000)};}conn();"
   "window.__pulseSend=send;})();"))
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
    [:div {:id "pc-tools"}
     [:button {:class "pct" :data-tool "paint" :title "flash the exact elements each patch op touched"} "paint"]
     [:button {:class "pct" :data-tool "timeline" :title "scrub back through every frame the app rendered"} "timeline"]
     [:button {:class "pct" :data-tool "inspect" :title "alt-click any element: what it is, what feeds it, what touched it — and fire its events"} "inspect"]
     [:button {:class "pct" :data-tool "cost" :title "ops · render ms · wire bytes per frame, and commits that shipped nothing"} "cost"]
     [:button {:class "pct" :data-tool "graph" :title "cells → traced subtrees, as declared; glows where the last update flowed"} "graph"]]
    [:div {:id "pc-cost" :hidden true}]
    [:div {:id "pc-graph" :hidden true}]
    [:div {:id "pc-inspect" :hidden true}
     [:div {:id "pc-in-head"} "alt-click an element"]
     [:div {:id "pc-in-body"}]]
    [:div {:id "pc-timeline" :hidden true}
     [:input {:id "pc-scrub" :type "range" :min "1" :max "1" :value "1"}]
     [:div {:id "pc-tl-info"}]
     [:div {:id "pc-tl-ticks"}]]
    [:div {:id "pc-vitals"}]
    [:div {:id "pc-trace"}]
    [:div {:id "pc-cells"}]]
   [:script {:src "/__pulse/studio.js"}]
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
  (erlang/send_after 2000 (erlang/self) [:pulse/tick]))

(defn- node-children
  "The child slots a differ path indexes: strings and elements, nils dropped,
   seqs spliced (mirrors live.diff `children-of`)."
  [node]
  (if (and (vector? node) (keyword? (first node)))
    (let [body (if (map? (second node)) (drop 2 node) (rest node))]
      (into [] (remove nil? (mapcat (fn [c] (if (and (sequential? c) (not (vector? c))) c [c])) body))))
    []))

(defn node-at
  "The hiccup node at differ `path` (a vector of child indices) in `tree`."
  [tree path]
  (reduce (fn [n i] (when n (get (node-children n) i))) tree path))

(defn- path-prefix? [p q]
  (and (<= (count p) (count q)) (= p (subvec (into [] q) 0 (count p)))))

(defn touched
  "Every retained frame whose ops touched `path` or anything under it —
   the history of one element, read straight off the tap ring."
  [path]
  (into []
    (keep (fn [f]
            (let [hits (filter (fn [op] (path-prefix? path (nth op 1))) (:ops f))]
              (when (seq hits)
                {:t (:t f) :event (pr-str (:event f)) :ops (into [] hits)})))
          (tap/frames (tap)))))

(defn inspect
  "Everything the studio can say about the element at `path`: the hiccup
   node (tag, attrs, its event terms — the :on-* values are DATA, so they
   can be shown, edited, and fired), its owner, and the frames that touched
   it."
  [path]
  (let [f (tap/latest (tap))
        node (when f (node-at (:tree f) path))
        tag (when (vector? node) (first node))
        attrs (when (and (vector? node) (map? (second node))) (second node))
        events (when attrs
                 (into {} (filter (fn [[k _]] (String/starts_with? (name k) "on-")) attrs)))]
    {:path path
     :tag (when tag (name tag))
     :attrs (when attrs (pr-str (apply dissoc attrs (keys events))))
     :events (into {} (map (fn [[k v]] [(name k) (pr-str v)]) events))
     :text (when (string? node) node)
     :owner (or (get attrs :data-tr) (get attrs :key))
     :touched (touched path)
     :t (:t f)}))

(defn- ws-init [_state]
  ;; per-commit push: this ws process subscribes to the tap, so a frame is
  ;; shipped the moment the live socket publishes it. The 2s tick is only a
  ;; heartbeat for the vitals (cell counts move without a commit).
  (tap/subscribe! (tap))
  (send-tick!)
  [:push (list (list :text (frame-json))) {}])

(defn- ws-info [msg state]
  (cond
    (and (sequential? msg) (= :pulse/tick (first msg)))
      (do (send-tick!) [:push (list (list :text (frame-json))) state])
    (and (sequential? msg) (= :tap/frame (first msg)))
      [:push (list (list :text (frame-json))) state]
    :else [:ok state]))

(defn- reply [state msg]
  [:push (list (list :text (Jason/encode! (interop/jsonable msg)))) state])

(defn- frame-at
  "One frame rendered for the timeline: its html (the tree is a value we
   kept, so 'the screen at t' is a pure function of it), the ops that made
   it, and the event that caused it."
  [t]
  (when-let [f (tap/frame (tap) t)]
    {:t (:t f) :kind (:kind f) :ms (:ms f) :basis (:basis f)
     :event (pr-str (:event f))
     :ops (:ops f)
     :html (h/hiccup->html (:tree f))}))

(defn wire-bytes
  "How many bytes the browser received for a frame: the ops JSON for a
   commit, the HTML for a mount."
  [f]
  (try
    (if (= :mount (:kind f))
      (count (h/hiccup->html (:tree f)))
      (count (Jason/encode! (interop/jsonable (:ops f)))))
    (catch _ 0)))

(defn- timeline-index
  "Every retained frame as a small row (no tree, no ops) — the scrubber."
  []
  (mapv (fn [f] {:t (:t f) :kind (:kind f) :ms (:ms f)
                 :ops (count (:ops f)) :bytes (wire-bytes f)
                 :event (pr-str (:event f)) :at (:at f)})
        (tap/frames (tap))))

;; ── Cost: sparklines as SVG hiccup, rendered by the server ──────────
;;
;; The chart is a VALUE. Each series is a polyline over the last N frames;
;; the server renders it as hiccup and ships the html — no charting library,
;; and the same hiccup could sit inside any live view and be diffed.
(defn- spark
  "An SVG sparkline over `xs` (numbers), `w`x`h`, stroke `color`. The last
   point is dotted so the eye finds 'now'."
  [xs w h color]
  (let [n (count xs)
        mx (max 1 (reduce max 0 xs))
        pt (fn [i x] [(if (<= n 1) w (* w (/ i (dec n))))
                      (- h (* (- h 2) (/ x mx)))])
        pts (map-indexed pt xs)
        path (join " " (map (fn [[x y]] (str (Float/round (* 1.0 x) 1) "," (Float/round (* 1.0 y) 1))) pts))
        [lx ly] (or (last pts) [0 h])]
    [:svg {:viewBox (str "0 0 " w " " h) :width w :height h :preserveAspectRatio "none"}
     [:polyline {:points path :fill "none" :stroke color :stroke-width 1.5 :stroke-linejoin "round"}]
     [:circle {:cx lx :cy ly :r 2 :fill color}]]))

(defn graph-hiccup
  "The dependency graph as SVG hiccup: cells (left) → traced subtrees
   (right), an edge per declared dep. Subtrees that recomputed on the last
   update glow; so do the cells they read. The picture IS the declaration —
   nothing is sampled or instrumented."
  []
  (let [g (graph)
        subs (sort (map name (keys g)))
        cells (sort (distinct (mapcat identity (vals g))))
        latest (tap/latest (tap))
        hot (set (map str (or (:recomputed (when latest (attribution (:t latest))))
                              (:recomputed (trace/last-update (tr))))))
        hot-cells (set (mapcat (fn [[l ds]] (if (contains? hot (name l)) ds [])) g))
        rowh 22 pad 10
        h (+ (* 2 pad) (* rowh (max 1 (count subs) (count cells))))
        w 250
        y (fn [i] (+ pad 11 (* i rowh)))
        idx (fn [xs] (into {} (map-indexed (fn [i x] [x i]) xs)))
        ci (idx cells) si (idx subs)
        node (fn [x yy label hot? color]
               [:g
                [:circle {:cx x :cy yy :r 5 :fill (if hot? color "#1f2733")
                          :stroke color :stroke-width 1.5
                          :style (if hot? (str "filter:drop-shadow(0 0 5px " color ")") "")}]
                [:text {:x (if (< x 100) (+ x 10) (- x 10)) :y (+ yy 4)
                        :text-anchor (if (< x 100) "start" "end")
                        :fill (if hot? "#e6edf3" "#7d8590") :font-size 11} label]])]
    (if (empty? g)
      [:div {:class "pcempty"} "no traced subtrees yet — build the view with (pulse/traced :label {:cell ref} …)"]
      [:svg {:viewBox (str "0 0 " w " " h) :width "100%" :height h}
       ;; edges run between the label gutters, not through the labels
       (for [[l ds] g, d ds]
         [:line {:x1 88 :y1 (y (get ci d)) :x2 (- w 88) :y2 (y (get si (name l)))
                 :stroke (if (contains? hot (name l)) "#39d0d8" "#1f2733") :stroke-width 1.2}])
       (for [c cells] (node 12 (y (get ci c)) c (contains? hot-cells c) "#ffd166"))
       (for [sl subs] (node (- w 12) (y (get si sl)) sl (contains? hot sl) "#39d0d8"))])))

(defn cost-hiccup
  "The cost panel: three sparklines (ops · ms · wire bytes) over the last
   `n` frames, each with its current value, plus the 'recomputed but shipped
   nothing' count — commits whose render ran and produced zero ops, the
   pathology tooling.trace catches."
  ([] (cost-hiccup 40))
  ([n]
   (let [all (tap/frames (tap))
         fs (into [] (drop (max 0 (- (count all) n)) all))
         commits (filter (fn [f] (= :commit (:kind f))) fs)
         ops (mapv (fn [f] (count (:ops f))) fs)
         ms (mapv (fn [f] (* 1.0 (or (:ms f) 0))) fs)
         bytes (mapv wire-bytes fs)
         idle (count (filter (fn [f] (empty? (:ops f))) commits))
         row (fn [label xs color unit fmt]
               [:div {:class "pcost"}
                [:span {:class "l"} label]
                (spark xs 120 18 color)
                [:b (if (seq xs) (fmt (last xs)) "–") [:i unit]]])]
     [:div {:id "pc-cost-body"}
      (row "ops"   ops   "#39d0d8" ""   str)
      (row "ms"    ms    "#ffd166" "ms" (fn [x] (Float/round x 1)))
      (row "wire"  bytes "#c084fc" "B"  str)
      [:div {:class (str "pcidle" (if (pos? idle) " bad" ""))}
       (if (pos? idle)
         (str "⚠ " idle " commit" (if (= 1 idle) "" "s") " recomputed but shipped 0 ops")
         (str "✓ every commit shipped ops · " (count fs) " frames"))]])))

(defn- ws-in
  "Requests from the chip, each a JSON list of verb and args:
   timeline -> the scrubber index; time t -> the screen at frame t."
  [frame state]
  (let [req (try (interop/json-> (nth frame 1)) (catch _ nil))
        verb (if (sequential? req) (first req) nil)]
    (cond
      (= verb "timeline") (reply state {:msg "timeline" :frames (timeline-index)})
      (= verb "time")     (reply state (assoc (or (frame-at (nth req 1)) {:t (nth req 1) :missing true}) :msg "time"))
      (= verb "inspect")  (reply state (assoc (inspect (into [] (nth req 1))) :msg "inspect"))
      (= verb "set")      (reply state (assoc (set! (nth req 1) (nth req 2)) :msg "set"))
      :else [:ok state])))

(def ws-handlers
  {:init ws-init
   :handle-in ws-in
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
   :ws-handlers ws-handlers
   :studio-js (web/asset "lib/tooling/studio.js")})

(defn http
  "The studio's HTTP surface as a live.app `:http` handler: the chip feed and
   the studio script. Wire it with one key: `{:http (pulse/http)}`."
  []
  (let [m (mount)]
    (fn [conn path]
      (cond
        (= path "/__pulse/ws")        (web/upgrade conn (:ws-handlers m) nil)
        (= path "/__pulse/studio.js") (web/js conn (:studio-js m))
        (= path "/__pulse")           (web/html conn (:page m))
        :else nil))))
```
