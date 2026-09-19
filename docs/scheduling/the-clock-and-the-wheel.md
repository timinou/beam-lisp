# The clock and the wheel — scheduling, recurrent work, and the pane that watches it

> **Broadway and Oban are two different things and only one of them is missing
> here.** Broadway is a *stream* processor (GenStage: demand + stages + batching)
> — beam-lisp already has that, it's `flow`. Oban is a *durable clock* (a table +
> a poller + retries + uniqueness) — that is genuinely absent, because `OTP`
> ships timers and nothing else. The scheduling primitive that exists is the
> **Timeout Edge** (`(after ms …)`), already named in
> [`the-process-pattern-language.md`](../the-process-pattern-language.md) §1.5;
> its periodic child **Heartbeat §4.1** is marked `◐ vitals; ○ stdlib fns` and is
> the unbuilt piece. So this isn't "add a scheduler subsystem" — it's **name the
> last patterns (Tick, Deadline Queue, Claim/Lease, Retry, Idempotency Key),
> bundle them into two `def*` forms, and let the store be the timer wheel.** The
> `bl ui` pane then falls out for free, because `vm.inspect` already is the one
> model with three faces.

This document is the design of record for the implementation. It is written so
the implementation can be tracked against it, item by item.

---

## 0. Verdict in one paragraph

**Broadway and Oban are two different things and only one of them is missing
here.** Broadway is a *stream* processor (GenStage: demand + stages + batching)
— beam-lisp already has that, it's `flow`. Oban is a *durable clock* (a table + a
poller + retries + uniqueness) — that is genuinely absent, because `OTP` ships
timers and nothing else. The scheduling primitive that exists is the **Timeout
Edge** (`(after ms …)`), already named in `the-process-pattern-language.md §1.5`;
its periodic child **Heartbeat §4.1** is marked `◐ vitals; ○ stdlib fns` and is
the unbuilt piece. So this isn't "add a scheduler subsystem" — it's **name the
last patterns (Tick, Deadline Queue, Claim/Lease, Retry, Idempotency Key),
bundle them into two `def*` forms, and let the store be the timer wheel.** The
`bl ui` pane then falls out for free, because `vm.inspect` already is the one
model with three faces.

---

## 1. Lay of the land — how the two products actually do it

### 1.1 knowledger — a durable queue with no clock

`knowledger/library.bl` is a hand-rolled **Oban minus the scheduler**:

```
:job/* in the control space (fjall, durable)
  states  :awaiting-confirmation → :queued → :reading → :chunking → :transacting
          → :embedding → (graph stages) → :published | :failed | :rejected
create-job!        id = sha(source|libmeta|day|unique)  ← deterministic = idempotent
run-job-async!     DynamicSupervisor/start_child(worker …, {:restart :transient})
job-attempt!       mid-flight → RE-QUEUE and redo (librarium ingest is idempotent)
                   terminal / awaiting-confirmation → left alone
supervised-job     registers self in library-registry {:kind :job :job id} on start
                   and after every restart → job-worker/1 finds the pid across a heal
ingest-keeper      one keeper owns the tree (start-link links to the first asker,
                   and a job is asked for by a Bandit request process)
```

Strengths (keep these): state machine as **facts**; idempotent re-run; registry
survives restarts; supervisor restarts workers.

Absent: **no clock.** Nothing fires on time. No `scheduled_at`, no cron, no
retry/backoff, no delayed job, no lease/orphan detection, no pruner. Expiry
(invites, oauth codes) is checked **lazily on read** (`(> exp now)`), never
swept. The queue is *push-driven only*.

### 1.2 blueprint — time as a value, one sweep, and it's off

`printflow/clock.bl` + `datom.time`: everything time-shaped is a **scale-second
on one monotone axis**; `(plant/at day h m)` authors a moment; the calendar is a
read-side projection. Maintenance windows, promises, incident stamps are all
`:db.type/time` intervals with Allen predicates.

Its scheduling is two mechanisms, one shape:

| mechanism | where | how |
|---|---|---|
| **edge rule** | `notify/arm-rules!` | `datom/watch` on `[?e :ev/reason :panne]` → fires inline in the writing path |
| **derived rule** | `notify/sweep!` | re-derives age/rate (bat-late, blocked-long, slowdown) at `now` and raises |
| **the ticker** | `notify/start-monitor` | `erlang/spawn` + `(receive … (after ms …))` loop |
| **bounded by proof** | `notify/verify-interval` | z3 proves `□(interval-ms ≥ 30000)` from the `notify-monitor` checkable core |

Two honest findings:

1. **`start-monitor` is dead code in the running app.** Grep shows it referenced
   only in `notify.bl`; `notif-test` calls `sweep!` synchronously. There is
   exactly **one periodic loop in the whole repo, and no server calls it.** So
   blueprint's "scheduling" in production is: a *re-placer* (recompute the plan
   on every fact change — no timer), plus one unwired sweep.
2. **Idempotency by construction is the load-bearing trick.**
   `notif-id = (rule, subject, time-bucket)` + unique-identity ⇒ at-least-once
   delivery, at-most-once *effect*. Same trick as knowledger's `job-id`. This is
   the pattern, not an accident.

### 1.3 The daemon already hand-rolls four schedulers, in three shapes

This is the sharpest finding, and it's the "why now":

| where | what it is | shape |
|---|---|---|
| `priv/std/vm/exec.bl` | a **serial sequencer**: reloads and intents take turns on one mailbox; publishes `{:busy :queued}` to a public ETS row | ETS row + gen_server |
| `priv/std/vm/index.bl` | a **background job with progress** (`:phase :done :total :file :ms`), public ETS row, one owner, idempotent kick | ETS row |
| `lib/beam_lisp/reload_watcher.ex:155` | a **debounce**: `Process.send_after(self(), :flush_pending, quiet_ms)` — a State Timeout | Elixir + `send_after` |
| `priv/std/vm/gateway.bl:461`, `vm/client.bl:47` | **polling waits**: `:timer.sleep` in a liveness loop | `:timer.sleep` |

Plus `bl cache prune` — a *periodic job run by hand*.

∴ **One need ("wake me later / on a boundary / after quiet"), four
implementations, two languages, three shapes.** That's principle 2 violated in
the runtime itself. Consolidating these is the natural first tenant of the
substrate.

### 1.4 What already exists in `priv/std` (verified, not assumed)

```
server     ✅ defserver (init|handle-call|handle-cast|handle-info|name|invariant)
supervisor ✅ super/defsupervisor, children, child-of, terminate, restart, pool
registry   ✅ reg/defregistry (keys …), reg/register|whereis|where (datalog)
bus        ✅ bus/defbus, bus/publish, flow/subscribe, flow/broadcast (lag policies)
fence      ✅ fence / fence-fn  (Monitor + Ask + Timeout Edge → a value)
flow       ✅ producer, from-seq, transform, map-/filter-/expand-/mapcat-stage,
              run, run-each, subscribe, broadcast
           ○ distribute, merge, batch      ← Broadway's missing half only
datom      ✅ transact! q pull entity as-of since history
           ✅ watch / unwatch / listen! / unlisten!      ← the notifier already exists
datom.time ✅ interval from to width allen overlaps? expand consistent?
           ○ RRULE / recur-rule                          ← designed, not built
system     ✅ verify, verify-process, verify-liveness, verify-capacity,
              synthesize-capacity, find-lasso, establishes?, preserves?, deadlocked
bl.ui      ✅ vm.inspect/model → terminal text + HTML + /model JSON, all one value
```

---

## 2. The OTP way — what's actually there, and what each library is compensating for

### 2.1 OTP gives you timers, and only timers

```
erlang:send_after/3 · start_timer/3   the primitive (a one-shot message)
receive … after T                     a timeout EDGE in a loop
gen_server {timeout, T} / handle_info :timeout
gen_statem state_timeout / {timeout,T}  a RESETTABLE edge (debounce, idle)
:timer.send_interval/2                periodic, FROM A SERVER PROCESS
:timer.apply_interval/4               periodic, drift-compensating
```

Everything else is convention:

- **one owner process** holds the timer (`:timer` is itself a supervised server);
- the tick is a **state transition**, not a callback;
- the ticker lives **under a supervisor**;
- **durations are monotonic, deadlines are wall-clock** — `monotonic_time` for
  "in 30s", `system_time` for "at 07:00", and you must re-check "am I actually
  due?" on wake (a VM suspend or NTP jump breaks naive intervals);
- `send_interval` **drifts**; a boundary-aligned scheduler asks "how long until
  the next boundary?" and re-arms the *delta*.

**OTP gives no durability, no retries, no uniqueness, no cron, no timezone, no
pruning, no orphan detection, no queue depth.** `:timer` dies with the node. That
is the entire gap Oban fills.

### 2.2 What Oban and Broadway decompose into

| Oban piece | mechanism | beam-lisp equivalent that already exists |
|---|---|---|
| `jobs` table | Postgres rows + states | **a datom relation** (`:job/*` — knowledger already does this) |
| `Notifier` (PG LISTEN/NOTIFY) | wake queues on insert | **`datom/watch` / `listen!`** (the broadcast-substrate doc §8) |
| `Producer` per queue | polls `available`/`scheduled`, dispatches to `Task.Supervisor` | **`defsupervisor` + `super/pool` + `reg`** |
| `Cron` plugin | inserts jobs on a schedule | **the missing piece — Tick + Deadline Queue** |
| `Pruner` plugin | periodic delete of terminal jobs | **the same Tick** |
| `Lifeline` plugin | rescue orphaned `executing` jobs via `attempt`+`lease` | **Claim/Lease over the store + Monitor** |
| `unique` / `max_concurrency` | DB constraint / per-queue limit | **unique-identity + `reg/where` count** |
| retry with backoff | `attempt` + `scheduled_at` | **Retry Edge (⊥ → later)** |
| telemetry → Oban Web | pub/sub + a dashboard | **`vm.inspect` + `datom/watch`** |

| Broadway piece | mechanism | beam-lisp |
|---|---|---|
| producer / processor / batcher / consumer | GenStage | **`flow`** (Demand, Metered Stage, Pipeline) |
| backpressure | demand | **`flow`'s demand protocol** ✓ |
| batching | `handle_demand` accumulation + timeout | ○ (a `batch` stage — not built) |
| multiple consumers per stage | `Flow.Partition` / distribute | ○ **`flow/distribute`** (in the ledger as unbuilt) |
| telemetry | `:telemetry` events | a Heartbeat + Snapshot; the pane |

**∴ Broadway's need is already 80% met by `flow`; what's missing is
`flow/distribute` + `batch` + a `defpipeline` skin. A "recurrent work" need is
Oban's need, and it's the unbuilt half.** The only overlap: a *never-ending
stream* is recurrence — `flow/producer` already has the long-idle re-loop
`(after 3600000 …)`.

---

## 3. The pattern language: scheduling × concurrency

### 3.1 Scheduling is not a new subsystem — it's the Timeout Edge meeting the store

Every scheduling pattern is a composition of patterns the doc **already names**.
The one new axis is *where the deadline lives*: in a process (cheap, lost on
crash) or in a relation (durable, inspectable).

| need | pattern (new name) | composes with (existing names) | where the deadline lives |
|---|---|---|---|
| "in 30 s, do X" | **Tick · once** | Timeout Edge §1.5, Loop-Carried State §1.1 | process |
| "every 15 m, do X" | **Tick · interval** (= Heartbeat §4.1) | Timeout Edge, Snapshot §4.2 | process |
| "at 07:00 daily", drift-free | **Tick · aligned** | Timeout Edge + calendar math | process |
| "after 200 ms of quiet" | **Tick · state-timeout** (= debounce) | Timeout Edge (reset on message) | process |
| "when T arrives, durably" | **Deadline Queue** | Loop-Carried State + Ask over a **store** | **relation** |
| "at most one runner" | **Claim / Lease** | Correlated Reply §1.4 + unique-identity | relation |
| "retry", "back off" | **Retry Edge** (⊥ → *later*) | Healing Edge §3.3 + Governor §3.4 | relation |
| "run it at most once per key" | **Idempotency Key** | unique-identity + Monitor §3.1 | relation |
| "at most K at once" | **Concurrency Limit** | Fan-Out distributed §2.4 + Demand §2.2 | relation |
| "missed while down" | **Catch-up policy** (`:skip`/`:coalesce`/`:run-all`) | Deadline Queue | relation |
| "N jobs at midnight" | **Jitter** | Tick · aligned | value |
| "resume where I got to" | **Watermark / Cursor** | Loop-Carried State | relation |
| "the job hangs" | **Bounded Isolation** ✅ `fence` | Monitor + Ask + Timeout Edge | — |
| "the ticker died" | **Healing Edge** ✅ supervisor | Monitor + Governor | — |
| "prove it can't double-book / can't stall" | **Invariant Gate** ✅ `system/verify` | `verify-liveness`, `verify-capacity`, `find-lasso` | — |

**The two patterns that make it durable are the two that need no new machinery**:
*Idempotency Key* (unique-identity, already used twice in the wild) and
*Claim/Lease* (a guarded transact). Everything else is already shipped.

### 3.2 The move that makes it beam-lisp and not Oban

> **The store is the timer wheel; the process is just the hand that turns it.**

Oban needs Postgres *and* a poller *and* a Notifier because in Postgres the table
cannot wake you. Here:

```
the wheel      ≈ an ordered set of :schedule/at       (ETS ordered_set, or an AVET range scan)
the wake       = ONE (after ms …) at the earliest deadline
on fire        = query due → claim (CAS :lease) → run → advance :at → re-arm
on restart     = re-derive the whole wheel from the store; a missed deadline is VISIBLE (at < now)
the notifier   = datom/watch  (no second transport)
the registry   = reg          (no pid table)
the restart    = defsupervisor (no restart machinery)
the pane       = vm.inspect   (no new model)
```

So the whole thing is **a relation + a tick + a watch**. That's ~200 lines and
zero new subsystems — and every review must ask *"is this a pattern already
named?"* before adding a mechanism.

### 3.3 The central design tension (SETTLED: fact-first)

**Is a schedule a process or a fact?**

```
A: schedule = process (defscheduler owns in-memory timers)
   ✓ cheap, no store round trip, exactly OTP
   ✗ dies with the VM · pause/resume/next are pids+bit state · the pane must ask
     the process (and after a restart it disagrees with what was declared)
B: schedule = fact (a :schedule/* relation) + ONE ticker process that owns the
   next-wake; the claim/lease/run are transactions
   ✓ durable · pause/next/explain are queries · the pane reads the same fact the
     scheduler reads, so it cannot lie · testable without a wall clock
   ✗ one store read on the fire path (see ⚠ dirty-IO, §6)
```

**Decision: B for anything declared and monitored (fact-first); A (`(tick …)`)
for housekeeping inside one process.** Rule of thumb: *does a human need to see
or change it?* → fact. *Is it this process's private beat?* → tick. Both lower to
the same trace (a Timeout Edge), so `system.model` sees one shape and
`verify-liveness` already covers "does the wake edge exist".

---

## 4. Proposed bundles, syntax, namespaces

Two new bundles, one clause, two stages. Fitting the house style exactly
(`defserver`/`defregistry`/`defbus`/`defsupervisor` clause shapes).

### 4.1 `(tick …)` — the clause (Heartbeat, made a verb)

```clojure
(ns jobs.house)

(defserver reaper
  (init [_] (ok {:last nil}))
  (invariant [_s] true)
  (tick 15 :minutes                       ; ≙ send_after + handle-info + re-arm
    (do (reap-orphans! conn) (noreply {:last (now)}))))

;; each option is a POLICY VALUE, not a code path
(tick 30 :seconds :anchor :wall)          ; wake on the wall-clock boundary (no drift)
(tick 5  :minutes :catch-up :coalesce)    ; missed while down → run once, not N
(tick 1  :hour    :jitter 0.10)           ; ±10%, de-sync N nodes/processes
(tick 2  :seconds :on-error :continue)    ; a throwing body doesn't kill the ticker
(tick 200 :ms     :reset-on :activity)    ; a DEBOUNCE (gen_statem's state_timeout)
```

Compiles to `init` + `handle-info [:tick]` + re-arm — one new case in
`BeamLisp.Server/callback` dispatch (`compile-defserver` already special-cases
`invariant` the same way, `priv/boot/compiler.bl:2943`). **No new runtime.**

> **Rung (temporary).** `priv/boot/` cannot be edited until the bootstrap ladder
> is repaired (`PLAN-088`). The clause therefore lands first as a std macro over
> `defserver` — the same rung `defregistry`, `defbus`, `defsupervisor` occupy —
> and is replaced by the real clause when the ladder climbs. That is a cutover,
> not a parallel implementation.

### 4.1.1 As built (P1 → P1.5) — the clause landed, 34 assertions green

The clause above is now REAL. There is no `defbeat`, no second name for the
graph, and the beat composes with a server's other clauses — which no form
could do. What runs today, exactly:

```clojure
(ns jobs.house
  ; the FORM from `server`, qualified (a bare `defserver` is the compiler's
  ; own — a special form is checked before macros); requiring `tick` is what
  ; REGISTERS the `tick` clause
  (:require [server :as server]
            [tick :as tick]))

(server/defserver reaper
  (init [_] (ok {:last nil}))
  (tick 15 :minutes [st]                    ; a params vector, as in every
    (do (reap-orphans! conn)                ; other defserver clause
        (noreply {:last (tick/wall-ms)})))
  (handle-call :last [_from st] (reply (:last st) st)))

;; policies, each a value
(server/defserver house
  (tick 30 :seconds {:anchor :wall} [st] (sweep!))          ; lands on the boundary
  (tick 1  :hour    {:jitter 0.10}  [st] (poll!))          ; ±10%, de-sync peers
  (tick 2  :seconds {:on-error :continue} [st] (sweep!))   ; survive a throwing body
  (tick 200 :ms     {:once true}    [st] (flush!)))        ; a one-shot …

;; … and the debounce is that one-shot plus a reset on activity:
(handle-info [:activity] [st]
  (do (tick/tick-reset 200 {:name 'house}) (noreply st)))
```

And the composition that motivated the whole change — a server's own slice of
state and a clause's slice in ONE `init`, which a macro could never express:

```clojure
(server/defserver composite
  (init [_] (ok {:mine 1}))     ; the server's slice
  (slice 42)                    ; a clause's slice (a test-local transform)
  (tick 25 :ms [st] (noreply (assoc st :n (inc (or (:n st) 0))))))
;; → {:mine 1 :slice 42 :n 4…}
```

**What changed, and why**

| the sketch | as built | why |
|---|---|---|
| `(tick …)` as a `defserver` clause | `(tick …)` as a `defserver` clause ✅ | the std expander landed (P1.5, `priv/std/server.bl`), so the clause is real and `defbeat` is deleted |
| `(tick N UNIT opts? BODY)` | `(tick N UNIT opts? [state] BODY)` | the body must have a NAME for the state it returns — every other `defserver` clause has one, so this is not a wart, it is the missing half of the sketch |
| `:catch-up`, `:reset-on` | **rejected** | both are DEADLINE policies: a missed deadline and an overlapping run are possibilities only a durable queue has. They arrive with `defscheduler`; here they are a loud error |
| — | **`:once`** | the debounce needs a tick that does not re-arm; `:once` + `tick-reset` is the whole pattern |

**The clause vocabulary is now open, and the vocabulary is DATA.**
`priv/std/server.bl` registers clause heads (`extend-clause!`) and lowers every
clause to one boot `defserver`. It validates a head against the compiler's OWN
table (`BeamLisp.Server/callback`, so there is no second list to drift) plus the
registry, and reports an unknown one with the whole accepted set — where the
boot path answers `1st argument: not a tuple`.

**Two facts about macros, learned by probing rather than by reading:**

1. **A special form beats a macro** (`compiler.bl:4014`), so a bare `defserver`
   can NEVER be the std one. Hence the qualifier, `(server/defserver …)`.
2. **A REFERRED macro does not resolve through a qualifier.** Verified:
   `(ns b (:require [a :refer :all]))` then `(b/macro-name)` compiles to a call
   on the `$macro` VALUE — "a value is not a function" — while `(a/macro-name)`
   works. So a macro lives in exactly one namespace, and neither an umbrella
   nor a bundle can re-export it (FUP-097 is corrected by this).

Both vanish with one boot edit: rename the special form to `defgen`, and
`(:require [server :refer [defserver]])` + `(defserver …)` finally does what it
looks like it does.

**The generation counter is the subtle half.** `cancel_timer` cannot un-send a
message already delivered, so a reset must be able to make a tick *stale*. Each
arming bumps a counter kept in the process dictionary (a timer is process-local
ephemera; forcing every server's state to carry a timer slot is the tax this
avoids), and the handler compares before running its body. Without it a debounce
fires twice under load.

**The clock is injected, and here is what that buys.** `tick-delay` is pure —
`(tick-delay period opts now)` — so "when does the next tick land?" is answered
without a process, a sleep, or a wait. `wall-ms` is only the default; a test
passes a fixed clock, and `:anchor :wall` was verified by arithmetic rather than
by hoping a wall clock landed where it should.

**Location: `priv/std/tick.bl` — the correct tier.** An earlier revision of this
note moved it to `priv/lib` because the tree's `priv/std` appeared unsearchable.
That was wrong, and the reason matters:

```
./bl -p priv/std run examples/tooling/tick.bl        ✓   run never loads tree dev tooling
./bl -p priv/std test --shared test/bl/tick_test.bl ✓   27 assertions, 0 failures
./bl -p priv/std test --async  test/bl/tick_test.bl ✓   27 assertions, 0 failures
./bl -p priv/std test test/bl/tick_test.bl          ✗   undefined var: source-graph/cycles
./bl -p research  test test/bl/deferred_test.bl     ✓   21 passed — a neutral root is fine
```

`-p` is honoured everywhere. What fails is `test`'s DEFAULT ward path, and it
fails for ANY test file — because the ward loads the tree's dev tooling
(`reload/ward.bl`, `codebase.bl`), which needs `source-graph/cycles`, and the
installed DROP is a stale generation whose `priv/build/source-graph.bl` has no
`cycles` at all. `source-graph` is a boot-tier kernel namespace loaded by the
drift gate before any CLI path applies, so no `-p` can dislodge it.

```
drop  …/9dcd3cad/…/priv/build/source-graph.bl   cycles=0
tree  priv/build/source-graph.bl                cycles=1
```

So the standard library cannot be developed in place yet, and the honest
working loop is `bl test --shared` (which gives up the per-file isolation the
ward exists to provide). Filed as **FUP-093** with the full matrix and the fix
direction. **The tier is not negotiable in the face of a tooling bug**: the
module belongs in `std/`, the tooling must catch up.

**What P1 deliberately does not do:** it has no timers that survive the process,
no counters a pane can read from outside, and no way to ask *when* a beat will
fire next from another process. Those are exactly the deadline queue's reasons
to exist.

### 4.2 `defscheduler` → AS BUILT: the `(sched …)` clause

**Built (P2), 18 tests / 56 assertions.** Because P1.5 landed the expander
first, the deadline queue was a CLAUSE from birth and never took a
`defbeat`-shaped detour — which is the reason P1.5 went first.

```clojure
(ns jobs.schedule
  (:require [proc :as proc] [proc.server :as server]))

(server/defserver housekeeping
  (init [_] (ok {:firm "acme"}))          ; the server's OWN slice of state
  (sched {:clock wall-clock}               ; injectable; defaults to the wall
    (every 15 :minutes :reap-orphans reap-orphans! {:catch-up :skip :jitter 0.05})
    (daily 07 00       :digest       send-digest!  {:catch-up :coalesce})
    (at    1790000000000 :go-live    switch-to-live!))
  (handle-call :firm [_from st] (reply (:firm st) st)))

(proc/spec     h)   ; the declaration AS DATA
(proc/next     h :digest)
(proc/pause    h :reap-orphans)   ; keeps the due, so resume runs it
(proc/resume   h :reap-orphans)   ; …and re-arms the wheel
(proc/run-now  h :digest)
```

| the sketch | as built | why |
|---|---|---|
| `defscheduler`, its own form | `(sched …)`, a clause | one form, one vocabulary; it composes with the server's state |
| a rule is a lazy seq of intervals | `every` / `daily` / `at`, answered by `first-due` and `advance-n` | a rule needs exactly two questions answered, and both are arithmetic — the lazy-seq shape is *tempo*'s and can arrive with it |
| `:overlap :skip` | **rejected**, and the error names `:catch-up` | a self-send cannot overlap itself; for a single owner, "the previous run has not finished" and "an occurrence was missed" are one event |
| `:cron`, `:tz`, `:run-all` | `:cron`/`:tz` rejected with a *why*; `:run-all` implemented with `MAX-CATCH-UP` | an unimplemented option that silently does nothing is the worst kind of configuration bug |
| `:schedule/*` as facts in the store | the DECLARATION is in the code (a literal, durable by construction); the OUTCOME is a row in one public ETS table (**P2b**) | the durable half is four fields per schedule — what ran, what failed, and the human's pause — and that is the whole difference between a restart that resumes and one that repeats |

**Four things the build taught, all by measurement:**

1. **Catch-up must be arithmetic.** The first implementation walked the missed
   occurrences one at a time; a schedule dormant for a year at a one-second
   period is 31M iterations, which is a hang wearing a policy's clothes.
   `missed-count` and `advance-n` answer in O(1).
2. **A late wake is not a missed occurrence.** The rule that matters is
   *"has the SUCCESSOR already passed?"*, not *"is it late?"*. Reading any
   lateness as a miss made `:skip` drop every fire — a schedule that silently
   never runs.
3. **Jitter scales the DELAY, never the due.** `:due` is absolute epoch-ms, so
   five percent of it is six weeks: a `(every 60 :ms … :jitter 0.05)` schedule
   armed 688 days out and never fired.

And one that was reasoned and then confirmed: **`resume` must re-arm.** A paused
schedule holds no wake, so the moment of resuming is exactly when the wheel has
to be wound again — without it the schedule is alive and never fires.

**P2b — the store, and the four things IT taught.**

| attempt | what went wrong |
|---|---|
| `{server, id, record}` as the row | an ETS `:set` keys on ELEMENT 1, so the key was `server` alone: every `{server, id}` lookup missed, and a second schedule on one server would have silently overwritten the first |
| the store created by the first scheduler | **an ETS table dies with the process that created it.** The first scheduler took the store with it, the second started from an empty table, and the symptom was "a one-shot ran twice across a restart" |
| `(= :undefined (Process/whereis name))` | `:ets.whereis` answers `:undefined` but `Process/whereis` answers **`nil`** — two registries, two miss values. Comparing the wrong one silently took the other branch, so the long-lived owner was never started and the table was created by whoever asked first |
| `(catch _e nil)` around the keeper start | swallowing the failure turned "the store never worked" into a silent misbehaviour three restarts later. It now re-raises unless the table arrived anyway (the one benign case: two schedulers racing, the loser finding the winner's table) |

**P2b.1 — ownership, by design.** The first version was *careful*: a keeper
created the table, and a fallback branch could also create it in whoever asked.
That fallback WAS the bug — an ETS table dies with its owner, so the branch that
looks like a safety net is the branch that hands the store to a transient
process.

But the fix is not a rule this file follows; it is a pattern the tree HAS. Every
ETS-backed store carries the same hazard — `datom/store-ets` documents it in
those words and has no heir — so the pattern lives once, in
**`priv/std/proc/table.bl`**, and is pattern **3.6 Heir** in the process pattern
language. This file uses it in one line:

```clojure
(table/hold :bl_sched {:type :set
                       :options [:public :named_table (tuple :read_concurrency true)]})
```

`hold` starts two processes if they are not running, and then asserts the
invariant. It never creates the table itself:

```
1. ONE CREATOR   `:ets.new` appears in `table-keeper`'s init and NOWHERE ELSE.
                 A fallback that "creates it if missing" is the whole bug
                 wearing a safety net.
2. AN HEIR       named AT CREATION, so there is no instant in which the table
                 exists unheired. The keeper's death TRANSFERS it to the heir;
                 the heir gives it back to the next keeper.
3. CHECKED       `hold` does not return until this table's KEEPER owns it — an
                 heir holding the table is the designed state BETWEEN two
                 owners, but `hold` is the call that ends that window, so a
                 window still open a second later is an ERROR, not a state.
```

It is not that nobody is *allowed* to kill the keeper — it is that killing it no
longer costs anything. Asserted directly in `test/bl/table_test.bl` (the pattern)
and end-to-end in `the-store-outlives-its-OWNER` (this file): kill the keeper,
the store survives, the heir holds it, the next keeper reclaims it, and a
one-shot that ran still does not run again.

**The failure mode is SILENCE, and it was measured twice — both times in this
store.** Building the pattern produced two defects that neither crashed nor
logged; the only symptom either would have had is the one that started this whole
thread, a one-shot that ran twice:

| the defect | why it was invisible |
|---|---|
| `:ETS-TRANSFER` written unquoted | it is not a name, it is the EXPRESSION `:ETS - TRANSFER`, so the clause compiles and never matches. The heir still OWNS the table — ownership transfers whether or not anything handles the message — so reads kept working and the store was merely one process from vanishing instead of two |
| the heir's state `assoc`'d one level too shallow | `(assoc (:holding st) …)` rebuilds the INNER map, so the new state was `{table tid}` with no `:holding` key. The heir owned the table and had no record of it, so every reclaim answered `:nothing` |

Both are the same shape: **the table is alive, owned, and no longer
recoverable.** Nothing fails; the protection just quietly drops from two-deep to
one-deep. Rule 3 is what catches them — the assertion is not decoration, it is
the thing that turned a silent degradation into a red test.

A third, smaller one: the heir's holdings are keyed by table NAME, read from
`:ets.info(tid, :name)`, because the transfer message carries a tid and the
keeper asks by name.

**P2c — datom over `store-ets`. AS BUILT.** The declaration and the outcome
belong in the database, not in a bespoke table: a reader then queries schedules
with the same language as every other pane, `history`/`as-of` come free, and
`:schedule/key` being `:db.unique/identity` means a tempid UPSERTS — one
transaction per write, with no read-modify-write window.

```clojure
(def SCHEMA
  [{:db/ident :schedule/key :db/valueType :db.type/string
    :db/unique :db.unique/identity :db/cardinality :db.cardinality/one} …])

(defn- store [] (store-ets/adopt (table/hold STORE {:type :ordered_set
                                                    :options [:public :named_table]})))
(defn conn [] …(datom/connect-with (store) SCHEMA)…)   ; published in :persistent_term
(datom/pull (datom/db (conn)) '[*] [:schedule/key "kitchen/prep"])   ; the read
```

**The plan was wrong about where the heir goes, and the correction made it
smaller.** P2c was scoped as (a) give `datom/store-ets` an heir, (b) publish the
conn, (c) swap four functions. (a) is unnecessary: the table's LIFETIME belongs
to whoever owns the store, not to the substrate that wraps it — so the store is
created through `proc.table` and the database merely **adopts** it
(`store-ets/adopt`). That also deletes (b)'s problem: the table is NAMED, so its
handle is re-derivable with no process call, and the connection is published in
`:persistent_term` only so a reader can name a BASIS. Reads never touch the
writer (`datom/db` builds a value from the basis atom), and two connections over
one store share a writer and a basis through datom's own registry.

**Acceptance met.** The 22 sched assertions were written against the store's
BEHAVIOUR, so they are the proof: 42 tests / 132 assertions green, and the same
count as before the migration — nothing was dropped to make it pass.

**Three defects, all silent, all in the substrate rather than the design:**

| defect | symptom |
|---|---|
| every row in a batch carried `:db/id -1` | two maps with the same tempid in one transaction describe the SAME entity, so writing N schedules collapsed them into one — the last won, every other key read back `nil`. Now a counter assigns distinct tempids |
| pull answers with attribute KEYS, and `inspect` renders `:schedule/runs` as `"schedule/runs"` | it reads as a string and is not one, so comparing against a string matched nothing and every schedule looked like it had never run |
| `:last-occ` is the occurrence id — a STRING | the schema rejected the write, loudly, which is the one failure mode here that announced itself |

The first two share the shape of §P2b.1's pair: the store is alive, the data is
in it, and the reader is told nothing. `(keys m)` settles the type question; a
red test settles the rest.

---

### 4.2.1 The sketch (kept as the target for the durable half)

```clojure
(ns jobs.schedule
  (:require [datom] [datom.time :as time] [sched] [system]))

(defscheduler housekeeping
  ;; a recurrence is a lazy seq of intervals — tempo §8's shape, no new arithmetic
  (every  15 :minutes  :reap-orphans  reap-orphans!  {:overlap :skip :jitter 0.05})
  (every   1 :hour     :reindex       reindex!       {:catch-up :coalesce})
  (daily  07 00        :digest        send-digest!   {:tz "Europe/Paris"})
  (cron   "0 3 * * *"  :vacuum        vacuum!        {:if-running :skip})
  (at     #time"2026-10-01T09:00" :go-live switch-to-live!})   ; one-shot, durable

(def h (start-link housekeeping))

(sched/next    h :digest)          ; {:at #time"2026-09-19T07:00" :in-ms 65104000
                                   ;  :runs 9 :last #time"2026-09-18T07:00:03"}
(sched/pause   h :reindex)         ; a FACT, not a bit in a process
(sched/run-now h :reap-orphans)    ; claim + fire out of band
(sched/explain h :digest)          ; WHY the next run is when it is (tempo §5's narrating fn)
(sched/spec    h)                  ; the declaration AS DATA (super/tree's shape)
(system/verify 'housekeeping)      ; □(period ≥ floor), no lasso through ⊥, every
                                   ; Ask answered, the lease bound is preserved
```

State, as facts (this is what the pane reads):

```
:schedule/id        "digest"
:schedule/rule      {:freq :daily :at [7 0] :tz "Europe/Paris"}   ; or :rrule / :every
:schedule/at        #time"2026-09-19T07:00"     ; the wheel key (range-scannable)
:schedule/state     :active | :paused
:schedule/lease     {:owner <pid> :until #time"…"}   ; Claim — CAS, default 2× period
:schedule/last      #time"…"  :schedule/runs 9  :schedule/fails 0
:schedule/overlap   :skip | :queue | :replace | :allow
:schedule/catch-up  :skip | :coalesce | :run-all
:schedule/jitter    0.05   :schedule/on-error :continue
```

`overlap`/`catch-up`/`jitter`/`if-running` are **values**, so `sched/explain` can
narrate a decision and the pane can show a policy column — the same trick as
`hw.gpu.mode` in the AGENTS.md AVD config, but as a queryable fact.

### 4.3 `defqueue` — durable jobs (the Oban bundle)

```clojure
(ns jobs.ingest)

(defqueue ingest
  (concurrency 4)                                   ; □(executing ≤ 4) — z3, like outbox's ≤200
  (retry 5 {:backoff :exponential :base 1000 :max 60000 :jitter 0.2})
  (unique    {:by [:job/source] :for 60})           ; unique-identity, one window
  (lease     300)                                   ; orphan detection (Lifeline)
  (prune    {:completed "7d" :discarded "30d"})     ; the Pruner, as a Tick
  (partition :by [:job/library])                    ; per-key serialisation

(def q (start-link ingest))

(jobs/perform q :ingest (fn [args _job] (run-ingest! args)))     ; a plain fn
(jobs/enqueue q {:kind :ingest :args {:lib "notes" :source p}})  ; immediate
(jobs/enqueue q {:kind :ingest :args {…} :in 30 :seconds})       ; delayed
(jobs/enqueue q {:kind :ingest :args {…} :at (sched/next h :digest)})
(jobs/stats  q)   ; {:scheduled 12 :available 3 :executing 2 :retryable 1 :discarded 4}
(system/verify 'ingest)   ; the concurrency bound, the retry lattice, lease ≥ timeout
```

**This is a cutover, not a parallel implementation:** knowledger's
`run-job-async!` + `runner-sup` + `supervised-job` + `job-worker` + registry
delete down to `jobs/enqueue` + `jobs/perform`, riding the *same* control-space
store it already uses for `:job/*`.

### 4.4 `defpipeline` — Broadway, which is `flow` + 2 stages

```clojure
(defpipeline enrich
  (source  (flow/from-conn conn {:attrs #{:datom/tx}}))  ; or a defbus, or from-seq
  (stage   :parse  parse-tx)
  (batch   :embed  32 {:timeout 200})                    ; ○ new stage: batch (Broadway's batcher)
  (stage   :write  write-embeddings!)
  (concurrency 8)                                        ; ○ flow/distribute — already in the ledger as unbuilt
  (on-lag  :block))                                      ; no Demand ⇒ Tell is the flagged hazard
```

### 4.5 Namespace map (proposed)

```
priv/std/proc.bl        (ns proc)          the umbrella — one require, the verbs
priv/std/proc/server.bl (ns proc.server)   the EXPANDER: defserver + the clause registry
priv/std/proc/tick.bl   (ns proc.tick)     the `(tick …)` clause
priv/std/proc/sched.bl  (ns proc.sched)    the `(sched …)` clause — the deadline queue
priv/std/{flow,bus,reg,super,fence}.bl     still loose; referred by proc.bl, moved
                                           one commit at a time (FUP-097)
priv/std/jobs.bl        defqueue · enqueue · perform · stats · retry · cancel · prune
vm/inspect.bl           :schedules, :jobs ← the pane, no new model
vm/http.bl              GET /schedules · POST /schedules/<id>/{pause,resume,run-now}
bl:  bl schedules [--json]  ·  bl jobs [--json]
```

---

### 4.6 The `defserver` question — the clause vocabulary belongs in std, not in boot

`defbeat` exists only because a clause name cannot be added to `defserver`
without editing the compiler. That is the real defect, and it is worth fixing:
the same wall forces `defregistry`, `defbus`, `defsupervisor` and `defbeat` to
be four hand-copied `defserver` bodies instead of four thin transformations.

**The evidence, read from the compiler.**

```c
// priv/boot/compiler.bl:4014 — the head dispatch, in order
(cond
  (and (some? name) (contains? special-forms name)) (compile-special name (rest items) env)
  (and (some? name) (not (local? env name)) (macro? env name)) (compile-node (macroexpand-1-env form env) env)
  :else (compile-call items env))
```

**A special form is checked BEFORE a macro**, so a std macro can never shadow
`defserver`. Confirmed by reading the line, not by trying it. Any design where
std owns the vocabulary must therefore *rename the boot form* — there is no
clever way around it.

Today the vocabulary is split across three places, which is why it is hard to
extend:

| where | what it owns |
|---|---|
| `lib/beam_lisp/server.ex:86-92` | `callback/1` — the head→OTP map: `"init" → {:init, 1, :vector}`, `"handle-call" → {:handle_call, 3, :pattern}`, … `_ → nil` |
| `lib/beam_lisp/server.ex:241` | `callback_order` — the OTP callback set, used to synthesize defaults |
| `priv/boot/compiler.bl:2943` | `compile-defserver` — and the **non-callback special case**: `(if (= hd "invariant") (assoc acc :inv …))`, compiled to a `:__invariant__` vector clause. *This is the half-remembered "special case that modifies the parent form".* |

And the current failure mode for an unknown clause name is not a diagnostic:
`callback/1` answers `nil`, `compile-defserver` does `tuple_to_list(nil)`, and
the user sees **`1st argument: not a tuple`** — an error this very session spent
a bisect on, from an unrelated cause. A language whose clause names are
extensible must name the ones it has.

**The design: `defgen` in boot, `defserver` in std.**

The boot primitive takes a *normalized descriptor* — no vocabulary, just keys
that are already OTP callback names plus a meta slot — and std owns the mapping:

```clojure
;; BOOT (priv/boot/compiler.bl) — the floor. It knows the VM, not the language.
(defgen reaper
  {:callbacks {:init        {:shape :vector  :clauses [(init [_] …)]}
               :handle_info {:shape :pattern :clauses [(…) (…)]}}
   :meta      {:__invariant__ {:shape :vector :clauses [(invariant [st] …)]}}
   :opts      {:otp [:handle_call :handle_info :terminate …]}})
```

```clojure
;; STD (priv/std/server.bl) — the vocabulary, and a REGISTRY so it is open.
(srv/extend-clause! :tick
  (fn [clause ctx]
    ;; → real clauses to splice + a prelude for init
    {:prelude [(tick/tick-arm period opts)]
     :clauses [(handle-info [:bl/tick n] [st] …)]}))
```

Then `(tick …)` is a clause of `defserver` itself:

```clojure
(srv/defserver reaper
  (init [_] (ok {:done 0}))
  (tick 15 :minutes [st] (do (reap!) (noreply (inc-n st))))
  (invariant [st] (>= (:n st) 0)))
```

**What it buys.**

- **`defbeat` is deleted.** No placeholder, no second name for one graph.
- **The four bundles stop being four copies.** `defregistry`, `defbus`,
  `defsupervisor` and the scheduler bundle become descriptor *transformations*
  over one primitive — so a fix to the primitive reaches all of them, which is
  the whole point of `the-five-bundles.md`.
- **The clause vocabulary becomes data**, so `system.model` can list what a
  server accepts and an unknown clause name can be answered with the registered
  set instead of `not a tuple`.
- **Third parties add clause names without touching boot** — the same move as
  the tagged-literal registry (`data-readers`), one tier down.

**What it costs, and what it does not.** `BeamLisp.Server`'s *OTP* facts stay
where they are (`callback_order`, `return_constructors` for `ok`/`reply`/
`noreply`/`stop`, `start`/`start_link`/`call`/`cast`/`stop`, `bind_init`) — those
are facts about the VM, not about the language, and they are correct in Elixir.
Only the *vocabulary* moves. The codegen must reproduce the current
`compile-defserver` exactly: the `:inv` partition, the grouped ordering, the
default clauses for callbacks a server did not implement, and the
`nest-lets`/`server-body` treatment that binds the return constructors.

**It is gated.** `priv/boot/compiler.bl` cannot be run until the bootstrap
ladder is repaired (PLAN-088). So this is a design to land *with* that repair,
not before it — and the `tick` clause in §4.1 is the visible payoff.

**What can land BEFORE it, and is worth landing.** The boot edit is needed only
for the *name*. A std expander can already accept arbitrary clause names and
lower them to boot-legal ones — that is exactly what `defbeat` does. So the
copy-pasting can stop today:

- `priv/std/server.bl` gains **one** shared expander: clause head → registered
  transform, spliced into a single boot `defserver`.
- `defregistry`, `defbus`, `defsupervisor` and `defbeat` each become a thin
  mapping over it, instead of four hand-copied `defserver` bodies.
- `(tick …)` stays spelled `defbeat` until the rename — a *name* waiting, not a
  parallel implementation — and there is still exactly one `defserver` in the
  language, so nothing is duplicated.

That is the version that pays immediately and shrinks the eventual boot diff to
a rename plus a table move.

### 4.6.1 The three bundles as clauses

**What a clause may contribute.** An extend-clause transform receives the clause
and a context (`{:init-param … :name …}`) and returns up to four things. This is
the whole contract:

```clojure
{:prelude [forms…]   ; spliced at the TOP of init — arming, registration, setup
 :init    {…}        ; a map MERGED into the server's state (an EXPRESSION,
                     ;   so it may read the init param)
 :clauses [forms…]   ; real defserver clauses to append (handle-call/…)
 :meta    [forms…]}  ; non-callback clauses (invariant, …)
```

The merge is the load-bearing part: it is what makes a clause *composable* where
a macro is a fork. An `init` whose body does not end in `(ok …)` is a loud
refusal, because the expander rewrites exactly that position.

**The registry.**

```clojure
;; today                                                    ;; as a clause
(reg/defregistry workers (keys :id))                        (srv/defserver workers
                                                              (registry (keys :id)))
```

It contributes `:init {:entries {} :keys [:id]}` and five clauses: the
`[:register pid attrs]` and `[:unregister pid]` calls, the `[:whereis q]` and
`[:where q]` calls, and the `[:DOWN _ :process pid _]` handler that retracts a
dead pid's entry. **Every verb stays a module function** — `reg/register`,
`reg/unregister`, `reg/whereis`, `reg/where` are plain fns over a pid or a
registered name, and never needed the macro. The clause composes:

```clojure
(srv/defserver workers
  (init [opts] (ok {:firm (:firm opts)}))     ; the server's own slice
  (registry (keys :id)))                       ; the clause's slice
;; → {:firm "acme" :entries {} :keys [:id]}
```

**The bus.**

```clojure
;; today                          ;; as a clause
(bus/defbus events (demand 8))    (srv/defserver events (bus (demand 8)))
```

It contributes `:init {:subs {} :closed? false :waiting [] :demand 8 :max-lag 1024}`
and the seven clauses `defbus` copies today: `[:publish ev]` as both a call
(which blocks under `:block` backpressure) and a cast, `[:subscribe pid]`,
`[:flow-options …]`, `[:demand n pid]`, `[:demand n]`, `[:DOWN …]`, and
`terminate` (which sends `:done` to every subscriber). **`bus/publish` and
`flow/subscribe` stay**, unchanged.

**The supervisor — NOT a clause.**

```clojure
(super/defsupervisor billing
  (strategy :one-for-one)
  (intensity 3 5000)
  (child :acct account 100)
  (child :workers (pool worker 4)))
```

Unchanged, and not deprecated. A supervisor is a different **process type**
(`:supervisor`, not `gen_server`), so it is not a clause of `defserver` — it is
the **second client of the same expander**. And it already *is* a clause-DSL
over a descriptor (`priv/std/super.bl:95-134` emits
`{:__supervisor__ true :strategy … :intensity … :children (list …)}`), which is
independent evidence that §4.6's design is the one the language already wanted.
Its `strategy` / `intensity` / `child` names register in the same registry, so
their validation and their error messages come from the same place.

**Do they still exist as modules? Yes — and that is the point.**

| form | after §4.6 | the module |
|---|---|---|
| `reg/defregistry` | the `(registry …)` clause | **stays**: the four verbs are plain fns, and the macro was only ever a way to write someone else's clauses into your server |
| `bus/defbus` | the `(bus …)` clause | **stays**: `bus/publish`, `flow/subscribe` |
| `super/defsupervisor` | unchanged, un-deprecated | **grows**: `pool-spec` / `pool-dispatcher` are a real server, and the pool is the supervisor's most useful clause |

A bundle is a *namespace of verbs plus a clause* — never a copied body. The
macro spellings are deprecated as of 2026-09-18 (`^:deprecated` in
`priv/std/reg.bl` and `priv/std/bus.bl`, with the successor named in the
docstring), and the deodorant smells that migrate consumers are written and
parked in **FUP-094**, because a smell may only rewrite to a word that
resolves — and the clause does not resolve until `server.bl` lands.

One constraint worth recording now, learned by reading the matcher rather than
assuming: `rewrite` matches **exact arity only** (`priv/std/rewrite.bl:141-145`),
so a migration smell binds a whole sub-form as one variable (`?keys` holding
`(keys :id)`) and guards its shape, rather than splicing a variadic pattern.

### 4.6.2 As built (P4) — a tree declares its periodic work

P4's line was *“cut the daemon's own housekeeping over”*. The cut landed on the
other side of the question: the work became a **declaration**, and the daemon
stopped being the place it was written down.

```
 env.bl
   :schedules [{:id "cache-prune" :daily [4 10] :run "bl.cache/prune-scheduled"}
               {:id "index-refresh" :every [30 :minutes] :run "vm.index/refresh-scheduled"}]
        |
        |  bl.env/normalize          shape checked; a mistake is a VALUE in :errors
        v
   vm.spec/read                   the VM's spec carries what the tree SAID
        |
        |  vm.sched/start-for        at daemon boot AND at VM spawn, idempotently
        v
   (proc/defserver declared       ONE module, `:server (:id start-opts)`
     (sched {:clock tick/wall-ms   — one wheel per project, told apart by its id
             :server (:id start-opts)
             :from (:schedules start-opts)}))
        |
        v
   the store (datoms)  →  bl daemon status · the dashboard · GET /schedules
```

Measured on this tree, first boot after the cut:

```
bl daemon
  schedules     2 declared
  schedule      beam-lisp@574618/cache-prune    active  0 runs  in 49233.0s
  schedule      beam-lisp@574618/index-refresh  active  0 runs  in 1754.2s
```

Six decisions, each from something that broke:

| | |
|---|---|
| **the DATA spelling IS the source spelling** | `:every [30 :minutes]`, `:daily [4 10]`, `:at EPOCH-MS` — the `(sched …)` clause's own words. A file that is read without evaluation cannot hold `(every 30 :minutes …)`, but it can hold the same three words, and both paths meet at ONE `proc.sched/rule` — `parse-entry` emits a call to it |
| **a verb is resolved when it FIRES, not when it is declared** | a project may name a verb it has not written yet, and a file's typo must not cost the tree its tool. The first occurrence fails, `:fails` climbs, `:last-error` holds the reason — loud where a human is looking |
| **`start-opts` is in scope for every clause's init** | `server.bl` gained a documented name for the map a server was started with. A clause is a slice of a server someone else starts; without the start argument there is no way to configure one, and a hard-coded default is the only alternative |
| **one module, many owners** | `:server (:id start-opts)` — the wheel's name comes from the VM, so two projects' `cache-prune` rows do not collide on one key in one store |
| **the tree is told, not inferred** | the wheel runs in the daemon's process, where cwd is the daemon's; the tree travels as `:ctx {:root …}` in the declaration, merged into the occurrence every body is handed. The occurrence IS the argument, so this costs no new channel |
| **a refusal is a FACT** | if arming fails, `vm.sched` writes a `:refused` row per declaration with the reason. `declares nothing` and `declares something that cannot turn` are the same picture to a reader — an absent row — and they are the two things a reader most needs told apart. Measured: `:every [30 :min]` (`:min` is not a unit `proc.tick` knows) armed nothing, said nothing, and showed exactly the empty pane of a tree with no declarations at all |

**What did NOT need a schedule**, and why that is the finding rather than a gap:

- the **stale-port sweep** is already correct lazily — `vm.ports/list-claims`
  sweeps every claim whose owner is gone as it reads it, and takes a claim's
  place on the next command. A schedule would be a second implementation of a
  need that is met, and the second implementation is the one that drifts.
- the **watcher's debounce** is a State Timeout, not a schedule: it is "wake me
  after quiet", and `proc.tick` already models that as a *clause*. It stays
  unimplemented here for a different reason — it lives in Elixir
  (`lib/beam_lisp/reload_watcher.ex`), and a clause cannot be reached from there.
- the **index refresh** turned out to be per-TREE with a node-GLOBAL owner
  (`:vm-index`), so the verb answers a declaration from a *different* tree with
  the mismatch rather than refreshing the wrong index (FUP-103).

**The domain walkthrough.** `examples/hotel/hotel.bl` runs a hotel on the tier —
the night ledger on a table with an heir (the owner is killed mid-walkthrough and
the charges are still there), the front desk as a server with a `tick` clause for
a wake-up call, housekeeping as a declaration with a clock the file OWNS (one
round per move of the clock, and a night audit that goes from 0 runs to 1 by
moving that clock to 03:00), and the pane reading the outcomes out of the store
without asking any process. The front page (`desk.bl`, loom) is designed and
unbuilt — FUP-104 names the verbs it needs and the three API facts that cost runs
to learn, so it is one pass of work rather than a rediscovery.

**A build-environment discovery worth its own line.** `./bl` (the ELF launcher
at the tree root) runs the **drop's** prebuilt image: `priv/std/bl/*` is
committed to `Elixir.BeamLisp.Ns.Bl.*.beam` there, so edits to `bl.env`,
`bl.cache`, `bl.cli` are INVISIBLE under it — while `priv/std/vm/*` is not in
the drop and loads from source, which is why half this work seemed to take
effect and half did not. `./bin/bl` is the checkout's own launcher (`build/`),
AOT-compiling the tree's `.bl` sources; every measurement in this section was
taken with it. See FUP-093 for the general case.


## 5. The `bl ui` pane — prior art, then the design

### 5.1 Prior art worth stealing from

| source | what it gets right |
|---|---|
| **`systemctl list-timers`** | the compact row: `NEXT · LEFT · LAST · PASSED · UNIT · ACTIVATES`. THE shape for a recurrence table |
| **Oban Web** | job states as counts + filters; job detail with attempts/errors; `execute-now`/`retry`/`cancel` buttons; queue-depth chart; periodic table |
| **Broadway / LiveDashboard** | the pipeline *topology graph* + per-stage throughput + lag (Telemetry-fed) |
| **Sidekiq Web** | scheduled / retry / dead sets separated — the states people actually triage |
| **Temporal UI** | a Schedule is a *resource* with `spec` + `state` + `action`; per-run **event history** |
| **k8s CronJob / Nomad** | `schedule`, `concurrencyPolicy`, `startingDeadlineSeconds`, `successfulJobsHistoryLimit` — policy made explicit |
| **Prometheus/Datadog** | the SLO is *lag* and *last success*, not counts: `now − last_run − expected` |

Nobody shows the thing beam-lisp can: **the schedule's transition graph, the
invariant it is proven to hold, and its live vitals — in one row.**

### 5.2 The pane

A field in the model (`vm.inspect/model` gains `:schedules` + `:jobs`), so it
appears in `bl daemon status`, the HTML page, **and** `/model` at once. FUP-086
is the precedent (and `index-pane` is the pattern to copy: read a public ETS row,
never queue behind the work you're reporting on).

```
Schedules
  NAME           SPEC                 NEXT        IN       LAST              RUNS FAILS DRIFT   STATE
  reap-orphans   every 15m (skip)     12:15:00    6m12s    12:00:03  ok         48     0   +0.3s   active
  digest         daily 07:00 Paris    07:00:00    18h04m   yesterday ok        9     0   —       active
  reindex        every 1h (coalesce)  —           —        12:04:11  ok         22     0   —       paused
  bat-late-sweep every 30s (jitter)   12:10:30    28s      12:10:01  ok         97     2   +1.9s   drifting
                └ □(period ≥ 30s) z3-proven · graph: init→armed→fire→armed→… · verify ✓
  vacuum         cron 0 3 * * *       —           —        03:00:11  failed×3  11     3   —       paused
                └ governor: 3 consecutive failures → paused (last: "permission denied /var/tmp")

Jobs
  STATE        Q      COUNT  OLDEST    ATTEMPTS  NEXT
  scheduled    ingest     12  00:03:22  —         12:20:00
  available    ingest      3  00:00:04  —         now
  executing    ingest      2  00:11:03  1/5       ← lease 5m OVERDUE  [reclaim]
  retryable    ingest      1  00:00:30  2/5       in 01:30
  discarded    embed       4  —         5/5       [retry]
  completed    —        1421  —         —         prune < 7d

Ticker  pid <0.612.0>  status waiting  mailbox 0  memory 48 KB  reductions 1.2M
        last tick 28s ago  □(interval ≥ 30s)  next wake in 2s
```

Affordances (token-gated POSTs, exactly the `/intent` shape):
`/schedules/<id>/{pause,resume,run-now}` · `/jobs/<id>/{retry,cancel}` ·
`/jobs/{reclaim-orphans}`.

The **deep** row (unique to beam-lisp): click a schedule → its
`system.model/graph` drawn, its invariant + `system/verify` result,
`sched/explain`'s narration (*why* the next run is 07:00 Paris), and its **event
history** — the datoms that moved its state — which is just `datom/q history`.
That's Temporal's event history, for free, because the state was facts all along.

**First tenant, so the pane is never empty: the daemon's own four hand-rolled
schedulers, cut over.** Plus `bl cache prune`, which is a periodic job run by
hand today.

**Pane scope (SETTLED): a session-wide registry, like `ports/list-claims`** —
any app registers a schedule; the pane shows every claim, whoever made it. The
stale-entry cleanup is itself a schedule, which is a pleasing bootstrap.

### 5.2.1 As built (P3) — the schedules half

Landed: `vm.inspect/model` gains `:schedules`, so the field appears in
`bl daemon status` (the terminal face), the HTML page, `GET /model`, and a new
`GET /schedules` at once. The op path is
`POST /schedules/<server>/<id>/<op>` for `pause` · `resume` · `run-now`, behind
the same `x-bl-token` guard `/intent` uses.

```
Schedules            (the model's field — every face renders THIS)
  kitchen/prep    active · 7 runs · in 40s                  [resume][pause][run now]
  kitchen/open    active · 1 run · — a one-shot with nothing left to run
  audits/rebuild  paused · 3 runs · 2 failed · 12s overdue  (no scheduler running)
```

Four decisions the sketch did not have, each from something that broke:

| | |
|---|---|
| **`<server>` is in the path** | a schedule's identity is `(server, id)`, not `id`: two servers may declare the same id, and the store already keys on the pair. The sketch's `/schedules/<id>/…` would have addressed an ambiguous name |
| **503, not 404, when nothing is listening** | the request was well formed and understood; the WORLD could not satisfy it. A page that cannot tell those apart sends its reader looking in the wrong place |
| **the row is written at BOOT** | not on the first fire. A pane that showed only what has RUN hides exactly the schedule an operator came for — the one that has never fired |
| **the scheduler announces its own name** | `:bl-sched/<server>`, derived from the declaration, registered by the scheduler's own init (the `vm.exec` idiom). A pane has only the store, so the name must be a FUNCTION of the declaration. A collision is refused with a message naming the holder, because two schedulers for one declaration are two writers of one fact — measured: that refusal is what caught a leaked scheduler in an example |

**The read path cannot write, and that is proven rather than intended.**
`proc/schedules` is built from `datom/db` — a basis — so it never touches the
writer. `test/bl/vm/schedules_test.bl` renders 50 times and requires the store's
basis not to move; with the scheduler left running the number it catches is the
TICKER's, not the pane's, which is why the test stops it first. See FUP-101.

**Honest limit of "the two faces agree".** Each face builds the model when
asked, so with a ticker firing between two reads the numbers genuinely differ —
what the covenant promises is that both faces describe ONE shape and agree about
a state, not that two reads a millisecond apart are simultaneous. The example's
first version of this comparison failed on exactly that, which is the useful
form of the caveat.

Still open in the pane: `:jobs` (awaiting `defqueue`), the deep row
(graph · invariant · `verify` · event history — `datom/q history` on the
schedule's own entity), the ticker line, and the daemon's four hand-rolled
schedulers as first tenants (P4).

---

## 6. Challenges — where this could be locally coherent and systemically wrong

1. **⚠ The host's one dirty-IO scheduler.** The AGENTS.md host notes: `+SDio 1`,
   and `file:call/2` ops queue behind *every* other dirty-IO op in the VM with no
   timeout. A scheduler that reads the store on every tick will (a) stall when
   the daemon does file I/O and (b) *become the thing that stalls everyone else*.
   **Consequence: the hot wheel must be an ETS `ordered_set` (a public row, the
   `vm.exec`/`vm.index` shape); the store is the durable *declaration and
   outcome*, written on claim/finish, not on wake.** Also: never render the pane
   with per-row store reads (the `gateway/live` lesson in `vm.inspect`).
2. **Drift vs lateness vs validity.** `send_after` drifts; the wall clock jumps;
   a VM can be suspended. Naive "every 15m" silently becomes "every 15m+ε". And a
   tick can fire *late* (zram, a busy dirty-IO queue). So: durations from
   `monotonic_time`, deadlines from wall clock, boundary-aligned re-arm, and on
   wake **re-check "is it actually due?"** rather than trusting the timer.
   `catch-up` must then be an explicit policy, not an accident.
3. **The clock must be a value, not `now`.** blueprint passes `now-fn`;
   knowledger's `now-day` is a coarse `yyyymmdd`. If the scheduler reads the wall
   clock internally, you can't test a week in a second, can't time-travel the
   pane, and break the `effects` lattice (reading the clock is `io` — tempo §9
   says so explicitly). **Pass the clock in. (SETTLED: injected everywhere; the
   daemon passes wall time.)**
4. **Recurrence arithmetic is a library, not a decision.** "every 15 min anchored
   where", DST, month-ends, "last Friday", "every Friday the 13th".
   `datom.time` has intervals + Allen + `expand`, but **no RRULE** (no
   `recur-rule` in `priv/lib`). v1 should be: fixed periods + daily-at + a
   cron-string *parser*, with the rule lowered to a **lazy seq of intervals**
   (`(take-while (before? …) (rule))`) — already tempo §8's shape, needing only a
   few constructors. Explicitly refuse "last Friday of the month" until
   recurrence lands.
5. **Distributed scheduling is not designed for, and shouldn't be yet.** No
   `:pg`/`global` in-tree. But note the *nice* consequence: **one store, one
   writer = the scheduler leader is the store's owner.** That's cleaner than
   Oban's advisory locks, and worth *not* spoiling with a premature cluster
   story.
6. **The temptation to build a second Oban.** Plugins, pruners, lifelines, a
   plugin API, telemetry, its own dashboard. Every one of those already has a
   home: restart (`defsupervisor`), lookup (`reg`), notify (`datom/watch`), proof
   (`system/verify`), pane (`vm.inspect`). Budget it: **~200 lines + two
   bundles**, and a review question that says *name the pattern or don't merge
   it*.
7. **`(tick …)` must not grow a second name for one graph.** The pattern is
   Heartbeat; `(tick …)` is its bundle. If the compiler desugars it to
   `handle-info`, `system.model` sees exactly the graph it already reasons about,
   and `verify-liveness` already covers it.
8. **The pane must never be a second truth.** Two ways it can lie: reading a
   *process's* in-memory next-run (disagrees with the declaration after restart),
   or computing per-row store/dir scans (the `gateway/url` round-trip bug already
   documented in `vm.inspect`). Rule: **one value, computed once per request,
   from the same facts the scheduler reads.**

---

## 7. What gets prototyped, in this order

```
P1  priv/std/tick.bl + examples/tooling/tick.bl                    ← DONE — 34 assertions green
      `bl -p priv/std test --shared test/bl/tick_test.bl`  (see FUP-093: the
      ward path cannot yet use the tree's own std, for reasons unrelated to it)
      intervals, wall anchors, jitter, injected clocks, one-shot + debounce,
      cancel, on-error :continue — all covered
P1.5 priv/std/server.bl — the expander: defserver + an OPEN clause vocabulary  ← DONE
      `(tick …)` is a real clause, `defbeat` is deleted, a clause MERGES its
      slice into the server's state, and an unknown clause names the whole
      accepted set instead of `not a tuple`
      next clients: `(registry (keys …))`, `(bus (demand 8))` — reg.bl/bus.bl
      are `^:deprecated` and FUP-094/095/096 carry the migration
P2  priv/std/proc/sched.bl — the `(sched …)` clause over the in-process wheel ← DONE
      `bl -p priv/std test --shared test/bl/sched_test.bl` — 18 tests, 56 assertions
      rules (every/daily/at) · catch-up (:skip/:coalesce/:run-all, arithmetic)
      · the idempotency key · pause/resume · run-now · spec/next · an injected clock
      NOT yet: the declaration as a FACT in the store (P2b). `runs`/`fails`/
      `last-run` live in the process and reset on restart, and say so.
P2b priv/std/proc/sched.bl — the durable half                                    ← DONE
      ONE public ETS table, ONE long-lived owner (proc.sched/store-keeper).
      The DECLARATION is durable by construction (it is a literal); the OUTCOME
      — what ran, what failed, the human's pause — is resumed from the store.
      acceptance MET: `a-restart-resumes-it-does-not-repeat` (a one-shot that
      ran does NOT run again across a restart) and `a-pause-survives-a-restart`
      (paused is a fact, not a bit in the process that made it).
      The same table is the pane's read model — `proc/read-all`.
P2c priv/std/proc/sched.bl + priv/lib/datom/store-ets.bl — datom over ETS   ← NEXT
      the declaration and the outcome as `:schedule/*` facts, so the pane
      queries them like everything else and `history`/`as-of` come free
      DEPENDENCY: `datom/store-ets` has NO heir (grep: zero hits), so a conn's
      table dies with the process that opened it, and `store-ets/open` makes an
      UNNAMED table so the handle cannot be re-derived — it must be published.
      (a) heir in store-ets (b) publish the conn (c) swap the four functions.
      The 22 sched assertions are written against BEHAVIOUR, so green = proven.
P3  ✅ vm.inspect :schedules → the terminal + HTML + JSON faces, GET /schedules,
     and POST /schedules/<server>/<id>/{pause,resume,run-now}; a declared-but-
     never-run schedule appears (the row is written at boot), and the read path
     is proven not to write (FUP-101)
      reads the store, so the pane never asks a ticker anything
      acceptance: `bl daemon status` and the page render the SAME numbers
P4  ✅ CUTOVER: the tree's periodic work is a DECLARATION (env.bl `:schedules`)
     — `bl cache prune` as a scheduled verb, the index refresh, armed at daemon
     boot and at VM spawn, visible in the pane, and a refusal that cannot arm is
     itself a visible row. Findings: the stale-port sweep needs no schedule (the
     read IS the sweep); the watcher's debounce is a State Timeout (a `tick`
     clause) and lives in Elixir
      the watch-debounce (reload_watcher.ex) onto P1/P2; the pane is now non-empty
        ── then, separately ──
P5  priv/std/jobs.bl — defqueue; knowledger cut over from its hand-rolled runner
P6  flow/distribute + batch + defpipeline  (the Broadway half)
```

P1→P4 is the honest wave: **substrate → observable → cutover** (prove, then cut,
per the repo's ethics). P5/P6 are separate waves with a real consumer each.

---

## 8. Decisions settled with the user (2026-09-18)

| # | question | decision |
|---|---|---|
| 1 | Is a schedule a **fact** or a **process**? | **Fact-first.** `defscheduler` over a datom relation for anything declared/monitored; the `(tick …)` clause for private per-process beats (debounce, polling, prune). Both lower to the same Timeout Edge. |
| 2 | What is the first wave's deliverable? | **Substrate + pane + cut the daemon's own housekeeping over (P1–P4).** The daemon already hand-rolls four schedulers (two languages, three shapes); the pane is non-empty on day one and the pattern is proven against a real tenant. |
| 3 | Should the clock be injected? | **Injected everywhere** (a fn → seconds); the daemon passes wall time. Without it you cannot test a week in a second, cannot time-travel the pane, and "this scheduler secretly reads now" becomes an invisible smell. |
| 4 | Where are schedules **declared**? | **Both.** `env.bl :schedules` for the tree's; `defscheduler` for a namespace's; the pane unions them. `:tasks` (a verb the daemon runs) and `:ports` (a claim the session hosts) are the precedent. |
| 5 | What does the pane **monitor**? | **A session-wide registry**, like `ports/list-claims` — any app registers a schedule, and `bl ui` is the one place to see all recurrent work. The stale-entry cleanup is itself a schedule. |

---

## Sources

- `docs/the-process-pattern-language.md` — §1.5 Timeout Edge, §4.1 Heartbeat,
  §4.2 Snapshot, §4.3 Invariant Gate, §5 the surface, §6 the build ledger
- `docs/the-five-bundles.md` — the bundle discipline (one paragraph, one test, one build step)
- `docs/the-maximalist-supervisor.md` — supervision, the healing edge, the governor
- `docs/the-environment-and-process-conveyance.md` — conveyed state and init args
- `docs/tempo-maximalist.md` — §8 recurrence as a lazy seq and the live surface, §9 the verification tier
- `docs/datom-as-a-broadcast-substrate.md` — §8 the public surface (`listen!`/`watch`), §8.1 the projector
- `docs/bl/06-the-warm-daemon.md`, `docs/dev/the-warm-session.bl.md` — the session and its faces
- `docs/dev/env.bl.md` — the project file and its keys
- `!tasks/follow-ups/FUP-086-…org` — a pane is a field in `vm.inspect`
- `!tasks/plans/PLAN-088-…org` — why `priv/boot/` cannot be edited yet
- `~/code/ora/blueprint/src/printflow/{clock,notify,outbox}.bl`
- `~/code/products/knowledger/apps/knowledger/src/knowledger/library.bl`
