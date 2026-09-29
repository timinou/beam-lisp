# The reconcile clause — `proc.reconcile`

Status: **implemented** 2026-09-29. Contract of record for the deferred clause
named in `mirror-and-reconcile.md` §4 and in
`docs/research/veritas-sync-investigation.md` §7 P1 (knowledger PLAN-041).

Read first: `entities-and-projections.md` (§3 the projection and its generated
owed/stale queries, laws L1–L7) and `mirror-and-reconcile.md` (§4 the loop).

`datom.reconcile/drain!` is the bulk EXECUTOR: one pass over a projection's owed
and stale rows, bounded concurrency, honest about what failed. It answers *what
to do with a row*. It does not answer *when*, *what happens when a row keeps
failing*, or *where the attempt is kept*. `proc.reconcile` answers those three
by wiring the projection's own generated queries to `proc.queue`, which already
owns retry, backoff, leases, uniqueness and partitioning.

**There is one implementation of publication.** A queued job performs a row
through the same primitives a drain uses (`owed-row`, `stale-row`, `apply-row!`,
`retire-row!` in `priv/lib/datom/reconcile.bl`). There is no second retry loop,
no second status discovery, and no second store.

## 1 · The clause

```clojure
(proc/defserver library-sync
  (reconcile
    {:projection lib-doc                        ; a pj/projection value
     :conn-fn    (fn [server] (sync-store/conn …))   ; → the datom conn to read
     :scope-fn   (fn [db conn] [[scope-eid :mount-key] …])
     :rules      under                          ; the % rules the queries need
     :apply      (fn [row prev] {:target t} | {:skip reason})   ; or THROW
     :retire     (fn [row target] …)             ; or THROW
     :paused-fn  (fn [db scope] …)               ; optional; default: never paused
     :limit      50                              ; optional; jobs per level pass
     :level      [10 :minutes]                   ; optional; default 10 minutes
     :jitter     0.05                            ; optional; ± on the level delay
     :watch?     true                            ; optional; default false
     :clock      proc.tick/wall-ms}))            ; optional
```

The clause EXPANDS to a `queue` clause over `:proj/job` jobs, the `perform`
registration, a level timer and four ops. Nothing new runs at runtime.

| option | required | meaning |
|---|---|---|
| `:projection` | ✔ | the `pj/projection` whose owed/stale queries define the work |
| `:conn-fn` | ✔ | `(fn [server-name] conn)` — the connection the queries read |
| `:scope-fn` | ✔ | `(fn [db conn] [[scope-eid scope-key] …])` — read from the CURRENT db, so a reopened store renumbers scope ids and the next pass uses the new ones |
| `:apply` | ✔ | the consumer's apply; `{:target t}` publishes, `{:skip r}` answers this revision with a reason, a THROW is transient |
| `:retire` | ✗ | the consumer's retire; default is a no-op |
| `:paused-fn` | ✗ | `(fn [db scope] bool)`. Gates STALE only — the projection's own `:active` clauses gate OWED |
| `:limit` | ✗ | bounds jobs per level pass (a first sync progresses in visible steps) |
| `:level` | ✗ | `[N UNIT]`; `nil` disables the timer (init pass only). Default `[10 :minutes]` |
| `:watch?` | ✗ | edge-trigger a `datom/watch` per scope. Latency only |
| `:queue` | ✗ | overrides merged into the queue declaration (literal data) |
| `:clock` | ✗ | the clock the level delay is measured on; also given to the queue |

The queue declaration it defaults to:

```clojure
{:of        :proj/job
 :unique    [:proj/key :proj/rev]      ; a revision is part of the identity
 :partition [:proj/scope]              ; one apply at a time per scope
 :retry     {:max 5 :backoff :exponential :base 2000 :max-delay 300000 :jitter 0.2}}
```

Job payload (carried as `:job/payload`, so it survives a restart):

```clojure
{:proj/kind :owed|:stale
 :proj/key  [projection-ident scope-key src-key]   ; the record key
 :proj/rev  <the revision this job answers>        ; part of :unique
 :proj/scope <scope eid>}                          ; the partition
```

## 2 · Laws

1. **A job re-judges before it acts.** Between enqueue and run the revision may
   move, the scope may pause, the row may be answered, the source may leave.
   `perform!` re-reads the projection's CURRENT answer and returns without
   acting when the row is no longer owed (or no longer stale). An
   **obsolete queued revision therefore cannot publish**, and **pause is
   honoured** for both owed and stale.
2. **Transient failure → the queue's retry, no answer.** `apply-row!` writes no
   answer on a throw, so the row stays owed; `perform!` re-throws, so
   `proc.queue` applies its backoff. An outage cannot suppress a revision.
3. **Exhausted retries park the row.** At the retry ceiling the queue settles
   the job `:failed` and KEEPS it. No projection answer is written — the row
   stays owed, which is the truth. It is then **parked**: the level pass does
   not re-enqueue a `(key, revision)` a failed job holds, so the level timer
   cannot re-mint a doomed job every period (no hot loop, no green `:skipped`).
   A **newer revision is not parked** (the revision is in the key) and becomes
   eligible immediately; `retry!` re-enqueues by hand.
4. **Level is recovery.** At init and every `:level` (and whenever a watch on
   reality is absent or was down), the pass re-derives its work from the
   projection's queries. Correctness never depends on a watch, a message or a
   previous process having lived.
5. **The failure is a fact.** `failures` and `status` read the queue's store, so
   a stopped server answers the same. `unsupported`, `temporarily failed` and
   `retries exhausted` are three different states.

## 3 · Public API

```clojure
(rec/pump!    :library-sync)   ; one LEVEL pass  → {:scopes :owed :stale :parked :enqueued :created :at}
(rec/enqueue! :library-sync p :owed row)  ; one row as a job (unique no-op if held)
(rec/status   :library-sync)   ; → {… :owed :stale :records :queued :running :done :failed
                               ;      :overdue :parked :last-level-at :last-error :by-scope}
(rec/failures :library-sync)   ; → [{:job/id :kind :key :rev :attempts :error} …]  (needs-attention)
(rec/retry!   :library-sync id); re-enqueue a settled job's payload → the new job
(rec/perform! :library-sync job)          ; the queue's body (registered by the clause)
(rec/unwatch-all! :library-sync)          ; stop this server's watches
```

The server also answers the queue's `[:enqueue job opts]` / `[:stats]` calls and
these: `[:reconcile-status]`, `[:reconcile-pump]`, `[:reconcile-retry id]`.

A clause cannot inject a `terminate` (the injected one would shadow the
server's own), so watches are stopped by `unwatch-all!` — or automatically when
a scope disappears from `:scope-fn`.

## 4 · What changed in `datom.reconcile`

The executor was refactored so the clause could reuse it instead of copying it:

| name | role |
|---|---|
| `source-key` | (was private `key-of`) the `:conn/key` a record is keyed by; public because a job re-reads its row by it |
| `owed-row` / `stale-row` | the row map for one owed triple / one stale pair (`:prev`, and `:rec` for stale) |
| `apply-row!` | INTENT (`:pending`) → apply → ANSWER (`:applied`/`:skipped`); `{:state :applied\|:skipped\|:error}` |
| `retire-row!` | retire → `retire-tx`; `:retired` or `{:error e}` |
| `drain!` | unchanged contract; now expresses itself through the four primitives |

`test/bl/datom/reconcile_test.bl` (25 assertions incl. the 120-history model)
passes unchanged over the refactor.

## 5 · Consumer cutover (knowledger `drive-sync`)

Today `drive-sync.bl` runs `console/timed-drain!` from a `spawn`+`sleep` loop
(`live.bl`). The cutover is: declare one `(reconcile …)` server per sync store
and delete the sleep loop; `pass!` keeps its keep-step, the clause owns the
drain and the failure history.

- `:conn-fn` → the store's connection (`sync-store/open!`).
- `:scope-fn` → the active/declared mount eids and their `:mount/id`.
- `:paused-fn` → `(fn [db scope] (not= :active (:mount/state (datom/entity db scope))))`
  — the same test the current `:paused?` uses.
- `:apply` / `:retire` → the existing `apply-file` / `retire-origin` fns; they
  are already idempotent on `(src, rev)` and already tolerate a target they
  never wrote (L4), which is exactly what a re-judged job requires.
- `:limit` → the existing `PASS-LIMIT` (50).
- Keep `drain!` for tests and for a one-shot bulk pass.

## 6 · Tests

```
bl -p priv/std test --shared test/bl/proc/reconcile_test.bl     # 14 tests, 54 assertions
bl test test/bl/datom/reconcile_test.bl                          # 25 assertions (executor + model)
bl -p priv/std test --shared test/bl/queue_test.bl               # 17 tests (unchanged)
```

Observed green on 2026-09-29 in the isolated runner (`~/.cache/bl-plan036-head`,
`e420f8b1`) with the three owned sources copied in. Note the `--shared` and
`-p priv/std` requirement: a clause is resolved when a file's `defserver` forms
are EXPANDED, and the isolated runner expands before the file's `require`s run
(BUG-082) — the same requirement `queue_test` documents.

The clause suite covers: level convergence and restart recovery; an obsolete
queued revision not publishing; transient failure → queue backoff → publish;
exhausted retries parked with `failures` and no hot loop; a newer revision
eligible after an older one is parked; manual retry; move/retire; the L4 crash
window (a `:pending` intent retired when its source leaves); pause; the level
timer; and a watch-only server (`:level nil`) converging on an edge trigger.

## 7 · Known limitations

- `:parked` counts TERMINAL failures this queue holds; each blocks its own row
  from being re-enqueued. A pruned job releases the row (a deliberate operator
  reset).
- `:last-level-at` / `:last-error` are the process's own history, not durable
  facts. The durable record of the work is the queue's jobs and the projection's
  records.
- The watch is per scope and is refreshed by `pump!`; a watch process for a
  scope that disappears is stopped on the next pass (or by `unwatch-all!`).
- `datom.store-fjall` exclusive ownership (P4) is orthogonal and not required
  by this clause.
