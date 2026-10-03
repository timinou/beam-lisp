# 05 — Observability: the system is the dataset

Events are datoms in the *same* store as the deploys they belong to, so a
dashboard is a live query that re-runs on every commit, an alert's firing is
itself a fact, and "did latency regress after the deploy?" is one datalog join
rather than two dashboards and a hope.

## The claim

From `docs/design/vps/observability.md`, three sections at once:

- **§Events are datoms.** A service reports by transacting a fact — no
  serialization into a metrics format, no second database. The event lives in
  the store that also holds desired state, effect history, and audit, so every
  question can join across all of them.
- **§Dashboards are live queries.** A dashboard is a datalog query that re-runs
  when relevant datoms land. There is no refresh interval because there is no
  polling: the page is a subscription.
- **§Alerts are schedules whose history is data.** The condition is a query; the
  firing is a transacted datom; the notification is an effect. Because the
  firing is a fact, alert fatigue becomes debuggable by query like everything
  else.

The spike proves the load-bearing half of those three claims on a real datom
store: events *are* datoms, a query *does* re-run live on commit, and the
deploy boundary *does* join to the event stream in one query. "Did latency
change after the deploy?" is the query the spike runs.

## The idea

On a conventional stack, observability is a copy. The service emits text, an
agent scrapes it, a time-series database stores it, a dashboard renders it, and
the deploy is recorded somewhere *else* — a CI log, an events table, a Slack
message. Nothing knows about anything. "Did the deploy cause the latency spike?"
is a question you answer by eyeballing two panes and inferring.

Here the system keeps its own facts. A request event is a datom. A deploy is a
datom. They share a store, so they share a clock and a query language:

```
event is a datom  →  dashboard = query over datoms  →  re-runs on every tx
deploy is a datom →  "latency since the deploy" = ONE join, not an inference
alert is a query  →  its firing = a datom  →  the alert's own history is queryable
```

∴ the observer is inside the observed: the tool you *detect* with is the tool you
*investigate* with, in the same address space. No switch from dashboard → logs →
ssh, each re-establishing context the last already had.

This spike makes that concrete in miniature, then asserts it.

## Walkthrough

The spike is one file, read top to bottom. Each stage prints, and the last line
is `PASS`/`FAIL`.

### Step 1 — one schema for events, deploys, and alerts

```clojure
(def conn
  (datom/connect
    [{:db/ident :ev/svc :db/valueType :db.type/string}
     {:db/ident :ev/lat :db/valueType :db.type/long}
     {:db/ident :ev/at  :db/valueType :db.type/long}
     {:db/ident :deploy/svc :db/valueType :db.type/string}
     {:db/ident :deploy/src :db/valueType :db.type/string}
     {:db/ident :deploy/at  :db/valueType :db.type/long}
     {:db/ident :alert/id :db/valueType :db.type/keyword}
     {:db/ident :alert/value :db/valueType :db.type/long}
     {:db/ident :alert/at :db/valueType :db.type/long}]))
```

Everything the spike cares about lives in **one connection**: request events
(`:ev/*`), deploys (`:deploy/*`), and alerts (`:alert/*`). This is the whole
inversion in nine lines. A conventional stack would need three systems for these
three kinds of fact; here they are three attributes in one schema, and any query
can span them. The attributes use a `:db.type/long` for times and latencies so
the query engine's predicates (`<`, `>=`) work directly on them.

### Step 2 — the dashboard is a live query

```clojure
(def dashboard-updates (atom 0))
(def wr (datom/watch conn '[:find ?lat :where [?e :ev/lat ?lat]]
                     (fn [_diff] (swap! dashboard-updates inc))))
```

This is the real organ: `datom/watch` is the L3 *filtered live query*. It
registers a datalog interest — here a trivially small one, `[?e :ev/lat ?lat]`
— and fires the callback whenever a commit on `conn` affects that interest. It
runs in its own process, so a slow callback is back-pressured rather than
stalling the writer, and the callback receives the *diff* (`{:added :removed}`),
not a projection the writer pre-computed.

The spike's callback throws the diff away (`_diff`) and just bumps an atom. That
atom is the spike's stand-in for a rendered dashboard: if the counter moves, the
"page" re-ran. The claim being tested is that no polling is involved — the query
re-runs because a commit landed, not because a timer fired.

### Step 3 — the deploy, then the event stream

```clojure
(datom/transact! conn [{:db/id -1 :deploy/svc "web" :deploy/src "v2" :deploy/at 1000}])
(datom/transact! conn [{:db/id -1 :ev/svc "web" :ev/lat 40 :ev/at 900}    ; before
                        {:db/id -2 :ev/svc "web" :ev/lat 44 :ev/at 950}])  ; before
(Process/sleep 40)
(datom/transact! conn [{:db/id -1 :ev/svc "web" :ev/lat 220 :ev/at 1100}  ; after: slow!
                        {:db/id -2 :ev/svc "web" :ev/lat 240 :ev/at 1200}])
(Process/sleep 40)
```

Four commits build the world: a deploy of `web` at logical time `1000`, two
healthy request events before it (`900`, `950` → 40 ms, 44 ms), and two slow
events after it (`1100`, `1200` → 220 ms, 240 ms). The `:ev/at` timestamps are
explicit data, not wall-clock, so the "deploy boundary" is a value the query can
compare against — this is what makes the join in Step 4 possible without any
correlation magic.

Note the deploy transact touches `:deploy/*`, **not** `:ev/lat`, so the watch
from Step 2 does not fire for it. Only the two event batches affect the
interest, so the dashboard counter should reach at least 2. The `Process/sleep
40` pauses give the watch's own process time to run its callback before the
assertions at the end — a small, honest accommodation for the fact that `watch`
is asynchronous, not a synchronous hook.

### Step 4 — the join: latency across the deploy boundary

```clojure
(def db (datom/db conn))
(def deploy-at (first (first (datom/q '[:find ?t :where [?d :deploy/svc "web"][?d :deploy/at ?t]] db))))
(def before (datom/q '[:find ?lat :in $ ?dt :where [?e :ev/lat ?lat][?e :ev/at ?t][(< ?t ?dt)]] db deploy-at))
(def after  (datom/q '[:find ?lat :in $ ?dt :where [?e :ev/lat ?lat][?e :ev/at ?t][(>= ?t ?dt)]] db deploy-at))
(defn maxv [rows] (reduce max 0 (map first rows)))
```

This is the point of the whole spike. `(datom/db conn)` takes a database
**value** — an immutable, O(1) snapshot. `deploy-at` pulls the deploy time
(`1000`) out of the store with one query. Then `before` and `after` are the
same query shape with one predicate flipped:

- `[(< ?t ?dt)]` — every `:ev/lat` whose `:ev/at` is **before** the deploy
  boundary,
- `[(>= ?t ?dt)]` — every `:ev/lat` **at or after** it.

Each query binds `?dt` through `:in $ ?dt` with the input argument `deploy-at`.
That is datalog *parameters*, not string interpolation — the boundary is a
value in the query, not baked text. `maxv` folds each result set to its largest
latency. The spike calls this "the join no conventional stack can do" because
the deploy and the events are different attributes in the same store; on a
conventional stack they live in systems with no shared key.

### Step 5 — an alert is a query, and its firing is a fact

```clojure
(def threshold 200)
(def breach (maxv after))
(when (> breach threshold)
  (datom/transact! conn [{:db/id -1 :alert/id :p95 :alert/value breach :alert/at 1300}]))
(def alerts (datom/q '[:find ?id ?v :where [?a :alert/id ?id][?a :alert/value ?v]] db))
;; re-read after the alert transact (db value is immutable, take a fresh one)
(def alerts2 (datom/q '[:find ?id ?v :where [?a :alert/id ?id][?a :alert/value ?v]] (datom/db conn)))
```

The alert is not a log line or a Slack message: it is a `datom/transact!`. The
post-deploy max (`240`) breaches the threshold (`200`), so the alert **firing**
is recorded as a fact — `{:alert/id :p95 :alert/value 240 :alert/at 1300}` —
with a keyword id and the offending value. That fact is now queryable exactly
like a request event, which is what makes alert fatigue debuggable: how often
did `:p95` fire, at what values, and what did we do each time?

The two queries over `alerts`/`alerts2` are a deliberate lesson in the datom
model, and the comment says so. `db` was captured back in Step 4, *before* the
alert was transacted; `(datom/db conn)` is a **new** value taken after. Because
a database value is immutable, `alerts` (on the old value) sees **no** alert and
`alerts2` (on the fresh value) sees **one**. Nothing was mutated under you; the
past value simply never learned about the new fact. This is the same property
that makes time-travel free — and the reason a live query must read the *current*
value, not a captured one.

### Step 6 — assertions

```clojure
(def ok (and (>= (deref dashboard-updates) 2)     ; dashboard re-ran live
             (<= (maxv before) 100)               ; healthy before
             (>= (maxv after) 200)                ; regressed after
             (= 1 (count alerts2))                ; alert fired
             (= :p95 (first (first alerts2)))))   ; and it is a queryable fact
```

Five conjuncts, one per claim:

1. the dashboard counter moved at least twice → the live subscription really
   fired on commit;
2. max-before ≤ 100 → the pre-deploy baseline is healthy;
3. max-after ≥ 200 → the boundary join shows the regression;
4. exactly one alert exists → the firing was recorded;
5. its id is `:p95` → the firing is a *queryable fact*, not a side effect.

`datom/unwatch` releases the subscription just before this. The final line is
the verdict.

## What's real vs modelled

The honest boundary, organ by organ, claim by claim.

**Real — exercised as-is:**

- `datom/connect` — a real datom connection over a real in-memory store, with
  the schema genuinely installed before any data. Events, deploys, and alerts
  are *actual datoms* in *one* store — this is the entire claim, and it is not
  simulated.
- `datom/transact!` — real, atomic commits. The deploy, the event batches, and
  the alert firing are all ordinary transactions.
- `datom/db` — the real immutable, O(1) database value. The stale-`alerts` /
  fresh-`alerts2` distinction in Step 5 is a *true* consequence of the datom
  model, not a contrivance.
- `datom/q` — the real datalog engine, with real `:in` parameter binding and
  real predicate clauses (`<`, `>=`). The latency↔deploy join is a genuine join
  in one store.
- `datom/watch` / `datom/unwatch` — **the real L3 filtered live query.** The
  callback runs in its own process and fires on commits affecting the declared
  interest. The whole "dashboard re-runs live, without polling" claim rests on
  this real organ; the spike only shrinks the *interest* (one attribute) and the
  *callback* (a counter).

**Modelled / simplified for the probe:**

- **The "dashboard" is a counter, not a page.** `dashboard-updates` is an atom
  incremented by the watch callback. The design doc's real dashboard is a
  `live/web` page whose query re-runs; here the *mechanism* (watch → re-run) is
  real, but there is no rendering, no diff application, and no push to a client.
  The spike discards the diff (`_diff`) a real dashboard would use to update
  rows incrementally.
- **"p95" is a max.** The alert is labelled `:alert/id :p95`, but `maxv` is
  `(reduce max 0 …)` — the *maximum* latency, not the 95th percentile. It is a
  stand-in for "a latency statistic breached a threshold". The datalog engine
  can compute real percentiles/aggregates; the spike chose the cheapest
  monotone function that makes the assertion crisp.
- **No real service, no real request stream.** The events are hand-written
  datoms with made-up `:ev/at` values (`900`, `950`, `1100`, `1200`) and
  explicit latencies. There is no load generator, no request handler, no
  wall-clock coupling. The store sees exactly what the script transacts.
- **The deploy is a hand-written datom.** `:deploy/src "v2"` is asserted
  directly; no deploy organ ran. The join is real, but the "deploy" it joins to
  is data the script wrote.
- **The alert is fired by an inline `when`, not a schedule.** The design doc
  shows `proc.server/defserver alerting (sched (every 1 :minutes :p95 check-p95!))`.
  The spike's `(when (> breach threshold) …)` is the *condition-as-query* part
  modelled inline; the periodic scheduling, the server wrapper, and the
  notification **effect** are not present. What *is* proven is the load-bearing
  half of the alert claim: the firing is a datom, and therefore queryable.
- **The boundary join is a scalar, not a generation.** The doc's example joins
  events against a *generation* entity (`[?g :node/generation "a1b2c3"]
  [?g :live-from ?t0]`) to scope latency to "while this generation was live".
  The spike simplifies the right-hand side to a single `:deploy/at` scalar and
  compares timestamps against it. The shape is the same (events join to deploy
  metadata in one query); the fancier generation-liveness join is not exercised.
- **The join is scoped by attribute and time, not by service.** `before`/`after`
  select `:ev/lat` by timestamp only — there is no `[?e :ev/svc "web"]` clause.
  With a single service in the store this is equivalent; the *general* join over
  a multi-service stream would need that extra clause. (See Exercise 3.)

## Run it

```sh
./blx run research/vps_spike/05_observability.bl
```

Cold start costs ~10-15 s (JIT warmup); that is boot, not work. Expected output:

```
── latency across the deploy boundary (t= 1000 ) ──
  before deploy, max lat: 44
  after  deploy, max lat: 240
── alert (fired = a fact) ──
  p95 fired @ 240

PASS 05_observability  (events join deploys; alerts are facts)
```

The final line is the assertion verdict. `before` max is `44` (the `950` event),
`after` max is `240` (the `1200` event), and the single `:p95` alert carries the
breaching value `240`.

## Exercises

All four change only the spike file; re-run after each and predict the verdict
before you look.

1. **Silence the alert by raising the bar.** Change `(def threshold 200)` to
   `250`. Predict the output and the verdict. → The post-deploy max is `240`,
   which no longer breaches, so the `when` does not transact — `alerts2` is
   empty and conjunction 4 (`(= 1 (count alerts2))`) fails. `FAIL`. The lesson:
   the alert's *existence* is conditional on its condition, and the assertion
   couples detection to the fact it produced.

2. **Break the live dashboard.** Replace `(datom/watch …)` with a binding that
   never fires, e.g. comment the `(def wr …)` form out. Predict the verdict. →
   `dashboard-updates` stays `0`, so conjunction 1 (`>= … 2`) fails. `FAIL`. The
   lesson: the "dashboard re-ran live" claim is genuinely load-bearing — it is
   asserted, not decorative.

3. **Pollute the join with another service.** Add a slow event for a different
   service to the second batch:
   `{:db/id -3 :ev/svc "api" :ev/lat 500 :ev/at 1150}`. Predict `after` max and
   the verdict. → `after` max becomes `500`, because `before`/`after` select
   `:ev/lat` by timestamp alone and never filter on `:ev/svc`. The verdict still
   `PASS` (500 ≥ 200 and the alert still fires), but the number is now wrong for
   "web". Fix it by adding `[?e :ev/svc "web"]` to both queries — the lesson:
   scoping a live query is the query author's job, and the store does not guess.

4. **Watch a value go stale.** Add `(println "alerts on old db:" (count alerts))`
   next to the `alerts2` print. Predict both counts. → `alerts` is `0` and
   `alerts2` is `1`. The old database value was captured before the alert
   transact and is immutable, so it never sees the new fact — while the fresh
   `(datom/db conn)` does. The lesson is the price of giving out free, forever-
   consistent snapshots: a live query must read the *current* value, and a
   captured one is a photograph, not a window.
