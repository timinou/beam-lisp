# Mirror and reconcile — keeping a remote tree, and turning it into work

Status: design of record, 2026-09-22. Written for the first consumer — knowledger
libraries that auto-sync from a Google Drive folder — but everything here is
generic: nothing below names knowledger, and only §2 names Google.

Read first: `an-api-is-a-relation.md` (§2 cursor laws, §3 the mirror),
`accounts-and-credentials.md` (§1 account identity, §6 mortal credentials),
`edge-cases.md` (E8, E9). This document does not restate them; it builds the two
pieces they leave open and fixes one defect the design surfaced.

Zero-context summary. A *mirror* is a set of datoms that copies a remote tree's
metadata into a database you own. A *reconciler* is a standing datalog query
whose rows are work that is owed; a process keeps the answer empty by doing the
work. Put together: **sync is not a process with its own state. It is a query
whose answer should be empty, and a server that empties it.**

```
remote ──cursor walk──► MIRROR (datoms, in YOUR db)
                           │
     your facts ──────────►│  owed  = a datalog query over mirror + your facts
                           ▼
            reconcile clause ──(level: full query · edge: datom/watch diff)──► proc.queue ──► perform
```

---

## 0 · Decisions this document rests on (settled 2026-09-22)

| # | decision | consequence here |
|---|---|---|
| 1 | Drive access is `drive.readonly` | recursive folder sync is possible (the non-sensitive `drive.file` scope does not grant a picked folder's children). It is a RESTRICTED scope: a public SaaS needs Google's security assessment. |
| 2 | one person's grant for now; firm-level must stack ON TOP | the mirror and everything downstream key on the **account**, never on the credential. A service-account credential (FUP-117) later yields the same grant shape for the same account key — nothing above `credential` changes. |
| 3 | one direction: remote → local | no write-back, no conflict model. FUP-117 Q4 stays open and does not block this. |
| 4 | removal at the provider is a FACT (tombstone), never an excision | E9 holds: a sync can never destroy history. Excision stays an explicit, audited act. |
| 5 | generic work first | this document, and PLAN-142, before any consumer code. |

---

## 1 · The mirror is scoped to roots

`an-api-is-a-relation.md` §3 describes a mirror of a *service*. A drive change
feed (`changes.list`) is per ACCOUNT: it reports every file the account can see.
Persisting all of it would copy a person's whole Drive — every filename — into a
database whose owner asked for one folder. That is a privacy defect, not a
storage cost.

**Law M1 — the mirror holds only what some root can see.** A keep is declared
with roots, and the mirror is the closure of those roots under `:file/parents`:

```clojure
(conn/keep c :~file/files {:db ctrl :roots #{[:google "1123…" "1AbCfolder"]}})
```

- a change whose file is (or becomes) a descendant of a root → asserted;
- a change for a file outside every root → **dropped before it is written**;
- a folder that MOVES INTO a root arrives as one change for the folder only —
  its descendants were never mirrored. The keep therefore **seeds the subtree**
  (a `files.list q="'<id>' in parents"` walk, breadth-first) whenever a folder
  newly satisfies `under`. This is the same code path as the initial backfill.
- a file that leaves every root keeps its datoms (it is history) but no longer
  satisfies `under`, which is how downstream sees the move (§4).

Adding a root is a backfill of that root. Removing the last root that covers a
subtree is an explicit **`conn/forget-root!`**, which excises the mirror
metadata only it covered — an audited act the caller performs, never a side
effect of sync (decision 4 governs *provider* removals; forgetting a root is a
local choice about what we hold).

### 1.1 · The initial sync takes the cursor FIRST (FUP-119 law, restated for roots)

1. `changes.getStartPageToken` → commit it as the keep's cursor.
2. Seed each root breadth-first with `files.list` — these pages write mirror
   rows and **never** the cursor.
3. From then on, `changes.list` from the committed cursor owns everything.

A change that lands during step 2 is seen by step 3, because the cursor predates
it. Applying it twice (once from the seed, once from the change feed) is safe
because mirror writes are idempotent (§2 law 2 of the relation doc).

### 1.2 · What a mirrored file IS (T1/T2/T3, per `three-tiers.md`)

```clojure
;; T1 — every remote resource
:conn/key        [:google account-id file-id]   ; :db.unique/identity — the composite
:conn/account    [:google account-id]           ; the account KEY (a value, not a ref)
:conn/raw        <term>                          ; the whole response object (:keep :all)

;; T2 — the file domain (files.bl), shared with local / S3 providers
:file/name       string
:file/mime       string
:file/parents    ref, cardinality many           ; the folder tree IS a datom graph
:file/folder?    boolean
:file/trashed    boolean                          ; a fact; removal is never excision
:file/gone       boolean                          ; the provider says it no longer exists / we lost access
:file/rev        string :db/index true            ; the CONTENT revision (below)
:file/size       long
:file/modified   long (epoch ms)
:file/sha        string :db/index true            ; when the provider supplies one

;; T3 — only Google's
:gdrive/version  string                           ; monotonic per-file change counter
:gdrive/export-links term                         ; Docs Editors files have no bytes
```

**`:file/rev` is the cheapest honest content signal, and a hint, not an identity.**
For a binary file it is `sha256Checksum` (Drive computes it; datom's content
address is also sha256, so a descriptor needs no download). For a Docs Editors
file there is no checksum — the Files resource says sha256 is "not populated for
Docs Editors or shortcut files" — so `rev` falls back to `version`, which Drive
documents as "a monotonically increasing version number … reflects every change
made to the file on the server, even those not visible to the user." That is a
superset of content changes: a false positive costs one export, and the consumer's
own content hash decides whether anything changed. A false NEGATIVE is impossible,
which is the direction that matters.

---

## 2 · The Drive cursor, concretely

| step | request | commit rule |
|---|---|---|
| start | `GET /drive/v3/changes/startPageToken` | commit before any seed page (§1.1) |
| walk | `GET /drive/v3/changes?pageToken=…&pageSize=1000&includeRemoved=true&fields=nextPageToken,newStartPageToken,changes(fileId,removed,time,file(id,name,mimeType,parents,trashed,version,sha256Checksum,size,modifiedTime,driveId))` | `newStartPageToken` appears only on the LAST page — commit then, and only then |
| stale | none documented (token "doesn't expire") | the `:stale` branch is coded anyway: a 4xx on a committed token discards it and re-runs §1.1 |

`removed: true` means the file left this account's view (permanently deleted, or
access revoked). It becomes `:file/gone true` — a fact. `trashed: true` becomes
`:file/trashed true`. Neither retracts anything.

Shared drives (`driveId`) need `supportsAllDrives=true&includeItemsFromAllDrives=true`
and are **out of scope for wave 1**: a root inside a shared drive is refused by
name at `keep` time rather than half-synced. (Open: one cursor per shared drive vs
one per account — measure when a consumer asks.)

The walk is one `proc.queue` job per account (`:unique [:conn/account]`), so a
scheduled poll, a "sync now" click and (later) a push notification coalesce into
one run. Push is a trigger, never a payload: a notification means "there may be
changes", and it enqueues the same poll.

---

## 3 · A relation declares what it READS — and `datom/watch` is wrong without it

### 3.1 · The defect (BUG-100, reproduced 2026-09-22)

`datom/watch` T2a decides whether to re-run a query with a prefilter:
`query-attrs` collects the attributes of the TOP-LEVEL pattern clauses only
(`pattern-clauses` → `parse/pattern-clause?`). Attributes read inside a rule
invocation `(under ?f ?r)`, a `[:not-join …]`, an `[:or …]` or a computed relation
are invisible to it. A commit that touches only those attributes is discarded
without running the query — **the watch stays silent while the answer changes.**

Measured with the owed-set query of §4 (probe kept in BUG-100):

```
file added under a subfolder        → {:added #{[10 "r1"]}}   ✓ (touches :f/rev, a top-level attr)
job recorded (the not-join)          → silent                  ✗  answer moved: {[10 "r1"]} → {}
rev bumped                           → {:added … :removed …}   ✓
file MOVED into the root (parent only) → silent                ✗  truth after: [[10 "r2"] [12 "x"]]
```

The move changed only `:f/parent`, which is read solely inside the recursive rule.
For sync this is the exact event that matters, and it is lost silently. The
`not-join` row was first annotated `✓ (the answer did not change)` — it is in fact
the same defect: recording the job stops the file being owed, so the answer DOES
move, and the old watch missed that too.

### 3.2 · The fix, and the axis it adds — LANDED 2026-09-22 (BUG-100, W0)

Two parts, the second being the reusable one. Both are in the tree
(`priv/lib/datom/watch.bl`, `priv/lib/datom/query/relation.bl`); the tests that
pin them are `datom.watch.test/a-watch-over-a-rule-and-a-not-join-reads-the-whole-query`
(the §3.1 probe, now firing `{:added #{["…" "x"]}}`), `…-inside-not-fires`,
`…-inside-or-fires`, `…-inside-a-rule-body-fires`,
`a-computed-relations-declared-reads-reach-the-prefilter`,
`a-computed-relation-without-reads-is-always-relevant`, and
`the-prefilter-still-prefilters`.

1. **`query-attrs` walks the whole query.** Recurse into `:not`/`:not-join`/`:or`/
   `:or-join`/`:and` sub-clauses, and into the bodies of every rule the `%` input
   defines (the rules are an `inputs` argument; the watch already holds them).
   Anything it cannot see through — a computed relation with no declaration, a
   variable attribute — makes the prefilter answer "always relevant". Correctness
   over the optimisation, which `touches?`'s own docstring already promises for
   variable attributes.

2. **Relation axis 8: `:reads`.** `register-relation!` gains an optional
   `:reads #{:file/parents}` — the attributes a provider's answer depends on. The
   watch prefilter uses it; so can `datom.attr-basis` (a derived column is
   invalidated by ITS attributes — W4a already argues this per attribute) and
   `datom.derived` validity. A relation without `:reads` is conservatively
   "reads everything", and an empty or malformed `:reads` is a registration
   error rather than a silent "never relevant". It is the eighth axis in
   `datom/query/relation.bl` (and is emitted by `catalog-datoms`), the one the
   seven-axis header was missing: `maintenance` says *how* to update under a
   delta but nothing said *which* deltas are relevant.

### 3.3 · `:~file/under` — the folder closure as a derived relation, not a rule argument

The recursive rule works (probed), but threading `%` through every consumer query
is the "second spelling" smell BUG-099 removed for computed relations. The tree
already has the shape: `codebase/register-reaches!` exposes a transitive closure
as `:~reaches` with `:extension :derived` and `:bf/:fb/:bb` modes over a rules
fixpoint. `files.bl` gets the same:

```clojure
(defn register-under! []
  (datom.query.relation/register-relation! :~file/under
    {:arity 2 :modes #{:bf :fb :bb} :extension :derived
     :maintenance :recompute
     :reads #{:file/parents}                       ; §3.2 axis 8 — the watch can see it
     :doc "?f is a (transitive) descendant of folder ?r"
     :provider under-provider}))                   ; seeds the fixpoint from the bound side

;; then, in any consumer:
[?f :~file/under ?root]
```

T2, so the same clause answers for a local directory tree or an S3 prefix
mirrored with `:file/parents`. `:fb` (root bound → its cone) is the mode sync uses.

---

## 4 · The reconcile clause — a standing query whose rows are owed work

### 4.1 · Why a clause, not a function

Every consumer of a mirror writes the same loop: compute what is owed, enqueue it
idempotently, re-check on change, re-check on boot because a watch only sees
deltas. knowledger already has two hand-rolled instances (semantic work
submission, ingest jobs), and a sync would be the third. `proc.queue` settled the
hard half — a job is a fact, `:unique` is the idempotency key, the claim is one
CAS. What is missing is the producer: **the query IS the producer.**

```clojure
(proc/defserver library-sync
  (queue {:of :sync/item
          :unique [:sync/key :sync/rev]            ; the same row owed twice is one job
          :partition [:sync/mount]                 ; one apply at a time per mount (§4.3)
          :concurrency 4
          :retry {:max 5 :backoff :exponential :base 2000 :max-delay 300000 :jitter 0.2}})
  (reconcile {:query  knowledger.sync/OWED         ; a literal datalog value
              :inputs knowledger.sync/owed-inputs  ; fn [] → the :in args (conn is resolved at init)
              :conn   knowledger.sync/ctrl         ; fn [] → the connection the query reads
              :job    knowledger.sync/row->job     ; fn [row] → the job payload
              :level  [10 :minutes]})              ; full re-run cadence; edges come from the watch
  (perform [job] (knowledger.sync/apply! job)))
```

Semantics, each one a sentence a test pins:

- **level-triggered.** At init and every `:level`, run the query and `enqueue!`
  every row. `:unique` makes a row already queued or running a no-op. This is what
  recovers from a crash, a missed notification, or a watch that was down.
- **edge-triggered.** A `datom/watch` on the same query (with §3's fix) enqueues
  every `:added` row as it appears. `:removed` rows need nothing: a row leaves the
  owed set because its work was recorded, or because it stopped being owed — in
  the second case a queued job for it is `cancel!`led if still `:queued`, and a
  running one finishes and is re-judged by `perform` (at-least-once, so `perform`
  re-checks the row against the current db before acting).
- **the answer should converge to empty.** `stats` gains `:owed` (the query's
  current count) beside `:queued`/`:running`/`:failed`, so "is sync caught up?" is
  one read with no process asked.
- **`:job` and `:inputs` are functions, the query is data** — for the same reason
  `(queue {…})` takes a literal map: the declaration stays inspectable, the runtime
  values are resolved where they exist.

Placement: `priv/std/proc/reconcile.bl`, registered with `extend-clause!` next to
`queue`, and required by the one door `priv/std/proc.bl` exactly as FUP-107 did
for `proc.queue` (BUG-082's rule: a clause no image has loaded is an "unknown
clause").

### 4.2 · What it replaces

`foundry.reconcile` compares desired datoms against observed state and REPORTS
drift. The reconcile clause is its active form — it reports AND acts — and the
foundry module can keep reporting through the same `:owed` count. No second
mechanism: a report is the query without the `perform`.

### 4.3 · Cross-database effects are ordered, not atomic

A consumer's `perform` usually writes two databases (the mirror's db, where the
owed query lives, and a target db). datom has one writer per connection and no
two-phase commit, so the rule is an ORDER plus IDEMPOTENCE:

1. do the effect in the target (idempotent: re-running it is a no-op);
2. then record it in the owed db (the row leaves the owed set).

A crash between 1 and 2 re-runs 1 (no-op) then does 2. A crash before 1 re-runs
everything. `:partition` serialises the jobs whose effects could interleave.

---

## 5 · Bytes: download and export (FUP-116 item 1, narrowed)

Sync needs bytes, which the relation surface deliberately does not carry. Two
transport verbs in `connector.http`, both returning values, both fenced:

| verb | request | cap |
|---|---|---|
| `get-bytes` | `GET /drive/v3/files/{id}?alt=media` | caller-supplied `:max-bytes`; a body larger than the cap is `{:error :too-large}` read from `Content-Length` BEFORE the body, never after |
| `export-bytes` | `GET /drive/v3/files/{id}/export?mimeType=…` | Google limits exported content to **10 MB** (files.export reference, verified 2026-09-22) — surfaced as `{:error :export-too-large}` by name |

Docs → `text/markdown` is a published export target (Export MIME types table,
verified 2026-09-22), which means a Google Doc arrives as markdown that a native
reader ingests with no optional reader at all. Sheets and Slides have no text
export worth indexing in wave 1; they are skipped **by name**, never silently.

Resumable upload (the other half of FUP-116 item 1) is out of scope: decision 3.

---

## 6 · Where grants live on a server (FUP-120, the parts sync needs)

The file store (0600) is right for a laptop and wrong for a multi-user server.
Sync needs two things from FUP-120, no more:

1. **`store-datom` — a grant as a datom, sealed.** Extends `credential.store/Store`
   over a connection. The grant is sealed with AES-256-GCM under a key the CALLER
   supplies (`{:seal-key <32 bytes>}`); given no key, construction **refuses by
   name** — the protocol's own doctrine ("a store for which plaintext would be
   wrong must REFUSE BY NAME"). The key never enters the database. The row is
   keyed `(service, account-id)` like every other tier, so `-list` still answers
   "which accounts are connected".
2. **The web redirect flow.** `credential.flow` splits at the click already
   (`begin!` / `finish!`), but `begin!` binds a loopback socket and `finish!`
   accepts on it. The web stance is the same two halves without the socket:
   `begin-web` → `{:url :state :verifier}` (the caller persists state+verifier
   against the user's session, one-time), and `finish-web!` takes the callback's
   query params, CHECKS `state`, and exchanges. Everything after the exchange
   (`decode-token`, `id-claims`, `classify`) is shared, not copied.

Law (unchanged, `accounts-and-credentials.md` §6): `invalid_grant` → `:reauth`,
never `:retry`. For a keep, `:reauth` **pauses** the keep and surfaces it; it does
not fail the cursor, and it does not delete anything.

---

## 7 · What is built, in order (PLAN-142)

| wave | module | acceptance (observable) |
|---|---|---|
| W0 | `datom/watch.bl` (BUG-100) + relation `:reads` | the BUG-100 probe becomes a test: a parent-only move fires the owed watch |
| W1 | `files.bl` schema + `:~file/under` | `[?f :~file/under ?r]` answers the probe tree in `:fb` and `:bb`; `:reads` is in `catalog-datoms` |
| W2 | `connector/keep.bl` + Drive `changes.list` spec | against a fake `get!`: cursor first; commit only on `newStartPageToken`; M1 drops out-of-root changes; a folder moved in is seeded; kill mid-walk → resume, no gap, no duplicate |
| W3 | `connector.http` `get-bytes` / `export-bytes` | caps enforced from headers; 10 MB export error by name |
| W4 | `proc/reconcile.bl` clause | level + edge enqueue; `:owed` in `stats`; a crashed perform is re-run and converges |
| W5 | `credential.store` `store-datom` (sealed) + `flow` `begin-web`/`finish-web!` | no key → refusal by name; a stored grant is not readable as plaintext from the db; state mismatch → a value, not a raise |
| W6 | `examples/connectors/03-keep-folder.bl` | one live run against a real account: pick a folder id, keep it, add/rename/move/trash a file in Drive, watch the mirror follow |

W0 and W1 need no network. W2–W5 are tested with injected transports. W6 is the
only step that needs a human click.

---

## 8 · Non-goals

- write-back, conflict resolution (decision 3; FUP-117 Q4)
- shared drives (wave 1 refuses them by name)
- push channels (a trigger for later; the poll is the mechanism)
- the lazy key-fill of `an-api-is-a-relation.md` §3 — sync is an explicit keep,
  never a fill from inside a read
- domain-wide delegation (FUP-117) — decision 2 says it must stack on top, and §0
  shows why it can: nothing here keys on the credential
