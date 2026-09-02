# datom as a broadcast substrate

How the BEAM's communication primitives, `auth`'s clause injection, and the
semantic vector search compose into **live, filtered, per-principal
subscriptions over datom** — and why the result is *stronger* than the raw
message-passing it is built on.

> Status: design. Precedes any code. The invariants in §7 are the reviewable
> contract; the plan items (PLAN-044, PLAN-045) carry the build.

---

## 0. The one-sentence thesis

datom is already a communication system wearing a database costume. It keeps a
**durable, totally-ordered log of facts** and lets any process hold a
**consistent value** of it for free. The only thing missing is the ability to
say *"it changed"* — and once that is added, every BEAM broadcast primitive
becomes a **transport** for a fact stream whose ordering, replay, and
consistency the log already guarantees. A dropped broadcast is never a lost
event; it is a slightly slower read.

This document shows the primitives, the seams already in the tree that make the
design fall out rather than get bolted on, and the guarantees datom must
preserve to be *at least as good as the BEAM itself*.

---

## 1. The primitives, three layers deep

Everything on the BEAM is message passing; there is no shared memory. Each layer
below adds ergonomics or reach, never a new semantic.

### 1.1 Erlang — the irreducible set

| primitive | what it is | beam-lisp | in-tree |
|---|---|---|---|
| `Pid ! Msg` | async send, at-most-once, never blocks | `(erlang/send pid msg)` | ✓ `examples/pingpong.bl` |
| `receive … after` | selective mailbox match + timeout | `(receive pat body … (after ms …))` | ✓ `pingpong.bl` |
| `spawn` / `spawn_link` / `spawn_monitor` | isolated process; optional crash/death signal | `(erlang/spawn (fn [] …))` | ✓ `processes.bl` |
| `monitor` → `{:DOWN,…}` | one-way death notice | `(erlang/monitor :process pid)` | ✓ (idea) `examples/datom/07` §6 |
| `register` / `whereis` | **local** name → pid | `(erlang/register :n pid)` | ✓ `priv/lib/datom/conn.bl` |
| `:global` | **cluster** unique name via consensus (CP) | `(global/register_name :n pid)` | — |
| **`:pg`** | **process groups — the native 1→N broadcast** | `(pg/join grp (erlang/self))` then send each of `(pg/get_members grp)` | — |
| `:erpc` / `:rpc` | call a fun on another node | `(erpc/call node m f args)` | — |
| `net_kernel` / `monitor_nodes` | cluster membership up/down | `(net_kernel/monitor_nodes true)` · `(erlang/nodes)` | — |

The one to notice: **`!` is strictly point-to-point; `:pg` is the only *native*
fan-out**, and it is the layer Phoenix.PubSub's default adapter sits on.

```clojure
;; :pg — the Erlang broadcast, in beam-lisp.
(pg/start_link)                               ; once, under a supervisor
(pg/join :orders (erlang/self))               ; subscribe = join a group
(doseq [pid (pg/get_members :orders)]         ; broadcast = send each member
  (erlang/send pid [:order-created 42]))
```

### 1.2 Elixir — the same primitives, better hands

| Elixir | over which primitive | beam-lisp | in-tree |
|---|---|---|---|
| `GenServer.call/cast` | `!` + `receive` + monitors | `(server-call s m)` / `(server-cast s m)` | ✓ `examples/server.bl` |
| `Agent` | a GenServer holding state | `(Agent/update box (fn [s] …))` | ✓ `processes.bl`, `conn.bl` |
| `Task` / **`Task.async_stream`** | `spawn_monitor` + `receive` | `(Task/async_stream coll f)` | ✓ `examples/datom/07`,`08` |
| **`Registry`** (`:unique` / `:duplicate`) | ETS + monitors | `(Registry/register r k v)` · `(Registry/dispatch r k f)` | — |
| `DynamicSupervisor` / `PartitionSupervisor` | supervisor + sharding | `(supervise …)` / `(worker …)` | ✓ `supervision.bl` |

`Registry` with **`:duplicate`** keys is Elixir's in-node topic bus: many pids
register the same key, `Registry.dispatch` fans out with a user callback. It is
`:pg` scoped to one node.

### 1.3 Phoenix — cluster pub/sub and replicated presence

Phoenix is a dependency here (`phoenix_pubsub ~> 2.1`; `SpellWeb.PubSub` is
**already in the supervision tree**), and the repo **already uses this exact
pattern** in `lib/beam_lisp/spell/server.ex`.

| Phoenix | adds | beam-lisp | in-tree |
|---|---|---|---|
| **`Phoenix.PubSub`** | topic pub/sub **across the cluster** (`:pg` adapter, or Redis) | `(Phoenix.PubSub/subscribe srv topic)` · `(Phoenix.PubSub/broadcast srv topic msg)` | ✓ (Elixir side, `spell/server.ex`) |
| `broadcast_from` / `local_broadcast` | exclude self / this-node-only | `(Phoenix.PubSub/broadcast_from srv self topic msg)` | — |
| **`Phoenix.Presence`** / `Phoenix.Tracker` | a **CRDT** of who/what is where, cluster-replicated (AP, converges) | `(Phoenix.Presence/track …)` · `(Phoenix.Presence/list topic)` | — |

**The ladder:** `:pg` (native, cluster, no topics) → `Registry` (topics, one
node) → `Phoenix.PubSub` (topics, cluster, pluggable transport) → `Presence`
(topics **+ replicated state**). Each rung trades latency for a stronger
guarantee. The design commits to **none** of them in the layers above L2 — it
picks a rung by *blast radius* at the seam (§5).

---

## 2. The seam already in the tree: `auth` ⋈ `datom`

The reason filtered subscriptions are cheap is that **the filter already
exists**. Study `priv/lib/auth/rls.bl` and `examples/auth/05-rls-filter-your-rows.bl`:

```clojure
;; auth guards a query by INJECTING datalog :where clauses — before it runs.
(def alice-docs
  (auth/guard '[:find ?title :where [?doc :doc/title ?title]]
              [(auth/owner-filter '?doc :doc/owner "alice")]))
;; ⇒ {:find [?title] :where [[?doc :doc/title ?title] [?doc :doc/owner "alice"]]}
(datom/q alice-docs db)   ; the store never selects a forbidden row
```

Two properties make this the load-bearing seam:

1. **A capability and a row filter are the *same value*** — both are datalog
   `:where` clauses, evaluated by the *same* datom engine. "May you?" and "which
   rows?" are one mechanism (`examples/auth/08-the-gateway.bl` fits login + ACL
   + RLS on one screen).
2. **Injection is monotonic on results** (`rls.bl` doc): a conjunctive clause
   can only *remove* rows, never add one. An injected filter *cannot* grant
   access to a row the base query would not have returned. This is the exact
   property a **subscription filter** needs: a subscriber must never be notified
   about a fact its filter excludes.

**∴ A per-principal live subscription is `auth/guard` ∘ `datom/watch`.** The
same clause that scopes a *read* scopes a *feed*, enforced at the datom level,
with no second policy language.

```clojure
;; a live, row-secured feed — one composition, zero new policy engine
(def feed (auth/guard '[:find ?id :where [?doc :doc/id ?id]]
                      [(auth/owner-filter '?doc :doc/owner principal)]))
(datom/watch conn feed (fn [changes] (push! principal changes)))
;; alice's feed can never carry bob's document — the guard clause forbids it,
;; monotonically, by construction.
```

---

## 3. Filters at the datom level: reuse the matcher, don't build a second one

The subscription filter must run **against each committed datom**, not by
re-running a whole query per event. The tree already has the primitive:
`priv/lib/datom/query/engine.bl` → `unify-pattern`.

```clojure
;; engine.bl, today: unify a clause against ONE datom [e a v tx op].
(unify-pattern bindings clause d)   ; ⇒ extended bindings | nil (no match)
```

A subscription's **interest** is a set of `:where` pattern clauses — the *same
shape* `auth/guard` produces. A commit's `:tx-datoms` (already in every
transaction report, `conn.bl`) is a list of `[e a v tx op]`. So the datom-level
filter is:

```
interested?(report, clauses) ≝ ∃ d ∈ report.tx-datoms . clauses unify with d
```

This is O(|tx-datoms| × |clauses|) per commit — cheap, and it reuses the engine
that already exists rather than a parallel matcher that could drift from query
semantics (the same anti-pattern `priv/lib/datom/datalog.bl` documents for the
native fixpoint spike: *"a second engine that must agree"*).

### 3.1 Three filter tiers, cheapest first

The design exposes filters by selectivity, so a subscriber pays only for what it
needs — and the store's own index structure (`priv/lib/datom/index.bl`: EAVT / AEVT
/ AVET / VAET) tells us which tier is cheap.

| tier | interest | test against a commit | cost |
|---|---|---|---|
| **T0 attribute** | `#{:order/status :order/total}` | does any tx-datom's `a` ∈ set? | O(n), a set lookup per datom — the AEVT question |
| **T1 pattern** | `[?e :order/status :shipped]` | `unify-pattern` per tx-datom | O(n×k), reuses the engine |
| **T2 guarded query** | full `auth/guard` `:where` | pattern-prefilter, then re-query only the touched entities | O(n×k) + one narrow query |

T0 is the Datomic `tx-report-queue` filtered by attribute — the 90% case
(*"tell me when any order changes"*). T1 is precise interest (*"…changes to
shipped"*). T2 is a **materialized live view** — the answer set, incrementally
maintained. A subscriber declares its tier; the writer routes accordingly.

### 3.2 The incremental-view escape hatch

For T2 done *right* (recompute only the delta, never the whole answer), the tree
already spiked the substrate: `priv/lib/datom/datalog.bl` exposes
`dl-eval-incremental` (semi-naive maintenance under new base facts, in Rust).
A materialized `datom/watch` view over a recursive rule is
`dl-eval-incremental(rules, edb_before, new_edb=tx-datoms)`. Out of scope for
the first cut (T0/T1 land first), but the seam is deliberately noted so T2 has
somewhere to stand.

---

## 4. The semantic seam: a changefeed that understands "similar"

`examples/semantic/03-hybrid.bl` documents that `similar-to` has **two modes**,
and the second is exactly a filter:

> FREE `?e` → GENERATE (emit k nearest as rows). BOUND `?e` → FILTER (score only
> the entities upstream clauses selected).

A subscription is the bound case. Given a query vector `?q`, the interest
*"notify me when something semantically near `?q` is written"* is:

```clojure
(datom/watch conn
  '[:find ?e ?score
    :in $ ?q
    :where [?e :doc/embedding _]            ; bind the touched entity
           [(similar-to :doc/embedding ?q 0.85) [?e ?score]]]  ; FILTER: score it
  {:in [query-vec]}
  (fn [changes] …))
```

Because embeddings are datoms (`priv/lib/datom/vector.bl`: *"a vector is just a
fact"*), and the vector search NIF scores a **bound** entity set, the changefeed
scores *only the entities in this commit* — not the whole corpus. And because
`similar-to` reads through the db value's basis
(`examples/semantic/10-time-travel-search.bl`), a semantic subscription
**time-travels for free**: a late joiner can replay *"what was near `?q` as of
last week"* with the same clause. No separate vector index to keep in sync with
the feed — the property that section calls out as the thing a bolt-on vector DB
cannot do.

**∴ the same subscription mechanism carries structured, secured, *and* semantic
interest — because all three are datalog clauses over one db value.**

---

## 5. The architecture

```
 L4  Presence / ownership           pid-as-entity (07 §4) ⊕ Phoenix.Presence CRDT / :global
       └─ "which node owns shard S", "who is online" — replicated STATE, AP or CP per use
 L3  Live queries / subscriptions   datom/watch, datom/listen!   (the tx-report-queue, as PUSH)
       └─ interest = auth/guard clauses (T0/T1/T2) matched by engine's unify-pattern
 L2  Transaction-report broadcast   publish-report!   (:pg local · Phoenix.PubSub cluster)
       └─ THE new primitive. Ordered because the writer is single. Payload = DELTA by default, basis by knob (§6).
 L1  Single writer per store        conn.bl writer process        ← serialization = correctness
       └─ vertical scaling: reads are lock-free VALUES; only writes queue
 L0  Storage port (6 methods)       store-ets (now) → store-hobbes (distributed keyspace)
       └─ horizontal scaling: the substrate shards the ordered keyspace
```

### 5.1 Vertical scaling — already correct, needs nothing

Reads are values: `(db conn)` is O(1) and copies nothing (`examples/datom/08`
§5 runs **200 concurrent readers with no pool** — a db value is not a resource).
Only writes serialize, through one process per store. L2 adds a fan-out of N
sends *after* commit, off the hot path — it never blocks the writer (§7.4).

### 5.2 Horizontal scaling — falls out of two existing seams + one rule

- **Shard by store.** The writer and basis are keyed *per store* in the registry
  (`conn.bl`). One store = one ordered writer = one serialization domain. Many
  stores = many independent writers across nodes. Route an entity to its shard by
  a stable key.
- **The substrate distributes.** `priv/lib/datom/store.bl` is deliberately **6
  methods** and targets **Hobbes** (FoundationDB-architecture, strictly
  serializable, distributed ordered keyspace). Horizontal *write* scaling within
  one logical database is the substrate's job; nothing above L0 learns which
  store it has. That boundary is the design's load-bearing wall, and it is
  already built.
- **Cross-shard snapshots via `basis-t` as a vector clock.** A read spanning
  shards pins `{shard → basis-t}` and each shard answers `as-of` its component —
  a consistent distributed snapshot with **no global lock**, the same trick
  `examples/datom/07` §1 uses within one store, lifted to a vector across stores.

### 5.3 Transport picks its rung by blast radius (L2 only)

- same node → `pg/get_members` + `send` (native, µs)
- cross-node, same cluster → `Phoenix.PubSub/broadcast` (its `:pg` adapter is
  already the default; `SpellWeb.PubSub` already runs)
- across clusters / regions → swap the PubSub adapter (Redis) — **zero code
  change above L2**, because L2 only knows *"publish to topic."*

---

## 6. Payload: delta by default; the WRITER never projects (§6.1) — what FEAT-016 really said

`docs/the-application-is-a-value.md` (FEAT-016) is often quoted as *"broadcast
the moment, never the projection"* and read as *"broadcast only a basis."* Those
are not the same claim, and conflating them makes the design needlessly arcane.
Pull them apart. There are **three** things a commit could put on the wire:

| payload | subscriber-agnostic? | writer can emit it? | reader must re-query? |
|---|---|---|---|
| **moment** — `basis` (one integer) | ✓ | ✓ | **yes** — reconstruct `db@basis`, re-run the interest |
| **delta** — the commit's `:tx-datoms` `[[e a v tx op]…]` | ✓ | ✓ | **no** — filter the delta locally |
| **projection** — rows/board for *(query, principal)* | ✗ (picks a principal) | ✗ | n/a |

FEAT-016's **load-bearing** claim is only the last column of row 3: *the writer
must not emit a projection*, because a projection is a function of *(data, who is
asking)* and a writer knows only its own half. That is correct and this design
keeps it absolutely.

But FEAT-016 also chose **moment** (basis-only) for its own payload — and that
choice is **context-specific, not a general law.** Its subscriber is a LiveView
*page*, whose only useful subscriber-agnostic delta *is* a re-rendered board —
which is itself a projection. So for a page there is nothing smaller than
"re-derive," and basis-only is right. For a **datom subscriber**, `:tx-datoms`
*is* the subscriber-agnostic delta: the store already produced it, the writer
emits it without knowing who asks, and it lets the reader answer **without
touching the store.** Forcing basis-only on datom subscribers would manufacture
exactly the extraneous re-query the moment/projection framing was never trying
to impose.

**∴ The rule, stated precisely:**

- **The writer never emits a projection.** (FEAT-016's real kernel — preserved.)
- **L2's default payload is the DELTA** (`:tx-datoms` + basis). Subscriber-
  agnostic, query-free for the reader, bounded by the size of the write. This is
  the common case and it costs the reader no store access.
- **Basis-only is a KNOB, not the default** (`{:payload :basis}`). Use it when the
  write is large, or when the subscriber is a store-replica / complex-view
  consumer that will re-derive from `as-of` anyway — the LiveView case FEAT-016
  was written for. Then the reader does `basis → (as-of db basis) → run interest`.
- **Shared-identical-view fan-out gets a PROJECTOR** (§8.1): a *subscriber* that
  computes one projection once and re-broadcasts it to N identical viewers. It is
  never the writer projecting — it is the system materializing, opt-in, at L3.
  This is the sanctioned answer to "10k viewers of one public board," and it is
  why the writer never needs to.

So the *cross-node* wire is delta-by-default, basis-by-knob; the *same-node* fast
path always carries the delta (local subscribers are in one consistency domain
and the T1 matcher needs `:tx-datoms`). A per-principal RLS feed (§2) is the one
case with **no** single projection to broadcast — there the reader-side filter is
forced by the problem, not by doctrine, and the delta is exactly what it filters.

---

### 6.1 Where projections live — the reactive-binding tiers

"The writer never projects" is scoped to **one process**: the commit path inside
the single-writer Agent (`transact-in-writer`, `conn.bl`). It is emphatically
*not* "no projections exist." Projections — including reactive frontend bindings —
are first-class; they just live one process to the left of the writer. The rule
protects three things, all about *that one process*:

1. **It is blind to consumers.** A projection is `f(data, principal, query)`; the
   writer holds only `data`. To project, it would enumerate every subscriber ×
   query × identity — O(subscribers) work it has no inputs for.
2. **It is the serialized critical section.** Every other write queues behind it.
   Rendering a view there blocks the *next commit* for the render's duration.
   Correctness (write-ordering) and view-rendering must not share a lock.
3. **It must not crash.** A rendering bug in the writer takes down the process
   that holds the ordering guarantee. `let it crash` wants the projector to be a
   *different*, supervised process.

So the real statement is: **keep projection off the serialized correctness path
and out of the layer blind to consumers.** Everywhere else, projections are the
point. There are six canonical shapes; each maps to an `examples/datom/live/`
file so this doc is the spec for how live rendering actually works in beam-lisp.

| case | who projects | for whom | payload it consumes | example |
|---|---|---|---|---|
| **A** per-socket binding | the LiveView / view-server process | one viewer | `:basis` | `10-reactive-socket.bl` |
| **B** shared materialized view | a `defserver` subscriber | N identical viewers | `:tx-datoms` (T0) | `06-projector.bl` |
| **C** diff / patch binding | a `defserver` subscriber | one principal-group | `:tx-datoms` (delta) | `11-reactive-diff.bl` |
| **D** derived state | *the writer, as a FACT* (tx-fn) | everyone | — (it's a datom) | `12-derived-fact.bl` |
| **E** presence binding | `Phoenix.Presence` (CRDT) | a topic's viewers | membership events | `13-presence.bl` |
| ~~writer projection~~ | ~~commit path~~ | ~~—~~ | — | **forbidden** (1–3 above) |

**Case A — per-socket reactive binding.** The canonical frontend case, and where
`:basis` is *optimal*, not arcane: a LiveView re-renders its whole assign map and
Phoenix diffs the DOM, so "reader re-projects from a coordinate" is exactly what
a page already does. This is the shape `lib/beam_lisp/spell/server.ex` runs
today. The projection is per-principal because the *socket process* holds who is
asking — the guard clause the writer never had.

```clojure
(defserver socket-view                    ; models one connected viewer
  (init [ctx]
    (let [principal (:principal ctx)
          q (auth/guard '[:find ?id ?title
                          :where [?doc :doc/id ?id] [?doc :doc/title ?title]]
                        [(auth/owner-filter '?doc :doc/owner principal)])]
      (datom/listen! CONN {:payload :basis})           ; Case A: a basis is enough
      (ok {:id (:id ctx) :q q})))
  (handle-info [:datom/changed basis _attrs]
    [state]
    (let [db   (datom/as-of (datom/db CONN) basis)     ; coordinate → value
          rows (datom/q (:q state) db)]                ; the per-viewer projection
      (Phoenix.PubSub/broadcast SpellWeb.PubSub
        (str "socket:" (:id state)) [:render rows])    ; → LiveView assign → DOM diff
      (noreply state))))
```

**Case B — shared materialized view.** "10k viewers of one public board." Compute
ONCE, fan out. A projection on the wire — legitimately, because the projector is
a *subscriber* that fixed *(query, principal=public)*, not a writer guessing one.
See §8.1.

**Case C — diff / patch binding.** A true reactive binding wants *minimal
patches*, not a full re-render. A projector holds the answer set and emits only
the delta between successive results — and the `:tx-datoms` payload is what makes
the pre-filter cheap (recompute only if this commit *could* touch the answer).

```clojure
(defn- diff [before after]
  (let [b (set before) a (set after)]
    {:added (into [] (remove b a)) :removed (into [] (remove a b))}))

(defserver reactive-feed
  (init [ctx]
    (let [principal (:principal ctx)
          q (auth/guard '[:find ?id :where [?doc :doc/id ?id]]
                        [(auth/owner-filter '?doc :doc/owner principal)])]
      (datom/listen! CONN {:attrs #{:doc/owner :doc/id}})    ; delta path
      (ok {:principal principal :q q
           :answer (set (datom/q q (datom/db CONN)))})))
  (handle-info [:datom/tx _basis tx-datoms]
    [state]
    (if (touches? tx-datoms (:principal state))            ; cheap prefilter on the DELTA
      (let [next (set (datom/q (:q state) (datom/db CONN)))
            d    (diff (:answer state) next)]
        (when (or (seq (:added d)) (seq (:removed d)))
          (Phoenix.PubSub/broadcast SpellWeb.PubSub
            (str "feed:" (:principal state)) [:patch d]))   ; the reactive binding
        (noreply (assoc state :answer next)))
      (noreply state))))
```

Write → delta → per-principal projector diffs → minimal patch → DOM. The delta,
not the basis, is what keeps the prefilter O(tx-datoms) instead of O(corpus).

**Case D — derived state is a FACT, not a projection.** When the frontend binds to
a value that is a function of other facts (`:order/total` = Σ line items), do
*not* "project at write." Record it as a datom via a tx-fn (`register-tx-fn!`,
already in the tree). Then it broadcasts through the ordinary delta and every
binding above sees it with zero special-casing.

```clojure
(datom/register-tx-fn! CONN :recalc-total
  (fn [db order] [[:db/add order :order/total (sum-line-items db order)]]))
;; the total is a normal datom now — delta-carried, watchable, time-travelled.
```

This is the boundary line: **the writer emits facts (which may be *derived*);
projectors and readers emit views.** Derived-at-write is a fact; derived-per-
viewer is a projection.

**Case E — presence binding.** "Who is looking at this?" is replicated *state*, not
a message, so it is a CRDT (`Phoenix.Presence`) at L4 — not a datom broadcast.
A presence binding and a datom binding compose on one page: the datom feed says
*what the data is*, presence says *who else is here*.

```clojure
(Phoenix.Presence/track (erlang/self) "doc:42" principal {:cursor 0})
(Phoenix.Presence/list "doc:42")     ; → reactive "3 people editing" binding
```

The synthesis: the **writer emits facts** (delta/basis — cheap, consumer-blind,
on the correctness path); **projections live at the reader (A), a shared
projector (B/C), or a CRDT (E)**; **derived state is pushed back as a fact (D)**.
Basis-vs-delta is a per-binding knob, not a doctrine — A wants basis, C wants the
delta, and both are reactive frontend bindings.

---

## 7. The contract — why this is *at least as good as the BEAM*

Raw `!` / PubSub is **at-most-once, no replay, no ordering across senders**.
datom's log makes the broadcast a *cache of a durable, totally-ordered fact
stream*. Each invariant below is testable and is the actual acceptance bar.

| guarantee | raw BEAM send / PubSub | datom-over-the-same-transport |
|---|---|---|
| **Ordering** | none across senders | **total** — one writer per store stamps monotonic `basis-t`; reports leave in commit order |
| **Delivery** | at-most-once, silent drop | at-most-once *broadcast* **backed by replay** → **effectively exactly-once** |
| **Late joiner** | sees nothing before subscribe | subscribes *and* replays from any basis via `as-of`/`since` — no cold-start gap |
| **Causality** | none | `basis-t` is a logical clock; read-your-writes is `(>= observed-t my-write-t)` |
| **Crash recovery** | in-flight message lost | the fact is in the log; a restarted subscriber resumes from its stored `basis-t` |

### The five invariants L2/L3 must hold

1. **Report order = commit order.** Guaranteed *iff* `publish-report!` runs
   inside the writer's serialized step (it does). Inherit the ordering from the
   single writer; do not reinvent it.
2. **No broadcast on a failed or speculative tx.** `with` (speculative,
   `conn.bl`) and `run-tx-pipeline` must **never** publish. Publish only on the
   real `transact!` commit path, after the basis high-water mark advances.
3. **A subscriber never sees an undetectable gap.** Every notification carries
   the new basis. A subscriber compares it to its last-seen `t` and replays
   `(datom/since db last-t)` on any jump. **Broadcast is an optimization; the log
   is the truth.** A dropped message degrades to a slower read, never a lost
   event.
4. **Backpressure is the subscriber's, never the writer's.** Fan-out is `send`
   (never blocks) or `Task.async_stream` with bounded `:max_concurrency`. A slow
   subscriber's mailbox grows; the writer is untouched. A subscriber that cannot
   keep up degrades to *polling the log* — same data, slower.
5. **Ownership/presence is a CRDT or a `:global` name, never a plain map.**
   Shard→node ownership must survive netsplits: `Phoenix.Tracker`/`Presence` (AP,
   converges) or `:global` (CP, consensus). *A map in one Agent is not an option
   across nodes.*

---

## 8. The public surface (proposed)

Thin additions, mirroring Datomic's `tx-report-queue` but **push, not pull**,
delta-by-default, and transport-pluggable:

```clojure
;; priv/lib/datom/conn.bl — one new seam, inside the writer, after a real commit.
;; DEFAULT payload is the DELTA (§6). Same-node always gets it; cross-node gets
;; it too unless a subscriber asked for :basis.
(defn- publish-report! [conn report]
  (let [topic (report-topic (:store conn))
        delta [:datom/tx (datom/basis-t (:db-after report))  ; basis, for gap-detect
                         (:tx-datoms report)]]                ; the delta itself
    (doseq [pid (pg/get_members topic)]                    ; L2 local: always delta
      (erlang/send pid delta))
    (when-let [ps (pubsub-server conn)]                    ; L2 cluster, opt-in
      ;; delta by default; a basis-only topic exists for subscribers that chose
      ;; {:payload :basis} — large writes, or replica/complex-view consumers.
      (Phoenix.PubSub/broadcast ps topic delta)
      (Phoenix.PubSub/broadcast ps (basis-topic topic)
        [:datom/changed (datom/basis-t (:db-after report)) (changed-attrs report)]))))

;; priv/lib/datom.bl — the facade surface
(datom/listen!   conn)                       ; delta stream: [:datom/tx basis tx-datoms]
(datom/listen!   conn {:attrs #{…}})         ; T0: only commits touching these attrs
(datom/listen!   conn {:payload :basis})     ; the KNOB: basis-only, reader re-derives
(datom/unlisten! conn)
(datom/watch     conn guarded-query f)       ; T1/T2a: filtered, per-principal live query
(datom/watch     conn q {:in [vec]} f)       ; semantic: similar-to as a filter (§4)
(datom/unwatch   conn watch-ref)
```

Consumer side is a plain `receive` or a `defserver handle-info` — the shape
`spell/server.ex` already uses for `spell/changed`. The default path reads the
**delta**, never touching the store:

```clojure
(datom/listen! conn {:attrs #{:order/status}})
(receive
  ;; delta in hand — no re-query, no as-of, no store access
  [:datom/tx _basis tx-datoms]
    (doseq [d tx-datoms]
      (when (= :order/status (datom/datom-a d))
        (handle-status (datom/datom-e d) (datom/datom-v d))))
  (after 5000 :idle))

;; a defserver whose state IS a db value (examples/datom/08 §3), now LIVE.
;; It keeps the whole value because it answers arbitrary queries; a narrower
;; subscriber would keep only the delta.
(defserver order-view
  (init [db] (do (datom/listen! CONN {:attrs #{:order/status}}) (ok db)))
  (handle-call [:q query] [_from db] (reply (datom/q query db) db))
  (handle-info [:datom/tx _basis _datoms] [db] (noreply (datom/db CONN))))
```

### 8.1 The projector — compute once, fan out to identical viewers

The answer to *"10k viewers of one identical public board"* is **not** to push a
projection through the writer (§6 forbids it) and **not** to make 10k processes
each re-derive. It is one **projector**: a subscriber that computes the shared
projection once and re-broadcasts it. The writer never projects; the *system*
materializes, opt-in, at L3.

```clojure
(defserver leaderboard-projector
  (init [db] (do (datom/listen! CONN {:attrs #{:score/points}}) (ok db)))
  (handle-info [:datom/tx _basis _datoms]
    [_db]
    (let [db    (datom/db CONN)
          board (datom/q '[:find ?player (sum ?p)
                           :where [?player :score/points ?p]] db)]
      ;; computed ONCE; every identical viewer gets the finished board
      (Phoenix.PubSub/broadcast SpellWeb.PubSub "leaderboard" [:board board])
      (noreply db))))
```

This is a projection on the wire — legitimately, because a projector is a
subscriber choosing to share a view whose *(query, principal)* it fixed, not a
writer guessing one. Per-principal feeds (§2) cannot use it (no shared
projection); public shared views should.

---

## 9. What each part of the tree contributes (the join)

| in-tree fact | what it gives this design |
|---|---|
| `conn.bl` single writer + monotonic basis | free **total ordering** of the feed |
| `conn.bl` tx report `:tx-datoms` / `:db-after` | the event payload already exists |
| `auth/rls.bl` monotonic clause injection | **filters = security**, one policy language |
| `query/engine.bl` `unify-pattern` | the datom-level matcher, already written |
| `datom/index.bl` EAVT/AEVT/… | tells us which filter tier is cheap |
| `datom/vector.bl` `similar-to` bound mode | a **semantic** changefeed for free |
| `datom/datalog.bl` `dl-eval-incremental` | the substrate for true T2 view maintenance |
| `store.bl` 6-method port → Hobbes | **horizontal** scaling lives below L0 |
| `spell/server.ex` `Phoenix.PubSub` + FEAT-016 | the cluster transport, and the *writer-never-projects* rule (§6) |
| `examples/datom/07`,`08` | pid-as-entity, db-value-as-state — the L4 shape |

Nothing here is a new subsystem. datom does not need to *become* a message bus;
it needs to **admit it already is one** and expose the seam — an ordered log,
made observable, with the filter and the security it already had.

---

## See also

- `priv/lib/datom/conn.bl` — the single writer, the basis high-water mark, the tx report
- `priv/lib/auth/rls.bl`, `examples/auth/05`,`08` — clause injection, "may you?" ⋈ "which rows?"
- `priv/lib/datom/query/engine.bl` — `unify-pattern`, the matcher this reuses
- `priv/lib/datom/vector.bl`, `examples/semantic/03`,`10` — similarity as a filtering clause
- `docs/the-application-is-a-value.md` — FEAT-016, *broadcast the moment, never the projection*
- `lib/beam_lisp/spell/server.ex` — `Phoenix.PubSub` subscribe/broadcast, already in the tree
- PLAN-033 (Hobbes substrate), PLAN-044 (L2 broadcast) / PLAN-045 (L3 filtered watch)
