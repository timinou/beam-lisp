# The application is a value

A live app in beam-lisp is one map, and a page is a function of the database.

```
an app      a value     routes · screens · guarded worlds · intents
the world   a value     a datom db, queried in the calling process
a page      a function  (shared-db, session-db, locals) → hiccup
an event    data        [:assign …] · [:intent …] · [:navigate …]
```

Each is ordinary alone. Composed, they say something none of them says:

> **The interface is a value. The database stores values. A basis orders them
> in time. ∴ the application is a value, a page is a projection of (data, who
> is asking), and both are nameable at a point in time.**

Everything below is in the tree, and the examples at the end run.

---

## 1. The writer never projects

datom already keeps a durable, totally-ordered log of facts and lets any
process hold a consistent value of it for free. The one thing it lacked was
the ability to say *"it changed."* `priv/lib/datom/broadcast.bl` adds that:
after a commit, the writer broadcasts a report, and any process can subscribe.

The rule, from that file's own header:

> The writer emits FACTS, never a projection (a projection is a function of
> (data, who is asking), and the writer knows only its half).

As a type, that is the whole idea:

```
page       :  (data, asker)  → DOM
broadcast  :  the moment the data moved     ← facts, not a page
```

Two payload shapes cross the wire:

| payload | is | the reader |
|---|---|---|
| `[:datom/tx basis tx-datoms]` | the delta: the commit's datoms, plus its basis | filters locally, **no store access** |
| `[:datom/changed basis attrs]` | the basis only (`{:payload :basis}`) | re-derives `(as-of db basis)` |

The delta is the default because it is subscriber-agnostic and query-free for
the reader: the store already produced `:tx-datoms`, and the writer emits them
without knowing who asks. Basis-only is the knob for a large write, or a
subscriber that will re-derive a complex view from a coordinate anyway.

Why it must be facts: the same task at the same instant offers `[doing dropped]`
to a tech lead and `[dropped]` to a product lead. Broadcast a rendered board
and one of them is looking at the other's answer. So the message is the delta,
and each reader recomputes *its own* question — in its own process, where "who
is asking" is known.

A `datom/listen!` subscriber reads the delta off its mailbox:

```clojure
(datom/listen! conn {:attrs #{:order/status}})
(receive
  [:datom/tx _basis tx-datoms]
    (doseq [d tx-datoms]
      (when (= :order/status (datom/datom-a d))
        (handle-status (datom/datom-e d) (datom/datom-v d))))
  (after 5000 :idle))
```

---

## 2. A page is a process that mirrors a value

`live.socket` binds a view fn to a conn. The socket is a `defserver` — one
process per viewer — holding a `:view`, a `:shared` world, an optional
per-viewer `:session` world, some `:locals`, the last `:tree` it rendered, and
a `:sink` to ship to.

```
mount        render once → push [:mount html], remember the tree
on-commit    re-render → live.diff → push [:patch ops]
handle-event :assign   → mutate locals, re-render THIS socket now
             :intent   → authorize, transact the shared world (no render)
             :navigate → mutate locals, re-render
```

The inversion is the concurrency model: **a local mutation renders here; a
fact mutation renders everywhere.** A click does not render the clicker's
screen — it requests a fact. The commit broadcasts; every listening socket
re-projects from the new coordinate and ships only the difference. Two tabs
cannot disagree, and a dropped patch is replayable from the basis.

The pieces are each small and each a value:

| idea | what it contributes |
|---|---|
| code as data | a program is a value you can hold |
| datom | a value can be stored, ordered in time, and queried |
| one writer per store | the one moving part, serialised; reads never touch it |
| `live.socket` | a process per viewer whose projection a browser mirrors |
| `live.diff` + `client.js` | the DOM is a projection, patched, never re-templated |

### One moving part

`datom.conn`'s writer is an Agent, and it owns *nothing*: every durable thing
is in the store and the basis is in an atom shared through the registry, so
the process exists purely to serialise. Reads never touch it — `(datom/db
conn)` is O(1), captures a basis, and ten thousand readers proceed in
parallel.

`next-tx-id` is a store counter, allocated **inside** that writer and
recovered from the store on reopen, so the basis is totally ordered across
restarts. Everything downstream rests on that monotonicity: it is why a basis
can be a coordinate rather than just a ping.

---

## 3. The app is a value

`live.app` turns routing, guarded multi-tenancy, liveness, and the web frame
into one map:

```clojure
{:home      "/app"
 :routes    [["/app" home] ["/lib/:lib" library] ["/e/:lib/:id" entity]]
 :principal (fn [conn] me)                    ; who is asking (cookie/header)
 :worlds    (fn [me params] {:control db …})  ; the GUARDED worlds me may read
 :observe   (fn [me] [conn …])                ; conns to listen to for liveness
 :intents   {:ingest/confirm confirm}}        ; the only writes

(live.app/serve my-app {:port 4040})
```

A screen is a pure function of a context map, and the frame guarantees the
hard things so a screen cannot get them wrong:

```clojure
(app/defscreen entity [{:keys [me params db]}]
  (let [lib (db :library)]          ; already guarded for `me`
    (page (usage-history (pull lib (:id params))))))
```

`:worlds` never hands a screen a world its principal may not read, so a
cross-tenant read is *unrepresentable*, not merely forbidden. `:observe` is
the liveness set. `:intents` is the only write path. The whole app is one
value passed to one call.

---

## 4. State has exactly three kinds

The hardest question in any UI framework is "where does state live?" Here the
answer is closed. Three kinds, each with one home:

```
kind      lives in                      lifetime
────────  ───────────────────────────   ──────────────────────
SHARED    the shared datom conn         durable, the log
SESSION   a per-socket in-memory conn   the socket's lifetime
LOCAL     the socket's :locals map      the socket's lifetime
```

- **shared** is the truth everyone sees — a fact in the log, with `q`, `pull`,
  `as-of`, and `watch` for free.
- **session** is this viewer's private database. Same datom API, but the ETS
  table is owned by the socket process, so it is reclaimed when the socket
  ends — leak-free by process lifetime, no cleanup code.
- **local** is a plain map for scalars (a draft, a toggle, `:me`).

There is no fourth "component state" tier. Durable and shared → a fact.
Ephemeral and private → a session datom or a local.

### A guarded live feed

A subscription's filter is the same datalog as a query. `auth/guard` injects a
conjunctive `:where` clause — monotone, so it can only remove rows — and
`datom/watch` runs it as a live feed in its own process:

```clojure
(def feed (auth/guard '[:find ?id :where [?e :doc/id ?id]]
                      [(auth/owner-filter '?e :doc/owner principal)]))
(datom/watch conn feed (fn [diff] (push! principal diff)))
```

A guard clause is conjunctive ⇒ monotone. The property that makes an
incremental live view *sound* is the property that makes it *secure*: one
idea, two guarantees. `datom/watch`'s docstring states the rule it keeps —
the callback receives datoms or result rows, never a projection the writer
computed.

---

## 5. What this unlocks

**(a) The view is time-travellable for free.** `datom/as-of` is O(1) and
copies nothing: a historical value shares the store and differs only in its
basis. Because a view is `(db → hiccup)` and every read takes a db *value*,
the same reader answers about the past. Pin a basis and the page shows
Monday; "as of tx 1000432" is renderable, so "are we looking at the same
thing?" becomes answerable instead of assumed.

**(b) The application is one value.** An app is a map; `live.app/serve` starts
it. The frame — routes, principal, guarded worlds, liveness, intents, the web
shell — is provided once, so a screen is just a function and cannot get
tenancy or liveness wrong.

**(c) One commit, N viewers converge.** Two tabs do not exchange messages;
they re-project from one log. A reconnect re-attaches the same session and
ships the delta since the tree the client last saw — nothing missed ships
nothing.

---

## 6. Reproducing it

The examples run as they are:

```sh
bl run examples/live/05-two-tabs.bl       # convergence through the log
bl run examples/live/06-session-cart.bl   # a per-viewer session datom
bl run examples/live/07-guarded-live.bl   # a guarded view + a denied write
bl run examples/live/08-optimistic.bl     # optimistic UI, rollback from the log
bl run examples/datom/live/10-reactive-socket.bl   # the per-socket binding
bl run examples/datom/live/13-presence.bl          # presence beside a feed
bl serve examples/server/hearth.bl        # a full app, one file
```

---

## The through-line

Clojure's claim is that a program is data. Datomic's is that a database is a
value. LiveView's is that a page is a process. beam-lisp holds all of them in
one shape — an app is a value, the world is a value, and a page is a function
of it — and the small decision at the centre, *broadcast the moment and let
each reader ask its own question*, is what makes the shape load-bearing
instead of merely elegant.

A basis is not a notification. It is a coordinate in the history of a value.

---

## See also

- `priv/lib/datom/broadcast.bl` — the report, delta by default, basis by knob
- `priv/lib/datom/conn.bl` — the single writer, and why the basis is a
  high-water mark
- `priv/lib/datom/watch.bl` — T1 patterns and T2a guarded live queries
- `priv/lib/live/socket.bl` — `deflive`, `mount`, `on-commit`, `handle-event`
- `priv/lib/live/app.bl` — the app as a value: routes, worlds, intents, serve
- `priv/lib/live/diff.bl` — the keyed structural diff
- `docs/datom-as-a-broadcast-substrate.md` — the substrate, three layers deep
- `docs/building-an-app.md` — the practical guide
- `examples/live/` and `examples/datom/live/` — every claim above, runnable
