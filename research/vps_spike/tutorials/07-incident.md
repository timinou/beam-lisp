# 07 — The incident ritual: page → postmortem in one store

An incident's page, its evidence, the fix, the audit trail, and the
postmortem are all datoms in one database — so the whole ritual is one
prompt against one connection, and the past is a query away.

## The claim

This spike proves the claim in `docs/design/vps/incident-ritual.md`: an
alert arrives as a *value that carries its own re-runnable query*; the
incident window is queried bitemporally (`datom/as-of` answering "what did
the system believe at the moment it broke"); the automation's actions and
the operator's commands land in the **same** audit log, because they are the
same kind of fact; and the postmortem's action item is itself a datom — an
incident that *produces its own prevention* in the same store that paged you.
The spike names itself "page to postmortem, one store, one prompt" and then
walks the design doc's five-step ritual against a single in-memory datom
connection.

## The idea

At 03:00 an on-call engineer pays a tax that has nothing to do with
diagnosis: context switching. The metrics vendor saw the symptom, the deploy
tool saw the change, the shell history saw the hand-commands, and the wiki
will hold the postmortem nobody queries. Each tool stores one *shadow* of an
event, and the human is the join.

beam-lisp's answer is that the truth was never split, so the tool shouldn't
be either. If desired state, observed state, the transaction log, the audit
trail, and the fix are all **datoms**, then every incident question is a
query against one database:

| incident question | the datom answer |
|---|---|
| what changed? | the append-only tx log — nothing is overwritten, so the change is still *there* |
| what did the system believe when it broke? | `(datom/as-of db t)` — the db value as of an instant |
| who touched it? | the audit datoms — automation and humans share one shape |
| is it still happening? | re-run the alert's own query against *now* |
| what should we do about it? | a postmortem whose action item is a datom a reconciler can pick up |

The centrepiece mechanic: **a fact is never updated, only superseded.** A
deploy doesn't overwrite `:svc/src` — it asserts a new value while the old
one stays in the log. Therefore "what changed?" and "what did we believe?"
are not features bolted on beside the database; they are *filters over data
that never went anywhere*. `datom/as-of` costs O(1) and copies nothing —
it hands back the same store with a different basis. The query does not even
know it is looking at the past.

That is why "the incident has one tool": diagnosis (query), remediation
(write), audit (query again), and record (write again) are the same address
space, so the postmortem's timeline is reconstructed from facts rather than
from a tired human's memory.

## Walkthrough

Everything runs against one connection, opened with a small schema.

```clojure
(def conn
  (datom/connect
    [{:db/ident :svc/id :db/valueType :db.type/string :db/unique :db.unique/identity}
     {:db/ident :svc/src :db/valueType :db.type/string}
     {:db/ident :act/who :db/valueType :db.type/keyword}   ; :reconciler | :operator
     {:db/ident :act/what :db/valueType :db.type/string}
     {:db/ident :act/at :db/valueType :db.type/long}
     {:db/ident :pm/svc :db/valueType :db.type/string}
     {:db/ident :pm/cause :db/valueType :db.type/string}
     {:db/ident :pm/action :db/valueType :db.type/keyword}]))
```

Three namespaces of attribute, one store: `:svc/*` is the service's desired
state, `:act/*` is the audit log, `:pm/*` is the postmortem. The `:act/who`
comment — `:reconciler | :operator` — is the whole audit-log trick in one
line: automation and a human write the *same* attributes, distinguished only
by a keyword value. There is no separate "human actions" table to join
against.

### Stage 0 — the timeline: a healthy deploy, then a bad one

```clojure
(def r-good (datom/transact! conn [{:db/id -1 :svc/id "web" :svc/src "v2"}
                                   {:db/id -2 :act/who :reconciler :act/what "deploy web v2" :act/at 200}]))
(def t-good (:tx r-good))                                    ; the last-known-good basis
(datom/transact! conn [{:db/id -1 :svc/id "web" :svc/src "v3-bad"}
                       {:db/id -2 :act/who :reconciler :act/what "deploy web v3-bad" :act/at 300}])
```

Two transactions build the whole incident. The first sends `web` to `v2` and
logs a reconciler action at `@200`; `t-good` captures the **transaction id**
of that commit — this is the basis we will time-travel to later. Note `:db/id
-1` in both transactions is a *tempid*, and because `:svc/id` is
`:db.unique/identity`, the second transaction **upserts onto the same `web`
entity** rather than creating a second one. That means `:svc/src` is now
retract-old-plus-assert-new: `"v2"` is not edited away, it is still in the
log. The second transaction is the bad deploy, `v3-bad`, logged at `@300`,
with no `:tx` capture — its basis is the present.

### Stage 1 — the page carries its own query

```clojure
(def alert {:id :p95 :at 320
            :query '[:find ?src :where [?e :svc/id "web"][?e :svc/src ?src]]})
(println "── PAGE ── p95 breach @" (:at alert))
```

The page is a value whose `:query` is a **quoted datalog vector** — data, not
a string, not a dashboard URL. Anyone paged by it can re-run *exactly* the
query that fired, and the spike prints the breach at `@320`: after the bad
deploy (`@300`), inside the incident window. This is the design doc's "An
alert is a datom. It arrives with its own evidence attached." We do not have
to guess what "p95 breach on web" meant; the query *is* the meaning.

### Stage 2 — query the window: now vs. as-of

```clojure
(def now-src (first (first (datom/q (:query alert) (datom/db conn)))))
(def good-src (first (first (datom/q (:query alert) (datom/as-of (datom/db conn) t-good)))))
(println "── QUERY window ──")
(println "  running now:        " now-src)
(println "  last-known-good:    " good-src)
```

Both lines run **the page's own query** — nothing else — against two `db`
values: the present, and `(datom/as-of (datom/db conn) t-good)`. Output:

```
── QUERY window ──
  running now:        v3-bad
  last-known-good:    v2
```

`(datom/db conn)` is the present database *value*; `t-good` is a transaction
id; so `running now` is `v3-bad` (the incident is real) and `last-known-good`
is `v2` (the past is queryable). The `first`/`first` is just unwrapping the
single row of a set-of-tuples; with one `web` entity there is exactly one
row. This pair of lines is the bitemporal heart of the spike: the same query,
two bases, two answers — no "audit table" to write or keep in sync.

### Stage 3 — one audit log for automation and operators

```clojure
(def actions (datom/q '[:find ?who ?what ?at :where [?a :act/who ?who][?a :act/what ?what][?a :act/at ?at]]
                      (datom/db conn)))
(println "── AUDIT (automation + operators, one log) ──")
(doseq [[who what at] (sort-by (fn [r] (nth r 2)) actions)]
  (println (str "  @" at "  " (name who) ": " what)))
```

One `:find` over `:act/*` returns every actor. The tuples are sorted by `at`
(3rd element of the row) so the log reads chronologically, and each is
printed with `(name who)` to strip the keyword colon. At this point in the
run the log holds the two reconciler deploys:

```
── AUDIT (automation + operators, one log) ──
  @200  reconciler: deploy web v2
  @300  reconciler: deploy web v3-bad
```

The shape would be identical for an operator line — that is the point. In
the real system a REPL session transacts its commands into this same log, so
"who touched it?" is answered by the same query that answers "what did the
automation do?".

### Stage 4 — the fix: revert to good, record the operator's own act

```clojure
(datom/transact! conn [{:db/id -1 :svc/id "web" :svc/src good-src}
                       {:db/id -2 :act/who :operator :act/what "rolled back to v2 (as-of t-good)" :act/at 340}])
(def fixed-src (first (first (datom/q (:query alert) (datom/db conn)))))
(println "── FIX ── web now:" fixed-src)
```

The remediation is a transaction: set `:svc/src` back to `good-src` (the
`v2` we read from `as-of`) *and* record an `:operator` act in the same commit.
So the audit log now contains a human action of exactly the same shape as the
reconciler's — automation and operator, one log. Then the page's query is
run a third time against the present:

```
── FIX ── web now: v2
```

The incident is over, and the fix is a fact. In the design doc this is step 4
("reach in … then hot-fix in place"); the note that steps 3 and 4 are *the
same prompt* is exactly what this shows — reading and writing go through the
same `conn`.

### Stage 5 — the postmortem closes the loop

```clojure
(datom/transact! conn [{:db/id -1 :pm/svc "web"
                        :pm/cause "v3-bad shipped; contract check absent"
                        :pm/action :add-contract-gate}])
(def pm (datom/q '[:find ?svc ?action :where [?p :pm/svc ?svc][?p :pm/action ?action]] (datom/db conn)))
(println "── POSTMORTEM (a fact the reconciler can act on) ──")
(doseq [[svc action] pm] (println (str "  " svc " → " (name action))))
```

The postmortem is transacted into the **same database that paged you**, and
its action item is a keyword value — `:add-contract-gate` — not prose. Output:

```
── POSTMORTEM (a fact the reconciler can act on) ──
  web → add-contract-gate
```

Because the action is a datom, a reconciler can query for it and turn it into
real prevention (a schedule, an alert, a gate). The postmortem does not decay
into a wiki page nobody reads; it is data with a consumer.

### The assertions

```clojure
(def ok (and (= "v3-bad" now-src)                 ; the incident was real
             (= "v2" good-src)                    ; the past is queryable
             (= "v2" fixed-src)                   ; rollback = value, applied
             (= 3 (count all-actions))            ; two reconciler + one operator act
             (= 1 (count pm))                     ; postmortem is data
             (= :add-contract-gate (second (first pm)))))
```

Six checks pin the whole story: the incident was real, the past is
queryable, the rollback took, the audit captured **three** facts (two
reconciler + one operator — the operator line added in stage 4 is counted
here even though the stage-3 *print* only showed the two deploys), the
postmortem exists exactly once, and its action is the expected datom. `ok`
drives the final line.

## What's real vs modelled

This section is the honest boundary. The organ exercised as-is is **`datom`
itself** (`priv/lib/datom.bl` et al.), and the parts of it used are real, not
stubs:

- **`datom/connect`** — a genuine in-memory datom store with the schema above
  installed before any data, exactly as `datom.conn/connect` does.
- **`datom/transact!`** — real commits returning a real transaction report;
  the tempid `:db/id -1` **upsert onto `:db.unique/identity`** is the real
  datom mechanic, which is what makes the second transaction *supersede* the
  first rather than duplicate `web`.
- **`datom/q`** — the real datalog engine (`datom.query.engine/q`), set
  semantics and all.
- **`datom/db`** → **`datom/as-of`** — this is the headline real organ. `db`
  is the real O(1) database *value* (`datom.conn/db`), and `as-of`
  (`datom.time/as-of`) is a genuine basis-filtered view over the immutable
  log: it copies nothing and shares the store. Running the *same* quoted
  query against the present and against `t-good` and getting two different
  answers is the real time-travel filter, not play-acting.

What is **modelled in miniature** or simplified for the probe:

- **The page is not itself transacted.** `alert` is a local `def` holding a
  map with an `:at` and a quoted `:query`. The design doc's `:alert/*`
  attributes are not in the schema and never enter the store, so "an alert is
  a datom" is demonstrated *by shape and by the re-runnable query*, not by an
  `:alert/id` entity you could query. A real page would be a datom in the
  same store (`observability.md`); this spike keeps it a value.
- **Step 2 of the ritual — "arrive" — is absent.** The design doc's five
  steps are page → *arrive (ssh → capped REPL)* → query → reach in → close.
  The spike's labels run `STEP 1, STEP 3, STEP 4, STEP 5`: there is no code
  for arriving over ssh into a capability-capped REPL. That organ is proven
  separately in `11_ssh_access.bl` (`executor.sandbox` + the token/auth
  stack), and the on-call guardrail it provides ("an exhausted operator still
  cannot `System/halt`") is not exercised here at all.
- **The operator's command is hand-transacted, not captured.** Stage 4 calls
  `datom/transact!` directly to write the `:operator` act. In the real system
  the operator's REPL commands transact *themselves* into the audit log; here
  the spike simply asserts the shape is the same as the reconciler's. So
  "operators and automation share one log" is shown as a *schema* fact, not
  as a live REPL-capture mechanism.
- **The postmortem is not consumed.** The action item `:add-contract-gate` is
  transacted and read back, but nothing turns it into a gate or a schedule.
  "The reconciler could pick it up" is a claim about the datom's *shape*
  (a queryable `:pm/action` keyword); the actual pickup is the reconciler
  spike's job (`01_reconciler.bl`), not this one.
- **Timestamps are hand-authored longs.** `:act/at` values (`200`, `300`,
  `320`, `340`) are arbitrary integers used for chronological ordering and
  display. The real ordering primitive is the **transaction id** — `t-good`
  from `(:tx r-good)` — and that is what `as-of` actually filters on. The
  `:act/at` longs stand in for wall-clock and are not synchronised with the
  tx basis.
- **One bitemporal axis, not two.** The spike uses `as-of`, which filters by
  *transaction time* (when a fact was recorded). True bitemporality has a
  second axis — *valid time*, when a fact is true in the world — and datom
  exposes it as `valid-at` / `valid-between`, but this spike never calls
  them. So "bitemporal window" here means the recording-time half; the
  valid-time half is available but unused.
- **The store is in-memory and volatile.** `datom/connect` opens a fresh ETS
  store in this process. Nothing survives the run; a real VPS keeps the same
  datoms on a durable backend (fjall). The spike also skips `release!`/
  `close!`, which a long-lived node would call.

In short: the *shape* of the incident ritual — re-runnable page query,
`as-of` window, one audit log, postmortem-as-data — is exercised end to end
against the real `datom`; the *surrounding organs* (ssh arrival, live REPL
capture, reconciler pickup, durable storage, valid-time) are named here and
proven elsewhere.

## Run it

```
./blx run research/vps_spike/07_incident.bl
```

Expect the section prints shown above and the final line:

```
PASS 07_incident  (one store, page to postmortem)
```

`blx` runs the checkout-matched `bl-v2026.4` drop; the first run pays
**~10-15s of cold-start** (JIT/boot), not work — the spike itself is
negligible. A `FAIL` line means one of the six assertions in `ok` came back
false; the printed stages above it tell you which.

## Exercises

1. **Aim the time machine at the bad deploy.** Change `(def t-good (:tx
   r-good))` to capture the *second* transaction's `:tx` instead (bind
   `r-bad` and use `(:tx r-bad)`). Predict: `good-src` becomes `"v3-bad"`, the
   "rollback" reverts to the bad source, and the assertion `(= "v2" good-src)`
   fails — so the run prints `FAIL`. This is the cost of a wrong basis, and it
   shows `as-of` reads *exactly* the transaction you name.

2. **Remove the operator's act.** Delete the `:act/who :operator` map from the
   stage-4 transaction so only the `:svc/src` update commits. Predict:
   `fixed-src` is still `"v2"` (the fix works), but `(count all-actions)`
   drops to **2**, so `(= 3 (count all-actions))` fails. The lesson: in this
   design the fix *and* its record are one commit, on purpose — a fix without
   an audit datom is an incomplete transaction.

3. **Query valid time, not transaction time.** Add a line that assigns a
   `:db.valid/from` to the bad-deploy transaction (or otherwise gives the two
   deploys valid intervals), then compare `(datom/valid-at (datom/db conn)
   t)` against `(datom/as-of (datom/db conn) t)`. Predict: the two views
   diverge — `as-of` asks "what had we recorded by `t`?", `valid-at` asks
   "what was true in the world at `t`?" — and you have added the second
   bitemporal axis the spike left on the table.

4. **Add a second service and watch set semantics bite.** Add a `blog`
   service with its own `:svc/src`, then point the alert's `:query` at both
   (or drop the `:svc/id "web"` clause). Predict: `(datom/q …)` returns two
   rows, and `(first (first …))` now picks an **arbitrary** one — datalog
   results are sets, so the "now-src" is whichever row happens to come first.
   Switch the assertion to `(count …)` or a sorted pick to make it
   deterministic; this is why the tutorial unwraps a single-entity query.
