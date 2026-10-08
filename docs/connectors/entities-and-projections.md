# Entities and projections — what a relation cannot say

Status: design, 2026-09-28. Nothing here is built. Supersedes the `:sync/*`
record shape of `mirror-and-reconcile.md` §4 (cutover, agreed 2026-09-28) and
amends `an-api-is-a-relation.md` / `accounts-and-credentials.md` on identity.
First consumer: knowledger `docs/21-org-integrations-and-rbac.md`. Executable
evidence: knowledger `apps/knowledger/test/sync-store-prototype.bl` (+ `-test`),
33 assertions, run with this checkout's `bin/bl run`.

Zero context. A connector turns a remote API into datalog. Today it does that
with **computed relations** — `[?f :~file/files ?name ?when]` — and the design
asks relations to carry everything. Three things a relation cannot carry kept
being hand-rolled in consumers: a remote object's **attributes** (a relation
returns positional tuples), its **identity** when several accounts see it, and
the **lifecycle** of what a consumer derives from it. This document names the
missing primitives and fixes the division of labour.

---

## 1 · The division of labour

| primitive | answers | stored? | example |
|---|---|---|---|
| **computed relation** | "which things are there / how are they connected, *right now*?" | no — asked of the provider | `:~file/children` for a folder browser |
| **mirror entity** | "what is this thing and what do we know about it?" | yes — datoms, by a keep | `[:m365 "t/drive-A" "item-7"]` with `:file/name`, `:file/rev` |
| **derived relation** | a closure over mirror datoms | no — computed from datoms | `:~file/under` |
| **projection** | "what have WE made from it, and is that still owed?" | yes — records with identity + lifecycle | the library source ingested from a file |

Rules that follow:

- **R1 · Relations carry identity and edges; attributes are datoms.** A relation's
  tuple is `[entity]` or `[entity entity]`. `name`, `when`, `size` are
  attributes read by ordinary clauses or `pull`. A new attribute never changes
  a relation's arity, so no query breaks when a provider learns a field
  (`three-tiers.md` R2 "absence is the null" finally holds for connectors).
- **R2 · Browsing is computed; keeping is mirrored.** Showing a folder picker is
  a computed relation (no datoms written — law M1 is about what we *keep*).
  Syncing is a keep. The same entity key names both, so a picked folder is
  already the root the keep needs.
- **R3 · Consumers never write lifecycle by hand.** Anything with "owed",
  "applied", "retired" is a projection.

## 2 · Identity is the provider's namespace, not the account

`accounts-and-credentials.md` §1 keyed a remote object as
`[service account-id remote-id]`. That is right only when the account IS the
namespace (a mailbox). For shared storage it duplicates: two people seeing the
same SharePoint library would mirror every file twice.

**Key = `[provider namespace remote-id]`**, where *namespace* is the scope the
provider guarantees uniqueness in:

| provider | namespace | why |
|---|---|---|
| Microsoft Graph files | `<drive-id>` — key `[:graph drive-id item-id]` | delta exists only per drive root, so one feed = one drive; drive ids are globally unique in Graph, so a tenant prefix adds length, not information (decided 2026-10-04, PLAN-051; replaces `<tenant-id>/<drive-id>`) |
| Google Drive | `<customer-or-account>/<drive-id or "my">` | file ids are global in practice; the prefix keeps shared drives distinct |
| Gmail | `<account-sub>` | the mailbox is the namespace — unchanged |

Access is an edge, not identity: `:conn/seen-via` (many) names the
integrations/actors that can reach an entity. Measured in the prototype: a
vector `:db.type/term` is a working `:db.unique/identity` and query input
(`[:m365 ns id]` upserts and looks up like a string).

The **cursor** is per *feed*, not per account: Graph's `delta` exists only from
a drive root, so one feed per drive; Google's `changes` is per account or per
shared drive.

## 3 · `defprojection`

### 3.1 · The declaration

```clojure
(defprojection :sync/doc
  "A file under a mount's root, ingested into the mount's library."
  {:scope    :mount                     ; the entity kind that owns the projection
   :active   [[?scope :mount/state :active]]
   :member   [[?scope :mount/root ?r] [?src :~file/under ?r]
              [:not [?src :file/folder? true]]
              [:not [?src :file/trashed true]]
              [:not [?src :file/gone true]]]
   :revision [[?src :file/rev ?rev]]
   :adopt    :auto                      ; :auto | :manual
   :vanish   :retire                    ; :retire | :orphan
   :apply    knowledger.sync/ingest!    ; (fn [ctx scope src rev prev-target]) → {:target t} | {:skip reason}
   :retire   knowledger.sync/drop-origin!}) ; (fn [ctx scope src target])
```

Three fixed variables — `?scope`, `?src`, `?rev` — are the whole interface
between the declaration and the generator. `defprojection` checks at expansion
time that `:member` binds `?src` from `?scope`, that `:revision` binds `?rev`,
and that neither mentions the other's locals.

### 3.2 · What it generates (proven by the prototype)

One record schema for every projection:

```clojure
:proj/key    term, unique identity   ; [projection scope-id source-key]
:proj/of     keyword, indexed
:proj/scope  ref                      ; e.g. the mount
:proj/source ref                      ; the mirror entity
:proj/rev    term                     ; the revision this record answers
:proj/state  keyword                  ; :proposed :applied :skipped :retired
:proj/target term                     ; a cross-database pointer VALUE, never a ref
:proj/reason string
```

And three queries, built by splicing, with `:in $ ?scope`:

| query | rows | definition |
|---|---|---|
| **owed** | `[scope src rev]` | active ∧ member ∧ revision ∧ ¬∃ record(scope, src) with `rev` = rev and state ≠ `:retired` |
| **stale** | `[record src]` | record(scope, src) holding a target, state ≠ `:retired`, ∧ ¬ member — **not** gated by active |
| **proposed** | `[scope src]` | member ∧ ¬∃ record(scope, src) |

The prototype prints the generated owed query; it is exactly doc 16's
hand-written OWED. The two bugs execution found in the hand-written pair
(knowledger docs/17) are now properties of the generator, not of each author:

1. *a skipped revision may still hold an older target* → stale selects on
   `:proj/target` present, never on state `:applied`;
2. *a retired record must not answer a returning source* → owed's anti-join
   excludes `:retired`.

A third rule the prototype made explicit: **stale ignores `:active`.** Pausing
a scope must never retire anything, so the query states the truth and the
executor decides (a paused scope's executor does not retire).

### 3.3 · Laws (each one a test in the prototype, or a gate below)

| # | law | evidence |
|---|---|---|
| L1 | identity = f(source key): a rename or move of the source updates, never duplicates | prototype 5, 8 |
| L2 | a projection writes only `:proj/*` in its store and only its target in the target store; human-owned attributes are never touched | by construction: `:apply` returns a target value |
| L3 | lifecycle `proposed → applied/skipped → retired → applied`; retire never deletes — it drops the target's claim | prototype 4, 5 |
| L4 | target first, record second; `:apply` is idempotent on (source, rev) | prototype order; crash test = gate G2 |
| L5 | owed converges to empty under the executor | prototype 2 |
| L6 | stale is independent of `:active` | prototype 7 |
| L7 | the watch prefilter is derived: `:reads` = attributes of `:member ∪ :revision ∪ :active` ∪ `:proj/*`, plus each relation's own `:reads` | gate G3 (BUG-100 machinery exists) |

### 3.4 · Adoption and vanishing

- `:adopt :auto` — the executor applies every owed row (a library source).
- `:adopt :manual` — owed is empty until a human writes a record with state
  `:proposed → :applied`; **proposed** is the list the UI shows. (Kept for
  consumers that want it; knowledger's library binding is an explicit act,
  see its doc 21, and does not use it.)
- `:vanish :retire` — stale rows are retired (tombstone downstream).
- `:vanish :orphan` — stale rows are marked, target untouched, a human decides
  (the right choice when the target is something people curate).

### 3.5 · Execution: the reconcile clause becomes the projection executor

`mirror-and-reconcile.md` §4's `(reconcile {:query … :job … })` is kept and
narrowed: it takes a projection instead of a hand-written query.

```clojure
(proc/defserver library-sync
  (queue {:of :proj/job :unique [:proj/key :proj/rev] :partition [:proj/scope]
          :retry {:max 5 :backoff :exponential :base 2000}})
  (reconcile {:projection :sync/doc :conn knowledger.sync/store-for :level [10 :minutes]}))
```

- level: run owed and stale at init and every `:level`; enqueue.
- edge: T2a watch on both queries (L7), `:added` enqueues.
- perform: re-judge the row against the current db (at-least-once), then
  `:apply` / `:retire`, then write the record.
- **transient vs terminal.** A transport error that may pass (network, 5xx,
  429, 401 before refresh) raises → the queue retries with backoff and **no
  record is written**, so an outage cannot suppress a revision. A terminal
  answer (`:skip reason` — unsupported type, too large, 403 on that item) is
  recorded and answers the revision until it changes.
- `stats` gains `:owed` and `:stale` counts: "is it caught up?" is one read.

### 3.6 · Where it lives

`priv/lib/datom/projection.bl` (declaration, schema, query generation — pure,
no processes) and `priv/std/proc/reconcile.bl` (the clause). The query
generator is data→data, so it is testable without a VM process, which is how
the prototype tests it.

### 3.7 · Is a projection a "computed entity"?

Yes, in the only sense that survives contact with time: an entity whose
identity is computed (L1), whose existence is derived (owed/stale), and whose
history is kept (L3). A computed entity that is NOT stored — "the file as the
provider sees it right now" — is just a computed relation plus a `pull` of an
empty mirror; it has no lifecycle to keep, so it needs no new primitive.

## 4 · Gates before this is built

- G1 · `test/bl/datom/projection_test.bl`: the prototype's scenarios over the
  generator, plus `:adopt :manual` and `:vanish :orphan`.
- G2 · kill the executor between `:apply` and the record write; rerun converges
  with no duplicate target and one record.
- G3 · a parent-only move fires the owed T2a watch through derived `:reads`.
- G4 · cost: owed + stale over a 50 000-item mirror with a 10-deep tree, rows
  scanned reported by `datom.explain`, `:fb` mode of `:~file/under`.

## 5 · Cutover (agreed 2026-09-28)

- `an-api-is-a-relation.md`: providers expose `[entity]` / `[entity entity]`
  relations; positional attribute columns are removed (`:~file/files`
  arity 3 → 1; `:~msg/messages` likewise) — callers move to attribute clauses.
- `accounts-and-credentials.md` §1: key = `[provider namespace remote-id]`;
  cursor per feed; the account becomes an access edge.
- `mirror-and-reconcile.md` §4: the reconcile clause takes a `:projection`;
  `:sync/*` is not a schema anyone writes.
- PLAN-142: W1 adds `:~file/children` (computed, browse) beside `:~file/under`;
  W4 becomes "projection + executor"; a Microsoft Graph spec + fake join W2.
