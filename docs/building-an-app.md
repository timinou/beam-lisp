# Building an app on beam-lisp: datom + live, layer by layer

How to stand up a new application of the same shape as
`examples/live/11-pulse-app.bl` and `examples/server/hearth.bl` — a durable
graph, a pure read model, a live page whose view is a function of the
database, and a verification ladder that catches the defects before a browser
does.

Everything below is drawn from the working system. Where a rule exists
because something broke, that is said, because a rule whose reason is lost
gets deleted by the next person.

---

## 0. The shape, in one picture

```
    browser                                  BEAM
    ───────                                  ────
    live page      ◀── [:mount html] ───────  one process per viewer
    (hiccup + client.js)   [:patch ops]       (a live.socket)
        │
        │  [:event [:intent :post {:text "hi"}]]
        ▼
    WebSocket  web/upgrade → BeamLisp.WebSocket
        │
        ▼
    live.socket
        │  :assign  → locals, re-render here
        │  :intent  → authorize → transact!
        ▼
    datom conn ──▶ datom.store-fjall   (durable)
                   datom.store-ets     (session)
        │  commit → [:datom/tx basis tx-datoms]
        ▼
    every listening socket re-projects → live.diff → patch
```

The chain is: **page ← `web.bl` + `live.socket` ← beam-lisp intents ← datom
on fjall.** Two properties hold it together:

1. **A view is a pure function** — `(fn [shared-db session-db locals] →
   hiccup)`. It renders the world; it never mutates, fetches, or subscribes.
   The same function answers a test and a browser.
2. **An event is closed data**, from three heads — `[:assign …]`,
   `[:intent …]`, `[:navigate …]` — never a closure. An `:intent` asks for a
   FACT; the socket authorizes it, transacts it, and the browser receives only
   a patch.

`live.app` lifts the whole thing into one value: an app is a map of routes,
screens, guarded worlds, and intents, served with `(live.app/serve app {:port
…})`. A screen is `(fn [ctx] → hiccup)`. Write a real app as one `.bl` file and
run it with `bl serve`.

---

## 1. The layers, and the rule that orders them

Copy `examples/server/hearth.bl` — the manifest namespace. Loading it loads the
application, because the loader computes order from the `(:require …)`
forms.

```clojure
(ns myapp.app
  (:require [myapp.schema]     ; what the system can say         (no deps)
            [myapp.store]      ; the durable connection, a process (schema)
            [myapp.work]       ; the lifecycle: states, legal moves (schema)
            [myapp.read]       ; the datalog queries — the read model (schema)
            [myapp.intent]     ; an intent becomes a transaction  (store work read)
            [myapp.corpus]     ; seed data, as terms              (read store)
            [myapp.ui.board])) ; views + intents                   (read)
```

**The rule: nothing reaches down past its layer; nothing below knows a layer
above exists.**

The sharpest instance: **`read` knows nothing of `store`.** Every query takes
a database *value*, never a connection and never the process. That single
choice buys three things:

- a whole page renders from ONE value and is therefore *consistent* — not
  six queries at six moments that can disagree about whether a task exists;
- every query is testable against an in-memory store with no process running
  and no file on disk;
- `as-of` is free. A historical value **is** a database value, so the same
  functions answer about the past. There is no second set of "historical"
  queries to keep in step.

Do not put the manifest in Elixir, and do not glob `src/**/*.bl`. A glob
loads whatever happens to be on disk (a scratch file included) and decides
order by filename.

---

## 2. Schema — the design document, as data

`myapp/schema.bl`. This file, read top to bottom, **is** the domain. An
attribute is a fact the system can hold, and the set of attributes is what
the system can say; nothing elsewhere may say anything it does not permit.

```clojure
(def identity-attrs
  [{:db/ident :myapp/slug
    :db/valueType :db.type/string
    :db/cardinality :db.cardinality/one
    :db/unique :db.unique/identity
    :db/doc "A stable, human-readable name. Upserts: loading twice updates."}

   {:db/ident :myapp/kind
    :db/valueType :db.type/keyword
    :db/cardinality :db.cardinality/one
    :db/index true
    :db/doc "What this entity IS. A tag rather than a table."}])
```

Reading an attribute:

| key | meaning |
|---|---|
| `:db/ident` | the keyword it is known by (required) |
| `:db/valueType` | `string long boolean keyword ref instant term` |
| `:db/cardinality` | `one` (default) \| `many` |
| `:db/unique` | `identity` (upserts) \| `value` (refuses a duplicate) |
| `:db/index` | maintain AVET, so a range scan can push down |
| `:db/doc` | what it means |

### Three decisions worth making deliberately

**`:db.unique/identity` on your slug.** This is what makes a seed corpus
idempotent: a tempid asserting a unique-identity value *upserts* onto
whatever entity already holds it. So `corpus/load!` runs on every boot with
no "have I already seeded?" flag anywhere to fall out of step with the
database. `:db.unique/value` would make the second load an **error** — right
for an invoice number, wrong for a definition that evolves.

**A `:kind` tag, indexed, instead of tables.** "All films" is then one
clause — `[?e :myapp/kind :film]` — with no join, and because it is indexed
it is an AVET range rather than a scan of the world.

**`:db.cardinality/many` is the sharpest key here.** It decides whether
asserting a value *replaces* the old one or accumulates beside it. Getting
it wrong is silent: a many-attribute recovered as one collapses its values
to whichever the scan reached last.

Schema is a value: `(transact! conn schema)` installs it, `(pr-str schema)`
prints it, a test asserts on it, and a migration is an ordinary transaction.

---

## 3. The pure domain — put rules in a map, not in control flow

`myapp/work.bl`. The usual shape is a `case` in a handler: read the state,
write the new one, hope every call site agrees which pairs are legal. The
rules then live in control flow, where they cannot be enumerated, tested, or
shown to a user — so the UI grows its own copy and the two drift.

Make them data:

```clojure
(def transitions
  {:todo    [:doing :dropped]
   :doing   [:review :todo :dropped]
   :review  [:done :doing]
   :done    []          ; terminal — EXPLICIT, so it reads as decided
   :dropped []})        ; rather than forgotten

(def permissions
  {:tech    #{:doing :review :todo :done :dropped}
   :product #{:todo :review :done :dropped}
   :sales   #{:dropped}})
```

Two maps, deliberately not folded into one. **Legality and permission are
different questions and a UI needs them apart**: an illegal move should not
be offered at all, while a legal move that is not yours should be visible
and refused. Collapse them and a person cannot tell "that cannot happen"
from "you cannot do that", and files a bug about the wrong one.

The board's affordances and the write's validation then come from the same
map — *an offered action is a legal action by construction*, with no second
list to maintain.

---

## 4. Read model — one function per question

`myapp/read.bl`. Every function takes a db **value**. Datalog answers a
*set* of tuples (the same answer arriving by two derivations is one answer),
so ordering is the caller's business: sort here, once, rather than leaving a
page to render whatever order a set iterates.

```clojure
(defn unrealised-components
  "Components with no task building them, and their state."
  [db]
  (vec (sort-by
         (fn [r] (str (get r 0)))
         (to-list
           (datom/q (quote [:find ?slug ?state
                            :where [?c :myapp/kind :component]
                                   [?c :myapp/slug ?slug]
                                   [?c :component/state ?state]
                                   [:not-join [?c] [?t :task/realises ?c]]])
                    db)))))
```

`:not-join` is what makes it *one query*. The alternative — pull every task
and every component and subtract in the host — is the same answer computed
somewhere it cannot be indexed.

### Project at the read model, not the view

A row is an entity map with namespaced keys (`:myapp/title`,
`:film/status`). A view that reads `(:film/status entity)` has learned how
*this database spells it* — it would have to change if the schema renamed an
attribute the page never cared about. Project rows to plain keys in the read
model, so a view names what it shows, not how the store spells it:

```clojure
(defn- row [entity pairs]
  (reduce (fn [m [from to]]
            (assoc m to (or (get entity from) "")))
          {} pairs))

(row f [[:myapp/title :title] [:film/status :status] [:myapp/slug :slug]])
```


### Two rules learned expensively

**Absence is not a state.** A pattern only matches where its attribute
exists, so an entity with no `:component/state` binds *nothing* and silently
backs every requirement that needs it. Query the absent case separately
(`[:not-join [?c] [?c :component/state _]]`) and treat absent as the unsafe
value. Cost of being wrong that way: something held back until a human
looks. Cost the other way: a demo that fails in front of a customer.

**An empty list is an answer, not an absence.** "Every requirement is
asserted" is the best result the tool can report and renders identically to
a query that crashed if the view just prints the list. Compose the sentence
in the read model, where the meaning of nothing is known:

```clojure
(defn verdict [coll noun empty-says]
  (let [n (count coll)]
    (cond (= n 0) empty-says
          (= n 1) (str "1 " noun)
          :else   (str n " " noun "s"))))
```

`empty-says` belongs to the caller, because only the caller knows what
nothing *means*: no unproven requirements is good, no showable films is bad.

### A produced stream must be built lazily, or it is not a stream

When a read model *produces* a value that its caller consumes incrementally —
Server-Sent Events to a browser, a chunked HTTP body, anything written to a
socket as it is realized — **how** the sequence is built decides whether it
streams at all, and the two ways look identical at the call site.

`Enum/*` is **eager**: `(Enum/map coll f)` walks all of `coll` and returns a
finished list. `Stream/*` is **lazy**: `(Stream/map coll f)` returns a
description that produces each element only when the consumer pulls it. So a
function that maps provider chunks into SSE frames with `Enum/flat_map`
**buffers the entire upstream response** before the consumer sees byte one —
the request "streams" to no one, and a slow or endless upstream hangs the whole
response. Switch the same code to `Stream/flat_map` + `Stream/concat` and each
frame reaches the socket the moment the provider emits it.

```clojure
; EAGER — realizes every chunk before the caller gets the first frame
(defn frames [chunks]
  (Enum/flat_map chunks (fn [c] [(encode c)])))

; LAZY — one frame produced per chunk pulled; TRUE streaming
(defn frames [chunks]
  (Stream/flat_map chunks (fn [c] [(encode c)])))
```

The trap is that laziness is **invisible in a test**: both versions pass
`(is (= expected (Enum/to_list (frames input))))`, because the assertion
realizes the whole sequence anyway. The difference shows only under a real
consumer, as latency-to-first-byte or a hang. Diagnose it deliberately — put a
side effect in the mapping fn and count how many times it ran before you pull
the second element:

```clojure
(let [n (atom 0)
      s (Stream/map (range) (fn [x] (swap! n inc) x))]
  (Enum/to_list (Stream/take s 2))
  (deref n))            ; lazy → 2, eager → would never terminate on (range)
```

The rule: **a value the caller consumes lazily MUST be built with `Stream/*`;
`Enum/*` realizes eagerly.** beam-lisp's own `lazy-seq` (and the hybrid
`map`/`filter`/`take` over a `LazySeq`, section notes in `core.bl`) compose
lazily too — but the moment the sequence crosses into an Elixir library that
speaks `Stream`, it is `Stream/*` that keeps the laziness the boundary needs.

---

## 5. Store — the one mutable thing, as a supervised process

`myapp/store.bl`. Everything else is a value; something has to hold the
moving end, and on the BEAM the honest place for a moving end is a process
with a name under a supervisor.

```clojure
(defserver store
  (init [path]
    (ok {:conn (datom/connect-with (datom.store-fjall/open path) myapp.schema/all)
         :path path}))

  (handle-call :db   [_from state] (reply (datom/db (get state :conn)) state))
  (handle-call :conn [_from state] (reply (get state :conn) state))

  (terminate [_reason state]
    (datom/release! (get state :conn))
    :ok)

  (handle-info _msg [state] (noreply state)))
```

**It is not a repository and holds no queries.** Callers ask for `(db)` — a
value, O(1), it captures a basis rather than data — and query it themselves.
∴ reads never touch this process, so it cannot be a bottleneck and a slow
query cannot block a write. The alternative (a GenServer with `get_tasks`,
`get_films`, …) grows one call per question, serialises every read through
one mailbox, and re-implements the query language it sits on.

Four things that will bite:

- **`terminate` must `datom/release!`.** `datom.conn` keeps a process-wide
  registry mapping each store to its writer and basis. That registry entry is
  a live reference, and the durable store's handle is freed by GC — so an
  unreleased entry keeps the **database locked against reopening** for the
  life of the VM. A store whose process is provably dead still owns its
  directory, and reopening it fails until the reference is dropped.
- **`terminate` does not run on a brutal kill.** Nothing does. Hence
  `release!` is idempotent, and a caller reopening after a crash may still
  wait for collection.
- **`erlang/whereis` answers the atom `:undefined`,** not nil, for an
  unregistered name. `(not (nil? …))` therefore returns *true* for a name
  nothing holds — a health check that cannot report ill health.
- **The name is what makes state identity independent of code identity.**
  The process keeps its connection across a reload of the namespace, because
  the name is what is looked up.

Give writes one door, and annotate them:

```clojure
(defn transact-as! [tx-data note lead]
  (let [annotation (if (nil? lead)
                     {:db/id :db/current-tx :tx/note note}
                     {:db/id :db/current-tx :tx/note note :tx/by lead})]
    (transact! (conj (vec tx-data) annotation))))
```

The annotation rides `:db/current-tx` — the transaction *is* an entity, so
describing it costs one datom and makes the change self-describing.
**This is why there is no activity table:** an events table written alongside
a change can disagree with the change; a fact recorded *on* the change
cannot.

---

## 6. Intent — a pure half and a dull impure half

`myapp/intent.bl`. This is where the app's writes live, and the split is the
point.

### `tx-for` — pure: intent + db → transaction data, or a refusal

```clojure
(defn tx-for [db op payload]
  (let [get* (fn [k] (get payload (name k)))]
    (cond
      (= op :refresh) {:tx [] :note ""}

      (= op :create-task)
      (let [title (get* :title)]
        (if (blank? (str title))
          {:refused "A task needs a title — it is what everyone else will read."}
          {:tx [{:db/id -1 :myapp/slug (slug-for title) …}]
           :note (str "created task \"" title "\"")}))

      :else
      {:refused (str "\"" (name op) "\" is not something this application does. "
                     "It answers to: " (join ", " (map name ops)) ".")})))
```

Every rule lives here, and it needs no substrate to check — no store, no
socket, no process.

**A refusal is a value, not an exception**, because a refused intent is an
ordinary outcome (someone typed an empty title). Exceptions are for the
impossible.

**A refusal is a sentence and it goes to a person.** Two rules: say what is
wrong, not that something is; say what would be right, when that is knowable.

### `perform` — impure: validate, write

A performer is what an intent op is wired to. Its signature is fixed: it
receives the conn, the payload, and the authenticated principal, and returns
transaction data — or nil for "validated, but nothing to write".

```clojure
(defn perform
  [conn payload _principal]
  (let [result (tx-for (datom/db conn) :create-task payload)]
    (if (contains? result :refused)
      nil                        ; nothing to write; the view renders the refusal
      (get result :tx))))
```

Three things in that shape are load-bearing:

- **The principal comes from the socket, not the payload.** The client names
  the *intent*; it cannot name the actor. The performer stamps the principal
  on the fact, so a post cannot lie about who posted.
- **A nil return is a legitimate no-op**, not an error: the performer
  validated and chose not to write. The socket records the outcome in locals
  (`:live/outcome`), so the view can say why, and nothing reaches the log.
- **The write is only the transaction.** Do not read back and push a rendered
  result. The commit broadcasts the moment; every listening socket
  re-projects; the view shows the new fact because the database changed — one
  path for the writer and every other viewer.

### Registration is the `:intents` map

An op is wired to its performer by a map — no global registry, no lookup by
name:

```clojure
(sock/mount {:view board
             :shared conn
             :session (sock/open-session ui-schema)
             :sink (erlang/self)
             :intents {:create-task perform}})
```

`live.app` carries the same map on the app value (`:intents`), so the screens
and the socket that serves them share one wiring. An unregistered op is a
**dead button**: the socket answers `[:denied …]` by name and never writes — a
view may name an op a narrower host does not serve.

Reads need no registration. A view receives the database **values** it renders
from (`shared`, `session`, `locals`), so the page's opening state and its state
after a click are each computed by the same pure function from one basis.

---

## 7. The socket — one process per viewer

`live.socket` binds a view to a conn. A live socket is a `defserver` — a real
OTP process, one per viewer — that holds:

| field | is |
|---|---|
| `:view` | a pure fn `(shared-db session-db locals) → hiccup` |
| `:shared` | the durable conn everyone sees |
| `:session` | this socket's own in-memory conn (opt) |
| `:locals` | ephemeral per-viewer values (draft text, ui toggles, `:me`) |
| `:tree` | the last hiccup tree, to diff against |
| `:sink` | where `[:mount …]` / `[:patch …]` go (the WebSocket process) |
| `:intents` | op → performer |

The loop, as plain functions you can call in a test:

```
mount        → render the view once → push [:mount html], remember the tree
on-commit    → re-render → diff → push [:patch ops]
handle-event → :assign   mutate locals, re-render NOW (this socket only)
             | :intent  authorize, then transact the shared world
             | :navigate mutate locals (route/params), re-render
```

The inversion that is the concurrency model: **a local mutation renders here; a
fact mutation renders everywhere.** `:intent` does not render — it transacts,
and the commit path (`on-commit`, driven by the datom broadcast) re-renders
*every* watcher. So two tabs cannot disagree, and a dropped patch is replayable
from the basis.

### Writing one socket

```clojure
(sock/deflive board-socket
  :view    board                 ; (shared-db session-db locals) → hiccup
  :intents {:create-task perform}
  :session ui-schema             ; opens an in-memory session conn (opt)
  :listen  {:payload :basis})    ; datom listen opts (opt)
```

`deflive` expands to a `defserver`. Mount is the trap it closes by
construction: `mount` renders and never fires an event, so a write at mount is
unrepresentable.

### The whole app: `live.app`

`live.app` lifts routing, guarded multi-tenancy, and the web frame into one
value, so a screen cannot get them wrong:

```clojure
{:home      "/app"
 :routes    [["/app" home] ["/lib/:lib" library] ["/e/:lib/:id" entity]]
 :principal (fn [conn] me)                    ; who is asking (cookie/header)
 :worlds    (fn [me params] {:control db …})  ; the GUARDED worlds this me may read
 :observe   (fn [me] [conn …])                ; conns to listen to for liveness
 :intents   {:ingest/confirm confirm}}        ; the only writes

(live.app/serve my-app {:port 4040})
```

A screen is then a pure function of its context map:

```clojure
(app/defscreen entity [{:keys [me params db]}]
  (let [lib (db :library)]          ; already guarded for `me`
    (page (usage-history (pull lib (:id params))))))
```

`:worlds` hands a screen only the worlds its principal may read, so a
cross-tenant read is *unrepresentable*, not merely forbidden. `:observe` is the
liveness set; `:principal` resolves the viewer from the request. `defscreen`
and `defview` name a role and expand to `defn` — a view is just a function.

---

## 8. The view — hiccup

A view returns hiccup: nested vectors of `[tag attrs children…]`.

```clojure
[:main {:class "myapp"}
 [:section {:class "panel"}
  [:ul
   (for [t tasks]
     [:li {:key (:slug t) :data-slug (:slug t)}
      [:h3 (:title t)]
      [:button {:type "button" :on-click [:intent :move {:slug (:slug t)}]}
       "move"]])]]]
```

- **Key every list item.** The diff matches children by `:key`; without one a
  re-sorted list is rewritten instead of moved. Keys are the difference between
  a minimal patch and a full re-render.
- **An `:on-*` value is an event term, not a callback** — `[:intent :op {…}]`,
  `[:assign [:draft] "text"]`, `[:navigate "/next"]`, or a vector of them. The
  vector runs in order, and a denied or no-op intent stops it.
- **A button is a component, not a string of HTML.** `loom.ui` and `loom.box`
  build accessible controls (`(ui/button {:variant :primary :on-click …} "go")`)
  and read their colors through `loom.token`, so a brand is one value.

`live.hiccup/hiccup->html` renders a tree to a string for the first paint
(SSR); on updates the same tree is diffed by `live.diff`, and the browser half
(`priv/lib/live/client.js`) applies the patch ops to the live DOM. `:mount` is
full HTML, `:patch` is a list of ops, and nothing re-renders the page.

---

## 9. Boot — one file that serves

An app boots from a `.bl` file: connect the worlds, load the corpus, define the
app, serve.

```clojure
(ns myapp.main
  (:require [live.app :as app] [datom] [web]))

(def conn
  (datom/connect-with (datom.store-fjall/open "data/myapp.fjall")
                      myapp.schema/all))

(datom/transact! conn myapp.corpus/seed)   ; idempotent: unique-identity upserts

(def my-app
  {:home      "/"
   :routes    [["/" home]]
   :principal (fn [conn] (web/req-cookie conn "who"))
   :observe   (fn [me] [conn])
   :intents   {:create myapp.intent/perform}})

(app/serve my-app {:port 4040})
```

Nothing here is Elixir. Run it with:

```sh
bl run myapp/main.bl        # run once and exit
bl serve myapp/main.bl      # run, then park the VM so the server keeps answering
bl serve myapp/main.bl --port 8080
```

`bl serve` supplies the half a program cannot: a server that returns leaves
nothing holding the BEAM open, so `bl serve` parks it until Ctrl+C. A
handler-only server is the same story with `web/serve`:

```clojure
(web/serve {:port 4000 :plug my-router})
```

Organize the app as namespaces loaded in dependency order (schema → store →
read → intent → ui → main); `bl serve`/`bl run` loads them from the `:require`
graph. There is no `Application.start/2` and no supervision tree to edit — one
file, one call.

---

## 10. Verification — four rungs, cheapest first

### (a) Domain tests, over a real store

Queries take a db **value**, so most of the app is testable with no process:
`(datom/connect schema)` opens an in-memory store, and `(datom/db conn)` is a
value.

```clojure
(def conn (datom/connect myapp.schema/all))
(datom/transact! conn myapp.corpus/seed)
(is (= [["Ada"]] (vec (myapp.read/unrealised-components (datom/db conn)))))
```

Do not mock. A query that passes against a substitute proves something about
the substitute.

### (b) The socket loop, headless

A socket's sink is a pid, so the whole loop runs in a test with no browser and
no channel: `mount` pushes `[:mount html]` to you; `on-commit` pushes
`[:patch ops]`; `handle-event` is a plain call.

```clojure
(def me (erlang/self))
(def st (sock/mount {:view board :shared conn :sink me :intents {:create perform}}))
(receive [:mount html] …)
(def st2 (sock/handle-event st [:intent :create {:title "write tests"}] {}))
(sock/on-commit st2)
(receive [:patch ops] …)
```

`test/bl/live/socket_test.bl`, `session_test.bl`, and `resume_test.bl` are the
reference. Reconnect is testable the same way: `detach` then `attach`, and
assert the delta — and that a guessed session id is refused.

### (c) The app boundary

`test/bl/live/app_test.bl` and `app_context_test.bl` drive `live.app/router`
directly: server-rendered HTML for a route, `/client.js`, and the `/ws`
upgrade. Assert the frames, not a browser.

### (d) The examples, and a browser

`bl examples examples/live` runs every example in isolation;
`examples/live/11-pulse-app.bl` is the worked app. Rendering is the one thing
the rungs above cannot assert, so one browser test exists:
`test/browser/connect.spec.js` (the session id rides every socket URL).

---

## 11. Build and ship

`bl build` AOT-compiles namespaces to `.beam` modules, in dependency order,
and writes a manifest; a second run is a no-op and a body edit rebuilds exactly
one file.

```sh
bl build src --out build
bl build src --out build --force
```

Put the built beams on a program's code path with `--code-path DIR` or
`BEAM_LISP_CODE_PATH`. To ship one file that runs with no Erlang installed,
`./bin/bl self-build` assembles a self-extracting `bl` drop. `bl doctor` reports
what a machine can do before you run anything (`datom_fjall loaded`, `z3 sat`,
…). See `docs/bl/05-shipping.md` for the flags.

---

## 12. The order to build in

Each step is verifiable before the next exists, which is the point of the
ordering.

| # | build | verify with |
|---|---|---|
| 1 | `schema.bl` — the attributes | a test asserting on the value |
| 2 | `work.bl` — rules as maps | pure unit tests, no store |
| 3 | `read.bl` — queries over a db value | `datom/connect` in memory |
| 4 | `store.bl` — the `defserver` | start, write, read back, restart |
| 5 | `intent.bl` — `tx-for` pure | table-driven tests, no substrate |
| 6 | `intent.bl` — `perform` | a socket test with a bare pid sink |
| 7 | `ui/board.bl` — the view, a pure fn | call it with `=` on a test db |
| 8 | `ui/board.bl` — `deflive` + intents | the socket loop, headless |
| 9 | `main.bl` — worlds, corpus, serve | `bl serve`, open a browser |
| 10 | router, principal, shell, theme | `app_context_test` + a browser |

**Steps 1–7 need no page. Steps 1–5 need no process.** That is the dividend
of "every query takes a value" and "every rule is a map": most of an
application is testable before any of it is wired.

---

## 13. Checklist of the traps, in one place

| trap | symptom | rule |
|---|---|---|
| unkeyed list in a view | a reorder rewrites every row instead of moving one | `:key` on every list item |
| an `:intent` expected to render | nothing happens until the commit lands | `:intent` transacts; the commit re-renders everyone |
| a live conn not in `:observe` | the view never learns the world moved | list every conn a socket should react to |
| reusing `db` after a write | the page shows the pre-write world | take a fresh `(datom/db conn)` |
| a refused intent reported as success | the view says "saved", nothing wrote | read `:live/outcome`; a nil tx is a no-op |
| bare `catch` around a write | a failing disk reads as "somebody else changed this" | discriminate on `ex-data` keys |
| missing `datom/release!` | the durable store stays locked against reopening | release in `terminate`; idempotent |
| a db value held on a test stack | the store stays locked, no obvious owner | take the db inside a *function* |
| `(not (nil? (erlang/whereis n)))` | `running?` true for a dead name | compare against `:undefined` |
| absent attribute in a query | the entity binds nothing, blocks nothing | query absence separately; absent = unsafe |
| empty list rendered bare | the best result looks like a crash | compose a verdict sentence server-side |
| `Enum/*` to build a consumed stream | no streaming; buffers, or hangs on an endless upstream | build produced streams with `Stream/*` (lazy) |
| corpus without unique-identity slug | duplicates on every boot | `:db.unique/identity`, upsert |
| two suites sharing a store path | irreproducible, scheduling-dependent | one fjall directory per suite |

---

## See also

- `examples/live/11-pulse-app.bl` — a worked live app, start to finish
- `examples/server/hearth.bl` — HTTP + WebSocket + auth in one file
- `examples/data/studio.bl` — a `live.app` with routes, screens, and intents
- `priv/lib/live/socket.bl` — `deflive`, `mount`, `on-commit`, `handle-event`
- `priv/lib/live/app.bl` — `defscreen`, routes, guarded worlds, `serve`
- `priv/lib/live/diff.bl`, `priv/lib/live/client.js` — the patch, both halves
- `priv/lib/web.bl` — `serve`, `route`, `upgrade`, `sse-open`, cookies
- `priv/lib/datom/store-fjall.bl` — the durable datom store
- `priv/lib/datom.bl` — `q`, `pull`, `as-of`, `since`, `history`, `changes`
- `docs/live-architecture.md` — the whole loop, schematically
