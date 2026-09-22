# An API is a relation

Connecting beam-lisp to Google Workspace — and to every other large provider —
is not an HTTP client problem. It is a **scheduling, metering, and reconciliation**
problem wearing an HTTP client's clothes. This document designs the substrate for
that, and the surface an app author actually writes.

It rests on four things this tree already has, each built for a different reason,
each landing exactly on a seam this needs:

| seam | what it is | why it is the right shape here |
|---|---|---|
| **`veritas`** (`priv/lib/veritas.bl`) | one verb over typed generators; a contract run backwards *is* a deterministic server; the fault space is `∃¬`; a property is behaviour | a provider's schema **is** a generator; its errors **are** a fault space; its pagination **is** a property |
| **datom relations** (`priv/lib/datom/query/relation.bl`) | `(provider db mode bound args) → tuples`; the adornment picks generate / probe / reverse; `[?a :~x ?b]` joins stored facts | a remote API is exactly this — and the **adornment is the call optimizer** |
| **`proc`** (`priv/std/proc/*`) | pull-based `flow`, a declared `pipeline`, a durable `queue` with retry/backoff/jitter/uniqueness/lease/partition, `reg`, `super`, `table`, `fence` | the transport wants to be a **living, metered, backpressured, observable subsystem**, not a function call |
| **`auth` + `datom`** (`priv/lib/auth.bl`) | a credential is a capability; offline TTL vs online revocation is a *stance*; a decision is reproducible `as-of` a basis | a credential's whole life becomes a **temporal fact**, and RLS governs who may read it |

Read `one-verb-over-generators.md`, `auth-the-application-authorizes-itself.md`,
and `auth-downstream-a-breeze.md` first. This document extends their thesis to the
remote boundary and refuses to add vocabulary they already own.

---

## 0 · The one rule

> **A connector's public face is a relation. There is no client API.**

There is no `connector/call`. There is no second way to reach a provider. A
one-shot read is a fully-bound query; a list is a partially-bound query; a stream
is a query whose rows arrive over time; a write is an assertion into the same
subject space. When two spellings exist they must lower to the *same* provider —
the way `[?a :~similar ?b]` and `[(:~similar) [?a ?b]]` are one relation with two
spellings and not two implementations.

Three things fall out of that rule, and they are the whole design:

1. **The sandbox needs no feature flag.** `veritas.mock` registers the *same
   relation ident* with a contract-backed provider. Every query above it is
   unchanged; nothing anywhere asks *am I mocked?* — because there is nothing to
   ask.
2. **Joins are free.** A query that mixes mirrored Drive facts with local ones is
   one `:where` clause. There is no "fetch then join" boundary to write.
3. **The cache is not an optimization bolted on — it is a layer of the answer.**
   §3.

### How a familiar call shape is still sugar

There is a real question here, because `(conn/one c :gmail.messages.get {:id "18c…"})`
*looks* like a method call — and a method call free-standing would be exactly the
parallel implementation this document forbids. It is sugar **only if it lowers to
the same provider**. So make that structural, in the spec:

```clojure
:gmail.messages.get
{:http   [:get "/gmail/v1/users/{userId}/messages/{id}"]
 :result :message
 :as     {:relation :~msg/messages :mode :bb}}   ; ← what this method IS (§1, T3→T2)
```

`(conn/one c :gmail.messages.get {:id "18c…"})` is now *definitionally* "run
`:~msg/messages` with the key bound, take the head". Same provider, same
transport, same budget line, same cache entry, same mock registration — because
there is exactly one of each.

That generalises past CRUD, and the generalisation is the design:

| method kind | the relation | the subject column |
|---|---|---|
| read one resource | `:~msg/messages` `:bb` | `:conn/key` — the composite, so two providers cannot collide |
| list | `:~msg/messages` `:bf` | — (free) |
| **cursor walk** (`history.list`, `changes.list`) | `:~msg/changes` | a **cursor entity** — the relation is finite per query and a cursor is a value |
| **computation** (`calendar.freebusy`) | `:~sched/freebusy` | a **query entity** — the request is a fact, so the answer can be a relation |
| **action** (`gmail.send`, `files.create`) | an **intent** (§3) | the intent fact |
| **media** (`files.export`) | `:~file/bytes` | the file, plus an ordering column |

These are **domain** relations, not the service's: the Gmail spec and the Graph spec
bind their methods onto the *same* `:~msg/messages`. That is §1's middle tier doing
its job — see it there.

Every method is *some* relation's adornment. A method that is not is a spec
error, and the spec validator refuses it — which is what keeps the rule from
eroding the first time something is awkward.

### One universal surface, providers as extensions

The core knows five verbs and no service:

```clojure
(conn/open     spec cfg)            ; a connection — a named process (§6)
(conn/have!    c aspect params)     ; make the mirror able to answer      — NOW
(conn/keep     c aspect opts)       ; keep it fresh                       — FROM NOW ON
(conn/put!     c method params)     ; an intent; it settles
(conn/query-of c method params)     ; a call AS A QUERY — a value, not a side effect
```

There is deliberately **no `conn/q`**. `defrelation` registers a relation
*process-wide*, so plain `datom/q` already reaches every connector relation over
the same engine; a query verb here would shadow a verb the language has — the
anti-pattern `data.config`'s own doc names (*"a new verb per type"*, and its
opening story about a module that shadowed `get`/`set`). **A connector's
contribution is relations, not verbs.** `conn/one` exists as a one-liner over
`query-of` (§3) — a calling convention, not a core verb.

Provider namespaces add **specs (T3)**; the relations they bind onto are **domains
(T2)** — `:~msg/threads`, `:~sched/instances`, `:~file/files`. No provider fact
enters the core, and a second provider (Graph, IMAP, S3) adds **no verbs and no
relations**: it adds a spec whose `:as` maps its methods onto relations that already
exist. A provider namespace extends the *spec* vocabulary — never the verb set, and
never the domain model.

---

## 1 · A spec is a value, and the spec is the API

A **spec** describes one service. It holds what a Discovery document holds, plus
the three things a Discovery document *does not*:

```clojure
{:service :drive
 :version "v3"
 :base    "https://www.googleapis.com"
 :auth    :oauth2-user                      ; §6
 :quota   {:unit        :u                  ; the charge unit
           :per-project 1000000             ; units / minute / project
           :per-user    325000              ; units / minute / user
           :charge-by   :quotaUser}         ; the param that attributes the charge

 :resources
 {:file   {:key :id    :fields {:id :string :name :string
                                :mimeType :string :modifiedTime :instant
                                :parents [:string] :size :long}}
  :change {:key :token :fields {:fileId :string :removed :bool :time :instant}}}

 :methods
 {:files.list
  {:http    [:get "/drive/v3/files"]
   :query   {:q :string :pageSize :int :fields :string}
   :result  :file
   :cost    100                               ; quota units — from Google's own table
   :page    {:kind :page                      ; ← one of three cursor algebras (§2)
             :token :pageToken :next :nextPageToken}
   :scopes  #{:drive.readonly :drive.metadata.readonly}}

  :files.get
  {:http   [:get "/drive/v3/files/{fileId}"]
   :cost   5
   :result :file
   :cache  :validated                         ; ETag / If-None-Match (§3)
   :scopes #{:drive.readonly}}

  :changes.list
  {:http   [:get "/drive/v3/changes"]
   :cost   100
   :result :change
   :page   {:kind   :sync-token
            :token  :pageToken
            :next   :nextPageToken
            :commit :newStartPageToken        ; the value to PERSIST at end-of-run
            :start  :changes.getStartPageToken
            :stale  nil}                      ; Drive documents the token as non-expiring
   :scopes #{:drive.readonly}}}

 :errors
 {:usageLimits/rateLimitExceeded     {:on [403 429] :do :budget-hold}
  :usageLimits/userRateLimitExceeded {:on [403]     :do :budget-hold}
  :global/insufficientPermissions    {:on [403]     :do :fail}
  :notFound                          {:on [404]     :do :fail}
  :authError/invalid_grant           {:on [401]     :do :refresh-credential}}}

 :push {:kind :channel :renew-after "PT23H" :receive :pubsub}}
```

Two facts about Discovery, measured 2026-09-21, decide the build order:

- **It is small.** Drive v3 is 269 KB (36 KB gzipped), Gmail v1 218 KB, Calendar
  v3 170 KB — 54/56/39 schemas, 64/79/38 methods. The atom-exhaustion worry is
  mild, not structural.
- **It carries schemas, methods, parameters and scopes — and *nothing else that
  matters*.** There is no machine-readable pagination block (pagination is a
  `pageToken` convention plus a `nextPageToken` property); there is **no error
  schema at all**; there is no quota table. Those are `:page`, `:errors`, `:quota`
  above — the three sections that carry the integration's actual difficulty — the fourth
being `:as` (§0), which binds each method to the relation and mode it *is*.

∴ **Hand-author the spec first.** What makes a Google integration rot is not the
missing `File` schema; it is the three hand-copied sections nobody maintains. Get
those right by hand for two services, then let an importer fill in the mechanical
four-fifths.

### A spec is not a sixth shape language

`auth-downstream-a-breeze.md §0` forbids this, and it still applies: a spec's
`:fields` lower to the **same field-metadata vocabulary** the shape system uses
(`:string :integer :keyword :instant :ref`, open maps, `:sensitive` absolute).
A spec is a *shape with remote meaning attached* — `:cost`, `:cache`, `:page` —
exactly as `defresource` is a shape with storage and auth meaning attached.

### Three tiers: universal → domain → service

Attribute placement is decided by one question asked in order, and it is the
reason a query can span providers — see **`docs/connectors/three-tiers.md`** for
the full model (the placement test, the three rules, all three packs, and how the
tiers are enforced). The short version:

```
T1  UNIVERSAL   :conn/*        every remote resource
T2  DOMAIN      :msg/*  :sched/*  :file/*  :person/*   what KIND of thing
T3  SERVICE     :gmail/*  :gcalendar/*  :gdrive/*  :graph/*   the quirks
```

Relations are **T2**, specs are **T3**, and `:as` is the adapter — so
`[?m :~msg/messages ?subject …]` returns Gmail and Graph messages alike, told
apart by `:conn/service`, and the same `:where` clause runs against either.

### Calendar lands on `datom.time`, and it is not a metaphor

Google's `EventDateTime` is `{dateTime, timeZone, date}` — and `datom.time`'s
`interval` takes a **resolution** (`:year :month :day :hour :minute :second`). An
all-day event is a **day-resolution interval**; a timed event a
**second-resolution interval**; and the constructor's own docstring says *"an
instant one second"*, so a point is the finest resolution. One attribute — and it
is **T1**, because everything on a timeline has one (§1):

```clojure
{:db/ident :conn/when :db/valueType :db.type/time :db/index true}
```

That it is T1 rather than `:sched/when` is the point: `:db.type/time` is *"ordered
by (from,to), so — unlike a vector — it CAN be AVET-indexed and range-scanned"*, so
`[?x :conn/when ?w] [(time/overlaps? ?w ?meeting)]` is **one clause over one
indexed attribute** — across mail, events and files alike.

Three more mappings, each exact:

| Google | datom | why it is exact |
|---|---|---|
| `recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=…"]` | `datom.recur` | the field is literally *"RRULE, EXRULE, RDATE and EXDATE lines … as specified in RFC5545"*, and `datom.recur` is an RFC5545 parser/expander |
| `recurringEventId` | `:sched/recurring-of` `:db.type/ref` | an instance is an entity pointing at its master |
| `start`/`end` going forward | **the transaction's valid-time window** | an event's truth-interval *is* `:db.valid/from`/`:db.valid/to` |

That last row is the one to dwell on. §2 was about cursors; this is about **what a
calendar event IS**. An event has a window in the world, and datom has a *second
time axis* for exactly that. So:

- `(time/valid-at db t)` — **what is on the calendar at `t`**. Not "events whose
  start falls in the next 7 days": the actual overlap filter, across every service.
- `(time/valid-at (time/as-of db tx) t)` — **what did we BELIEVE at `tx` was on the
  calendar at `t`**. This separates *the meeting moved* from *we learned it moved* —
  and no Google field can tell you, because `updated` says only that something did.

And freebusy stops being an endpoint. `:~sched/freebusy` is `datom.time`'s
**interval-set algebra** over mirrored events: `set-union` the busy intervals,
`set-complement` the working window, `set-measure` the answer. `overlaps?`,
`meets?`, `overlap-verdict`, `consistent?` are the scheduling predicates, already
written. **A recurring standup mirrored once answers "was I busy on 2027-03-04"
with zero API calls**, because `datom.recur` expands the rule and the algebra does
the rest — where a Google client needs a `list` with `timeMin` and a round trip.

### Drive lands on `datom.file`, and closer than expected

`datom.file`'s docstring states the constraint that shapes it: *"a file is a FACT;
its bytes are not."* A file datom holds a ~50-byte content-addressed descriptor
`{sha size media-type}`; the bytes live in the connection's blob store. Content
addressing buys four things, and every one is a Drive requirement:

```
immutable   → `as-of` resolves the SAME bytes forever; history never lies
dedup       → the same PDF in Drive and attached to a mail costs ONE blob
idempotent  → a retried upload is a no-op, never a duplicate
"edit"      → assert a NEW DFile; the old fact is retracted like any other
```

Then the finding that makes this a non-event: **Drive's `File` schema carries
`sha256Checksum`, and datom's content address IS sha256** (verified against the
live Discovery document, 2026-09-21). So the descriptor is written **from metadata
alone, without downloading a byte**:

```clojure
;; T1 — has bytes
{:db/ident :conn/content :db/valueType :db.type/file}   ; {sha size media-type}

;; T2 — the file domain. datom.file's docstring already names the first of these:
;;      "look files up by a sibling :file/sha string attribute if you need to",
;;      because a file descriptor is a MAP with no meaningful order and is therefore
;;      never AVET-indexed. The string sibling is what makes it findable.
{:db/ident :file/sha     :db/valueType :db.type/string :db/index true}
{:db/ident :file/mime    :db/valueType :db.type/string}
{:db/ident :file/size    :db/valueType :db.type/long}
{:db/ident :file/parents :db/valueType :db.type/ref :db/cardinality :db.cardinality/many}
{:db/ident :file/trashed :db/valueType :db.type/bool}

;; T3 — only what is genuinely Google's
{:db/ident :gdrive/md5          :db/valueType :db.type/string}  ; a fallback identity
{:db/ident :gdrive/app-props    :db/valueType :db.type/term}
{:db/ident :gdrive/export-links :db/valueType :db.type/term}    ; Docs/Sheets have no bytes
```

Three consequences:

- **`file-bytes` returns nil until the bytes are pulled, and that is correct.** The
  descriptor is the fact; the bytes are a separate port. A 4 GB video mirrored from
  metadata costs ~50 bytes, and `file-stream` reads it 64 KiB at a time when you
  finally want it.
- **`:file/parents` as a `:db.type/ref` makes the folder tree a datom graph**, and
  "everything under /Projects" is a **recursive rule** — `datom.query.engine`
  materialises recursive rules into an ordinary relation read. And because it is
  T2, the *same traversal* answers for an S3 prefix and a local directory.
- **`sha256Checksum` is omitted for Docs/Sheets** — they are not files, they are
  export targets. That is why `:gdrive/export-links` exists rather than a nullable
  content, and why the code takes a real branch instead of a fallback.
- **`:gdrive/md5` is T3, not T2, and that is the placement test working**: only
  Google populates it, so it cannot be promoted until a second provider does. If you
  wanted it in T2 today you would be *guessing*, and §1 R1 exists to make that
  guess visible.

---

## 2 · Three cursor algebras, one fold

Google ships three different incremental-sync contracts, and they are the part of
the API that actually breaks in production:

| service | start | page within a run | commit at the end | stale signal |
|---|---|---|---|---|
| **Drive** `changes.list` | `changes.getStartPageToken` | `pageToken` ← `nextPageToken` | **`newStartPageToken`** (present only when the end is reached) | *none* — documented non-expiring |
| **Gmail** `users.history.list` | a `historyId` from `getProfile` or a prior run | `pageToken` ← `nextPageToken` | the response's **`historyId`**, stored only when there is **no `nextPageToken`** | **404** → full sync |
| **Calendar** `events.list` | an initial full listing | `pageToken` ← `nextPageToken` | **`nextSyncToken`** (omitted while more pages remain) | **410** `fullSyncRequired` → clear and full-sync |

Three services, one shape. The spec names it:

```clojure
:page {:kind :sync-token :token … :next … :commit … :start … :stale …}
```

and the connector owes exactly three **laws**, checked by `veritas.property`:

1. **the cursor advances** — a run's committed cursor is never the one it started
   from, or the run was empty;
2. **resume is idempotent** — applying the same chunk twice against the same basis
   is a no-op (this is what makes an at-least-once queue safe downstream);
3. **stale implies full resync** — on the declared stale signal the connector
   discards the cursor and starts from `:start`, never from the stale token.
4. **a backfill starts *from* the cursor, never beside it.** This one is a trap,
   and it is why the backfill is a follow-up rather than a footnote. A cursor is
   minted at the instant you call `:start`; a window backfill ("last 90 days")
   runs *before* that instant, so anything that changed during the backfill falls
   between the two windows and is lost — silently and permanently. The order is
   therefore fixed: **take the cursor first, commit it, then page backwards.**
   The two never share a parameter set, which is also what keeps Calendar's
   stability rule satisfied by construction. A backfill page never writes a
   cursor. (FUP-119.)

Calendar adds a constraint the spec must carry as a *law*, not a comment:
`syncToken` **cannot be combined** with `timeMin`, `timeMax`, `q`, `orderBy`,
`updatedMin`, `iCalUID`, or the extended-property filters. A resumed run must send
the same parameters as the initial one, or the semantics are undefined. That is a
checkable property over a call and its parameters — `veritas` territory.

A page stream is a `proc.flow` **producer** whose state is the cursor. Downstream
demands N rows and gets N rows; the producer is structurally incapable of
outrunning its consumer. No buffer to size, and a slow indexer cannot make you
hammer a 429-prone API.

---

## 3 · Three layers of an answer, and the provenance that names which

A query against a provider is answered by the strongest layer that can answer it:

```
q: [?f :~file/files ?name ?mime]
   │
   ├─ 1  MIRROR    stored datoms — temporal, offline, O(1), joins with your data
   ├─ 2  CACHE     data.cache vault — ETag-validated responses, hot + durable tiers
   └─ 3  NETWORK   a proc.queue job → proc.flow pages → the socket      ← the only egress
```

**A store is a value.** `data.cache/open` gives a `vault`: content-addressed keys,
a hot in-VM tier, an optional durable tier on disk, and — the part that matters
here — **a datalog index of what is cached**, so *what is in my cache, how often
did it earn its slot* is a `q`. `proc.table` owns that index so it survives the
worker that first created it.

**Caching is derived, not asked for.** The spec says it per method:

- `:cache :none` — `files.list`, `changes.list`. A list is a cursor walk; caching
  it is caching the wrong thing.
- `:cache :validated` — `files.get`. Store the response with its `etag`; on the
  next read send `If-None-Match`; a 304 costs **5 units, not 100**, and zero
  bytes. The 304 path is a *first-class success*, which is why
  `googleapis-common` teaches its validator to accept it.
- `:cache :coalesced` — N concurrent identical requests become **one** network
  call. This is not a lock; it is `proc.queue`'s **`:unique`** on the request key.
  The Idempotency Key *is* the single-flight.

**Nothing above the network knows which layer answered — except on purpose.**
datom's relation spec already carries a `:provenance` axis ("why each tuple
exists"). Turn it on and each row carries `:from :mirror | :cache | :net`, with
`:at`. So "why did this page render the old title?" is a query, not an
investigation.

### What the mirror stores: the blob, and its projections

The mirror is **lossless**. A row is two things at once:

```clojure
{:conn/remote-id  "18c…"          ; T1 — a real, indexed datom
 :conn/title      "Q3 planning"    ; T1 — the shared display projection
 :conn/when       #time{…}         ; T1 — the temporal extent, AVET-orderable
 :msg/thread      "18c…"           ; T2 — the domain's own shape
 :msg/sent-at     #inst "…"
 :conn/raw        <<the response bytes>>}   ; T1 — :db.type/term, the WHOLE object
```

The declared fields are projections. `:…/raw` is the response itself. datom's
`codec.bl` gives a **total order to every BEAM term** — *"a tuple, a nested map, a
set or a pid can be indexed and range-scanned exactly like a string"* — so the
blob is not a dead column: it is a legal, orderable datom value. It has to be
*declared* as `:db.type/term`, which is deliberate ("an untyped attribute is an
attribute nobody has thought about yet, and those should not silently become
indexable").

Three things follow, and they are why this is the right default:

1. **The spec controls what is INDEXED, not what is KEPT.** A field nobody
   declared is not gone; it is one projection query away. Discovering you need
   `:labelIds` on month three costs a projection, not a re-fetch — and a re-fetch
   is not free: a `files.list` is **100 units**.
2. **The blob is the ETag keeper and the audit trail.** `:cache :validated` needs
   the prior response to send `If-None-Match`; the mirror already has it. And
   `as-of` makes "what did Google say last Tuesday" a query.
3. **It keeps the declared-field contract honest.** §5 derives a mock contract
   over *declared* fields only (z3 has no records or maps). That is a real limit
   on the mock — and it is not a limit on the mirror, which loses nothing.

The honest cost: a term column is heavier per value and datom retains history. A
100 000-file Drive at ~2 KB each is ~200 MB of blobs plus history, which needs a
measured decision, not a vibe. ∴ the retention is a **stance**, not a fork:
`:keep :all` (default) keeps the blob forever; `:keep :declared` drops it and
marks the projection lossy; `:keep :windowed N` keeps a rolling window. One
field on `conn/keep`, one code path.

### How a query becomes a request — the fill

This is the mechanism the whole design rests on, so here it is concretely.

**A remote relation is a *stored* relation plus a *fetcher*.** The query engine
sees only the stored one. `:~msg/messages` is real datoms with real indexes;
`datom/q` answers it with zero network. What makes it *complete* is the fetcher —
and the fetcher is governed by a declaration, not by a heuristic buried in a
provider.

```clojure
;; the spec, per relation — what the mirror IS, and how it may be filled
:relations
;; ── T2 (msg.bl): the relation, and the SHAPE of its fill. NO METHOD IS NAMED. ──
{:~msg/messages
 {:mirror {:entity :conn/key                              ; T1's composite identity
           :cols   [:conn/title :msg/from :conn/when]}   ; T1 and T2 columns together
  :fill   {:on-miss :key                                 ; ← implicit fill is KEY-ONLY
           :key     :conn/key                            ; the key NAMES the service,
           :fresh   "PT5M"                               ; so the provider is unambiguous
           :max     1}                                   ; never fan out inside a query
  :scan   {:page :page}}}                                ; explicit only — see `have!`

;; ── T3 (connector/google/gmail.bl): the SPEC binds a method onto that relation. ──
:gmail.messages.get  {:as {:relation :~msg/messages :mode :bb}}
:gmail.messages.list {:as {:relation :~msg/messages :mode :bf}}
```

The provider the engine calls is then almost trivial:

```clojure
(defn provider
  "A datom relation provider over this connection's mirror, filling on a miss.
   Called BY THE ENGINE, inside whatever process runs the query."
  [aspect]
  (fn [db mode bound _args]
    (let [local (mirror-rows db aspect bound)]      ; an indexed read. no network.
          {:keys [on-miss by key fresh max]} (:fill (relation-spec aspect))]
      (cond
        ;; the mirror answers, and the answer is younger than :fresh → no call.
        (and (seq local) (younger-than? db aspect bound fresh)) local

        ;; EVERYTHING BOUND — a key lookup — and the mirror missed.
        ;; This is the whole of "the query becomes a request": one bounded call,
        ;; then answer from what it wrote.
        (and (= :bb mode) (= on-miss :key) (fillable? by bound) (<= max 1))
        (do (have! (conn-of db) aspect {(key-of aspect) (first bound)})
            (mirror-rows (live-db (conn-of db)) aspect bound))

        ;; a SCAN never fills implicitly — see below.
        :else local))))
```

Two subtleties in there are load-bearing, so they get said out loud:

- **`conn-of db` — the connection is derived from the database.** One registration
  per ident serves every connection, because a connection IS a database plus a
  credential: `{:db conn :credential cred :spec spec}`. N tenants are N dbs, not N
  registered relations. (§6.)
- **`live-db` — the fill is read against the NEW basis.** A query's `db` value is
  a fixed basis, and a fill writes *above* it, so the filled rows are invisible to
  the running query everywhere **except through the clause that caused the fill**.
  The doorway is the only place the new rows appear. No phantom rows, no basis
  drift.

**A filter is not an action — which is why the fill is a function clause.**

The obvious spelling of "fetch on a key miss" is

```clojure
;; ✗ WRONG — the provider is never called
:where [?m :conn/key [:gmail "18c…"]]
       [?m :~msg/messages ?subject ?from ?when]
```

and it is wrong for a reason worth stating plainly: **a clause that matches nothing
produces no rows, so the join never reaches the `:~` clause and the provider never
runs.** A fill cannot be a *filter over the mirror*; it has to be something the
engine **calls**.

`datom` already has the right clause kind, and it is not a new one: *"A predicate
`[(> ?age 40)]` filters. A function `[(* ?age 2) ?double]` **binds**."* So the fill
is a **function clause**:

```clojure
;; ✓ a function clause: it FILLS, and it binds the entity
:where [(conn/ensure :~msg/messages ?key) ?m]
       [?m :~msg/messages ?subject ?from ?when]
```

```clojure
(defn ensure
  "Make the mirror able to answer for `key`, then hand back the entity.
   Self-contained (input from :in only), so clause order cannot change the answer;
   idempotent under the queue's :unique window, because the engine may call it once
   per binding row."
  [aspect key]
  (let [c (conn/of-key key)]                     ; the key NAMES the service AND the
    (auth/require! c :read (env/principal))      ; account — so this is unambiguous,
    (have! c aspect key)                         ; and this is the AUTHORIZATION
    (datom/entity-id (datom/db (:db c)) [:conn/key key])))
    ;; ↑ nil when the fill failed or was refused — and a nil binds nothing, so the
    ;;   query returns no rows. Absent, never an error (rls.bl's own rule).
```

Three properties are requirements, not style:

- **self-contained.** `ensure` takes its input from `:in` and a literal, never from a
  sibling clause's binding — because **the engine may evaluate clauses in any
  order**, and a clause that read its key from another clause would give a
  different answer depending on the plan. It is a *source* clause, never a join.
- **idempotent.** The engine may call it once per binding row; the `:unique` window
  (§3's `have!`) makes the second call cost nothing.
- **authorized here, not in the query.** `auth.rls` injects `:where` clauses, and
  injected clauses narrow *rows* — they cannot stop an *action*. So the check lives
  in `ensure`, against the **env's principal** (`auth/sandbox-fork`'s doctrine:
  *"one token narrows both the env's calls and the query's rows"*).
  **∴ RLS gates what you READ; an authorization check gates what you DO.**
  (`accounts-and-credentials.md` §2 has the full treatment.)

**Why the fill is KEY-ONLY — correctness, then cost.**

- *Correctness.* The engine is walking an index. A fill writes datoms into the
  **same store**, and an ordered-set cursor can walk *into* keys that arrived
  after the scan began — so a scan-fill could return rows the query's own basis
  did not contain, **and the function clause makes that worse rather than better**:
  a `[(conn/ensure …) ?m]` that filled with `:bf` would run inside the very scan it
  was feeding. A key lookup is a point probe against an index, so it cannot.
- *Cost.* A `:bf` fill is an unbounded enumeration of a remote corpus **from inside
  what the author wrote as a read** — a Drive `files.list` is 100 quota units, a
  corpus is thousands of them, at unbounded latency. Explicit means explicit:
  `have!` and `keep`, in the caller's own hands.

`have!` and `keep` are then the two names for the same enqueue — **now**, and
**from now on**:

```clojure
(defn have!
  "Make sure the mirror can answer for these params. Enqueues the fill,
   idempotent under the queue's :unique window — calling it twice while a job is
   in flight costs nothing and creates no second job. Blocks until the mirror can
   answer, or the fence expires."
  [c aspect params]
  (proc.queue/enqueue! (queue c) {:aspect aspect :params params
                                  :idem (idem-key aspect params)})
  (proc.fence/fence-fn (* 60 1000)
    (fn [] (datom/watch-until (:db c) (mirror-predicate aspect params)))))
```

Two properties worth noticing, because they are why this needs no protocol:

- **the mirror is the channel.** The winner and the loser of the `:unique` window
  exchange nothing — both wait on a *fact*. There is no reply to address, no
  client-side promise to leak, and a process that dies mid-wait resumes by
  re-running the same enqueue.
- **`have!`, `keep` and the backfill are ONE mechanism.** `keep` is a standing
  enqueue that re-arms on a cursor; `have!` is a one-shot enqueue; the backfill is
  the same enqueue with many ids. Which is why the backfill is a follow-up
  (FUP-119) and not a foundation: nothing new is needed, only more of what is
  already there. **For now, the mirror is fed by incremental sync plus lazy fills —
  which is a working index on day one, just a thin one.**

`conn/query-of` is the last piece: it turns a *method* into the query that reaches
it, as a **value**.

```clojure
(conn/query-of c :gmail.messages.get {:id "18c…"})
;; → '[:find ?m ?subject ?from ?when
;;     :in $ ?key
;;     :where [(conn/ensure :~msg/messages ?key) ?m]     ; ← the FILL, a function clause
;;            [?m :~msg/messages ?subject ?from ?when]]   ; ← reads the mirror it filled
```

Which is the whole of `conn/one`:

```clojure
(defn one [c method params]
  (let [q (query-of c method params)]
    (first (datom/q (:query q) (datom/db (:db c)) (bindings-for q params)))))
```

And dropping `conn/q` buys the thing that matters: **a call is a value you can
splice.**

```clojure
(datom/q '[:find ?subject ?title
           :in $ ?key
           :where [(conn/ensure :~msg/messages ?key) ?m]      ; ← fills if unmirrored
                  [?m :~msg/messages ?subject ?_ ?when]       ; ← same basis, same query
                  [?e :~sched/events ?title ?when]
                  [?f :~file/files ?name ?when]
                  [(str-contains? ?name "Q3")]]
         (datom/db (:db c)) [:gmail "18c…"])
```

No Google client can express that, because in every one of them the network is a
side effect and the join is a separate loop in the author's code.

### Writes are facts too

A relation is read-only, and a provider has mutations. Do **not** add a second
mechanism. `proc.queue` already decided this for the whole tree: *a job is a
fact*. So a connector operation is a fact.

```clojure
;; assert an intent; it settles.
(tx [{:conn/intent  :files.create        ; the domain's verb, not the provider's
     :conn/title   "Q3 planning"
     :file/parent  "1AbC…"
     :intent/idem  "app-42/q3-planning"}])  ; the whole of idempotency
```

Three properties come free and are the reason to do it this way:

- **`:unique [:intent/idem]`** — the retry that follows a crash cannot double-apply
  a create, because the job is the same job.
- **it is durable when you want and invisible when you don't** — the queue runs
  over `datom/store-ets` by default and over a durable store when the server has
  one. *Durable vs fast is a stance, not a fork.*
- **it is inspectable** — `vm.inspect` already renders queue rows; "what is in
  flight, what is rate-limited, what failed and why" becomes a page nobody wrote.

For the app author who wants the imperative spelling, `(conn/put! conn
:files.create {:name "…"})` asserts the intent and awaits settlement — **one
implementation, two spellings**, by the table in §0.

---

## 4 · The transport is a `proc` subsystem, not a function call

This is the part where the tree is far ahead of the ecosystem, and the research
says so plainly. Measured against the six BEAM HTTP stacks:

| stack | per-host pooling | what a caller gets when saturated | weighted meter |
|---|---|---|---|
| `:httpc` (inets) | `max_sessions` **2**, `max_connections_open` **infinity** | opens a *non-persistent* connection with `Connection: close` — unbounded growth, no queue | ✗ |
| **Finch** | NimblePool; `size` 50/shard, lazily opened | **blocks** in the checkout queue, then **raises** after `pool_timeout` (5 s). HTTP/2 streaming has **no backpressure** (documented) | ✗ |
| **Mint** | none, by design — "that is the job of a connection pool built on top of Mint" | n/a | ✗ |
| **gun** | `gun_pool` tracks `max_concurrent_streams` | the only stack with a first-class **"no capacity"** value (`undefined` / `no_connection_available`), plus per-request `flow` | ✗ |
| **hackney** | ETS counting semaphore per `{host,port}`, 10 ms poll loop | blocks until deadline, then `checkout_timeout` | ✗ |
| rate limiters (`ExRated`, `Hammer`, `rate_limiter`, Broadway) | — | reject-only or block; **unweighted**; single-node | ✗ |

Two gaps show up, and both are the reason to build rather than adopt:

**Gap 1 — backpressure as an exception is the wrong shape.** When Google tells you
to slow down, the correct behaviour is *hold this request until the window
opens* — which is what `proc.queue`'s `:at` and `:retry` already do, durably, with
the wait as `data` rather than as a blocked caller. Finch's answer is a five-second
queue and then an exception naming your pool size.

**Gap 2 — quota is weighted and Google's is per-minute sliding.** A `files.list`
costs **100** units and a `files.get` costs **5**. Every limiter in the BEAM
ecosystem counts *requests*. A limiter that counts requests is off by twenty times
on the calls that matter.

Where the tree is already ahead:

```
proc.queue   {:concurrency 4 :retry {:max 5 :backoff :exponential
                                     :base 1000 :max-delay 60000 :jitter 0.2}
              :unique [:req/key] :lease 60 :partition [:quota/key]}
```

Google's own documented guidance is *truncated exponential backoff with jitter*,
`min(2ⁿ + rand(0..1000), maximum_backoff)` with `maximum_backoff` typically 32–64 s.
The default above is closer to that guidance than `gaxios` is — gaxios has **no
jitter**, delays of 100/500/1500 ms, and excludes POST from its retryable methods.

### The design: Mint inside `proc`

**Mint is the socket layer** — deliberately a *process-less connection data
structure*, "no pooling; that is the job of a connection pool built on top of
Mint." That sentence is the invitation. So:

```
proc.super  pool of N connection workers, one Mint conn each, healed by OTP
proc.table  the pool's real state, surviving a worker restart
proc.reg    a roll-call of live connections keyed (host, credential)
proc.queue  admission · metering · retry · backoff · jitter · idempotency · durability
proc.flow   pages, demanded — the producer cannot outrun the indexer
proc.fence  every call bounded; {:ok v} | {:crash r} | {:timeout}
vm.inspect  the whole subsystem, as rows
```

`gun` is the alternative and the honest tradeoff is stated: it is the only stack
with a non-blocking *no capacity* result and it does HTTP/2 with per-request flow
control — but it brings its own process and pool model, which is the thing `proc`
already is. Start on Mint/HTTP-1 with keep-alive; reach for `gun` only if
multiplexing becomes a measured need.

### What must be built (and nothing else)

1. **A weighted budget.** One `proc.table` row per quota key — `{:tokens :refill-at}`
   — charged by the method's declared `:cost`, refilled on the sliding window.
   When short, the job's `:at` is set to the refill instant and the queue's own
   scheduler does the waiting. **This is the single genuinely new piece of
   machinery in the transport**, and it is small.
2. **`quotaUser` by construction.** For domain-wide delegation Google charges the
   **service account** unless you set `quotaUser` / `x-goog-quota-user`. The
   budget layer sets it from the credential's subject always, so the charging
   identity cannot be forgotten into a wrong quota bucket.
3. **Resumable upload.** No BEAM client ships it. Drive and Gmail media need it.
4. **A cookie jar and an SSE reader** — no stack ships a jar; only `gun` ships SSE.
   Both are small and both are only needed on specific paths.

Everything else on the transport is a **declaration**, not code.

---

## 5 · The sandbox is a registration

```clojure
;; live
(defrel :~file/files {:arity 4 :modes #{:bf :bb}
                      :provider (connector/provider conn :files)})

;; offline, same ident, same queries, deterministic
(defrel :~file/files {:arity 4 :modes #{:bf :bb}
                      :provider (connector/mock-provider spec :files)})
```

`connector/mock-provider` derives its contract from the **same spec** the live
provider is checked against — `veritas.mock/contract-from` over the method's
`:result` fields and its declared `:page`/`:errors` laws, then
`make-mock`/`answer` for determinism and `synth-boundary` for the edges a
hand-written mock always forgets. Two honest limits, stated now:

- **The contract is over the *declared* field subset**, not the API's full schema.
  z3 has no records or maps; nesting is modelled only as far as the theories
  reach (`coll-of` gives length laws, an `enum-of` payload arm gives one tagged
  union, `tuple-of` gives products) and everything past that falls to
  `:witnessed`. The modality says which. This is why `:fields` in a spec is the
  fields the app *depends on* — a design decision, not a limitation.
- **The error taxonomy is the fault space.** `veritas.fault/isolate` gives a
  per-law isolated mutant and `serve` injects it by name, so a negative test can
  say `{:inject :usageLimits/rateLimitExceeded}` and get a response wrong for
  exactly that reason — never accidentally a valid one.

---

## 6 · Credentials: proof of authority over a remote

> **Multi-account, the client/grant split, the store port, and what `auth` owns are
> in `accounts-and-credentials.md`.** This section is the credential *value* and its
> laws; that document is where it comes from and who holds it.

`auth` draws its own boundary (`strategy.bl`): *"A strategy turns verified
credentials into facts. It does NOT run the OAuth provider dance — that transport
belongs elsewhere."* `connector` must not absorb it either. It gets its own
package, and the three levels are clean:

```
credential :  proof of authority over a REMOTE — obtain, keep valid, revoke
auth       :  proof  ⇒  a capability         — who may do what to MY app
connector  :  capability + spec  ⇒  calls, pages, a mirror
```

A credential is a value; the flow is how you obtain it:

```clojure
{:scheme   :oauth2 | :sigv4 | :api-key | :jwt-bearer
 :material {…}                        ; tokens or keys — a :sensitive field, always
 :scopes   #{…}
 :subject  "user@example.com"         ; DWD impersonation target
 :expires-at <instant>
 :charset  :host}
```

and its laws are checkable:

- **refresh with skew.** Five minutes before expiry, not at expiry — the number
  `google-auth-library` settled on (`DEFAULT_EAGER_REFRESH_THRESHOLD_MILLIS`).
- **one refresh per credential.** Concurrent refreshes for the same refresh token
  must share one in-flight result, or N workers mint N tokens and invalidate each
  other.
- **the token cache is keyed.** `google-auth-library` caches one token per client
  instance and hands you `createScoped` to clone it — *per-(scope, subject)
  caching is the caller's job.* Here it is `proc.reg` (a roll-call keyed by what
  the connection is) plus `proc.table` (state that outlives a worker) — the exact
  thing the library leaves to you, and the exact thing the tree already has.
- **revocation is a stance.** `nil` oracle = offline + short TTL; provided =
  online. Same authorizer, same token; the deployment picks.

And because `:store` can be `:datom`, **the credential's whole life is a temporal
fact**: which credential was live when this sync ran; what did we hold at T; revoke
as-of T. RLS then governs *who may read the credential*, because it is an ordinary
resource.

### Personal and industrial are stances

```clojure
;; personal — one user, one machine, no public endpoint
(conn/open g/drive {:auth :oauth2-user :scopes [:drive.readonly]
                    :store (cred/store-file "~/.config/app")})

;; industrial — per-tenant, delegated, pushed, revocable
(conn/open g/drive {:auth :service-account :subject (:email tenant)
                    :store (cred/store-datom conn)
                    :revocation (auth/datom-oracle conn)
                    :watch {:kind :pubsub :topic (:topic tenant)}})
```

Same `open`, same provider, same queries. The stance chooses the grant, the store,
whether push exists, and whether an oracle is consulted. All values — the pattern
`auth` set with `:revocation`, applied one level out.

### The connection config — datom's config plus three things, never four

A connection **is** a database plus a credential, so `conn/open` must not invent a
config of its own. Two rules, both checkable:

1. **Anything `datom/connect` accepts, `conn/open` accepts verbatim.** If a
   connector option duplicates a datom option, the connector option is the bug.
2. **The blob tier is not a connector option at all.** `datom.blob/default-for`
   asks the *store* which blobs it declares (`DefaultBlobs`), and a store for which
   local bytes would be wrong *"extends `DefaultBlobs` and throws from it, naming
   the tier it needs. The refusal belongs to the store that knows; this function
   does not guess."* A connector offering `:blob` would be a second opinion about a
   decision already made correctly one layer down.

So the connector adds exactly three things:

```clojure
(def index
  (conn/open {:gmail gmail/spec :calendar calendar/spec :drive drive/spec}

    ;; ── the datom connection, verbatim. Not a connector config. ──────────
    {:store  (store-fjall/open {:path "~/.local/share/index"})
     :schema (schema/install-all (schema/empty-schema)
               (concat connector/schema
                       gmail/schema calendar/schema drive/schema))}

    ;; ── (1) the credential ───────────────────────────────────────────────
    :auth {:scheme :oauth2-user
           :scopes [:gmail.readonly :calendar.readonly :drive.readonly]
           :store  (cred/store-file "~/.config/index")}

    ;; ── (2) the retention stance (§3) ────────────────────────────────────
    :keep {:raw :all}                  ; :all | :declared | {:windowed "P90D"}

    ;; ── (3) the policies — DEFAULTS the spec narrows per method ──────────
    :policies
    {:fill   {:on-miss :key :fresh "PT5M" :max 1}
     :budget {:per-project 1000000 :per-user 325000 :charge-by :quotaUser}
     :retry  {:max 5 :backoff :exponential :base 1000 :max-delay 60000 :jitter 0.2}}}))
```

The industrial stance differs in **one field**, which is the whole argument for the
stance pattern:

```clojure
    :auth  {:scheme :service-account :subject (:email tenant)
            :store (cred/store-datom conn)
            :revocation (auth/datom-oracle conn)}
    :watch {:kind :pubsub :topic (:topic tenant)}
```

Every other line is identical. `:policies` are *defaults* — the spec narrows them
per method (`files.list` is `:cache :none`, `files.get` is `:cache :validated`),
and an app narrows them again per `keep`. Three layers, each able to make the
answer **narrower**, none able to make it **wider** — so a policy cannot be
silently escalated by a callee.

**Push is an industrial luxury; polling is the default.** A channel needs a public
endpoint and renews on a timer (Drive/Gmail/Calendar channels expire in hours).
`proc.sched` already owns timers and `proc.queue` already owns durability, so
`:watch` is a declaration that reuses both — and a personal install simply never
makes it.

---

## 7 · The module map

```
priv/lib/connector.bl                  ; facade — one require
priv/lib/connector/
  schema.bl      ; T1 — the UNIVERSAL pack (§1)
  spec.bl        ; the spec vocabulary: service · resources · methods · page · errors · quota · relations
  call.bl        ; a call as a value; the disposition classifier (retry/hold/resync/fail)
  page.bl        ; the cursor FOLD — three algebras, one shape (§2)
  budget.bl      ; the weighted sliding-window budget (§4)  ← the one new mechanism
  transport.bl   ; Mint-in-proc: pool · fence · keep-alive · the queue declaration
  relation.bl    ; spec + credential → a datom relation provider  ← the seam
  mock.bl         ; spec → veritas contract; register the SAME ident, offline
  law.bl         ; the three cursor laws + the parameter-stability law, as veritas contracts
  projection.bl  ; spec :fields + the raw blob → datom schema and projected datoms (§3)
  mirror.bl      ; the reconciler: cursor store, resumable chunks, idempotent apply
  watch.bl       ; channels + renewal (industrial stance)
  connect.bl     ; (open spec cfg) → a connection record + its supervision tree
  discovery.bl   ; Discovery doc → spec (fills four-fifths; never the hard fifth)

;; ── T2 · the DOMAINS. NOT under connector: a locally-imported message and a
;;        Gmail-synced message must be THE SAME ENTITIES (§1). ────────────────
priv/lib/msg.bl                   ; :msg/*, the :~msg/* relations, threads
priv/lib/sched.bl                 ; :sched/*; interval algebra, free/busy, RRULE glue
priv/lib/person.bl                ; :person/*; identities shared by every domain
priv/lib/datom/file.bl            ; :file/* — the module already owns the DFile half

;; ── T3 · the SERVICES. Specs and a few quirks. ─────────────────────────────
priv/lib/connector/google/
  discovery.bl   ; Google quirks: the three cursor algebras, the error envelope, quota tables
  gmail.bl ; gcalendar.bl ; gdrive.bl ; people.bl   ; thin: a spec VALUE + a T3 pack
priv/lib/credential.bl                 ; scheme-agnostic credential value + lifecycle
priv/lib/credential/
  oauth2.bl      ; code+PKCE · device · jwt-bearer · client-credentials · DWD
  sigv4.bl       ; aws_signature as a scheme — the second FAANG family, nearly free
  apikey.bl
  store.bl       ; :file | :datom | :keyring | :env
```

The core's verbs are the five in §0 and nothing else. Every provider namespace
below adds **specs**, never a verb — so a second provider (Graph, IMAP, S3, Stripe)
writes **no core code and no relations**, only a spec whose `:as` maps its methods
onto relations that already exist.

Layering — each level depends only on those below it, and the three tiers cut
ACROSS it rather than sitting inside it:

```
z3 · system.smt · datom · veritas · data.cache
        │
   credential ────────────► auth            (a credential mints a capability)
        │
      spec ──► budget · page · call · transport        (T3 · the services)
        │
     relation ──► mirror ──► watch                     (T2 · the domains)
        │
   connector.bl (facade) · schema.bl                   (T1 · the universal)

   msg.bl · sched.bl · person.bl · datom.file          (T2, beside connector —
                                                        NOT under it; §1)
```

The tiers are a *layering of meaning*, not of modules: `msg.bl` and
`connector/relation.bl` are peers, because a message is a message whether it
arrived over HTTP or out of an mbox.

`datom/blob-s3.bl` is the in-tree precedent for "speak a FAANG API" —
`(open cfg)` → a record implementing a capability protocol, SigV4 over
`aws_signature`, transport over `Req`. It should be **cut over** to this
transport: today it throws on a non-2xx instead of returning an error value, and
it has no retry ladder.

---

## 8 · The first use case: one index over three services

**A personal "everything index": Gmail + Calendar + Drive into one datom mirror,
queryable and offline, developed entirely against the derived mock.**

This is the case no Google client can do, which is why it is first. The
deliverable is not three integrations — it is **one query**:

```clojure
;; everything about "Q3 planning", across three services, offline — and the
;; relations are DOMAIN relations, so this query does not name a provider.
(datom/q '[:find ?kind ?what ?when
           :where [?m :~msg/messages ?subject ?_ ?when]
                  [(str-contains? ?subject "Q3 planning")]
                  [?e :~sched/events ?what ?when]
                  [?f :~file/files ?what ?when]
                  [(str-starts-with? ?what "Q3")]])
```

Three services, one `:where`, no fetch-then-join boundary, no network — because
each `:~` ident is a relation over the same basis. **And not one of them names a
provider:** point the same query at a Gmail + Calendar + Drive index or at a
Graph + CalDAV + S3 one, and the `:where` clause is unchanged. That is §1's middle
tier paying for itself, and it is the acceptance test for §0 — if the join needs a
line of glue *or a provider name*, the interface is wrong.

It is also the case that stresses the most:

| seam | what it forces |
|---|---|
| spec | three services, ~15 methods, **all three cursor algebras**, two stale signals (Gmail 404 · Calendar 410 · Drive none) |
| credential | user consent (loopback + PKCE) across three scopes, then refresh *mid-run* through a long backfill |
| transport | `403 usageLimits/rateLimitExceeded` — the commonest real failure — plus `429`, `401 invalid_grant`, `404`, `410`, and the 5xx ladder |
| budget | Gmail `history.list` = **2** units against 6 000/min/user; Drive `files.list` = **100** against 325 000; Calendar is a per-minute **sliding** window. A request-counting limiter is provably wrong |
| page | three algebras, one fold; commit-at-end-of-run, where a wrong commit silently and permanently skips mail |
| cache | `messages.get` / `files.get` are `:validated` (a 304 costs 5 units, not 100); `history.list` / `files.list` are `:none` |
| mirror | blob + projections — a three-service backfill is where `:keep` retention is actually measured instead of guessed |
| mock | the whole three-service index builds with **no credentials**, deterministically, faults injected by name |
| law | cursor advances · resume idempotent · stale ⇒ full resync · Calendar's parameter stability |
| landing | three specs → one datom schema, reusing the shape vocabulary |

**Order within the case: Gmail → Calendar → Drive.** All three are in this wave.
Drive is last not because it is optional but because `changes.list`'s token is
documented non-expiring and its `:stale` is `nil` — it is the *easiest* of the
three, and a broken cursor fold would pass on it. Build the hard two, then add
Drive as the third instance: **if adding Drive touches `page.bl`, the fold was not
a fold**, and that is the finding.

### The prototype: the dossier, reconstructible at any instant

The case above proves the spine. The prototype is the thing that shows what the
spine is *for* — and it has to show the connector, datom and beam-lisp at once, or
it is a demo rather than a prototype.

**One expression. No loops. No glue.**

```clojure
(defn dossier
  "Everything about a meeting — the mail around it, the doc it produced, and the
   doc's BYTES — as they stood at `tx`."
  [db event-id tx]
  (let [db     (time/as-of db tx)
        ev     (d/pull db '[* {:sched/attendees [*]}] [:conn/remote-id event-id])
        window (:conn/when ev)
        busy   (time/set-union
                 (d/q '[:find ?when
                        :where [?e :conn/kind :event] [?e :conn/when ?when]] db))
        doc    (first (d/q '[:find ?f ?title
                             :in $ ?w
                             :where [?f :conn/content ?c] [?f :conn/when ?t]
                                    [(time/overlaps? ?t ?w)]]
                          db window))]
    {:when  window
     :event ev
     :free  (time/set-complement busy window)          ; when else were we free
     :mail  (d/q '[:find ?subject ?from
                    :in $ ?w
                    :where [?m :~msg/messages ?subject ?from ?when]   ; ← FILLS if unmirrored
                           [(time/overlaps? ?when ?w)]]
                db window)
     :doc   doc
     :bytes (d/file-bytes db (:conn/content doc))}))
```

Now the beat that lands it: `(dossier db id meeting-start)` and
`(dossier db id (now))` are **the same query**, and they differ in `:bytes` and
`:mail`. *"What did the doc say when we agreed the numbers"* is a **result**, not
an archaeology exercise. No Google client can express it, a place-oriented database
cannot store it, and no SaaS will sell it to you.

Three smaller beats, each from the same db, each proving a different layer:

| beat | what it proves |
|---|---|
| the SAME query against the mock — offline, deterministic, with `{:inject :usageLimits/rateLimitExceeded}` | the sandbox is a registration, and the fault space is the spec's own taxonomy |
| a query about a 2027 date that was never synced, answered from `:sched/recurrence` | a recurrence is a *value*; the mirror is descriptive, not merely recorded |
| `[?x :file/sha ?sha]` matching a mail attachment and a Drive file on the same sha | content addressing dedups **across services**, for free |

And one beat worth the extra plumbing: the live version — a `datom/watch` over
`:conn/kind :message` re-rendering the dossier as mail arrives — because it shows
the whole thing is a *running system* (proc, budget, cursors, fills) and not a
batch job.

**Why this and not a CRUD demo.** A CRUD demo shows the connector. This shows the
connector, datom's two time axes, its content-addressed files, its interval
algebra, and beam-lisp's "a query is data" — in one function that a person would
actually want to call. It is also exactly wave 1: three `keep`s and a query, so
**the prototype IS the acceptance test**.

**A research spike for the industrial stance** (FUP-117): domain-wide delegation
with per-tenant `quotaUser`, Pub/Sub push channels, People ↔ CRM conflict. It
stresses tenancy and push — not the spine — so it must not gate the spine.

---

## 9 · Non-goals and risks, stated plainly

**Non-goals.**

- No universal OpenAPI importer. One target — the spec value — with Discovery as
  one importer. OpenAPI can become a second importer later; it must not shape the
  vocabulary now.
- No general RPC framework. The relation + the intent fact are the whole surface.
- No new shape language. `auth-downstream-a-breeze.md §0` still holds.
- No hand-written mock, ever. A mock is derived from the spec or it does not exist.

**Risks.**

1. **The contract cannot model the full schema.** Mitigated by scoping contracts to
   the declared field subset and letting the modality carry the honesty. If a
   design ever needs "the mock is faithful across all 54 Drive schemas", the design
   is wrong, not the engine.
2. **Weighted budgets are estimated, not known.** Google publishes per-method unit
   costs but they change. A wrong `:cost` is a wrong budget. Mitigation: the budget
   is an *advisory meter*, and the authoritative signal is still the `403` — which
   sets a **hold** on the quota key regardless. The meter reduces how often you
   learn the hard way; it never replaces learning.
3. **A queue round trip per call.** Small — `proc.queue` runs over
   `datom/store-ets` by default, so it is an ETS transaction, not a disk write —
   but real, and it must be measured before it is defended.
4. **Push needs a public endpoint.** Personal installs have none. Polling with a
   backoff ladder is the default stance; push is the industrial add-on. Stated as a
   stance, so nobody designs a feature that only works behind a load balancer.
5. **Discovery is machine-generated input.** Bounded interning, tagged binaries, a
   size guard before parse — `trust-boundary.md`, applied to a 269 KB JSON.
6. **`Retry-After` is not a documented Workspace contract.** Parse it defensively
   (seconds *or* HTTP-date) and never depend on it; the jittered ladder is the
   real mechanism.
7. **A tier is a *judgement*, and judgements rot.** Putting an attribute in T2
   that only one provider fills buys portability you do not have; putting a shared
   attribute in T3 buys a provider coupling you will pay for at the second
   provider. The mitigation is not discipline: it is §1's two invariants — a
   `:conn/kind`/domain agreement check, and `migrate/plan` as the gate on every
   promotion. **If a promotion has no migration, the tier was never earned.**
8. **A lossless mirror is heavier than a projected one.** The blob column (§3) is
   what makes a forgotten field cost a projection instead of a refetch, and it is
   also what makes a 100 000-file Drive ~200 MB plus history. `:keep` is the
   stance that trades them; measure before choosing, and never remove a field
   because the estimate was uncomfortable.

---

## 10 · The through-line

`veritas` says a contract run backwards is a server. `datom` says a computed
relation is a full citizen. `proc` says a job is a fact and backpressure is a
protocol. `auth` says a capability is a value and the stance is a parameter.

Point all four at a remote API and there is exactly one thing to write: **a spec**.

```
spec ├─ provider   a datom relation, so queries and joins come free
     ├─ mock       the same ident, offline, deterministic, faults by name
     ├─ gens       schema → generators → the property domains
     ├─ laws       cursor · idempotence · resync · parameter stability
     ├─ budget     weighted, per quota key, held by the queue's own scheduler
     └─ schema     resources → datoms, reusing the shape vocabulary
```

The API spec exists once. Everything else is a projection of it. That is the
whole design, and it is the reason the mock, the mirror, the meter and the tests
cannot disagree with each other: they all answer to the same value.
