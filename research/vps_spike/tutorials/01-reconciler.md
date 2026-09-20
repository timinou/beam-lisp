# 01 — The reconciler

The entire control plane is one pure function `(desired, observed) → effects`,
and every effect it emits is transacted back as a queryable fact — so *"why did
that happen?"* is a datalog question, not a log hunt.

## The claim

From `docs/design/vps/the-reconciler.md` — the section **"The loop"** and the
section **"Why the delta is a pure function"**: desired state and observed state
are two values, the delta between them is a third value produced by a function
that touches nothing, and the effects of applying that delta are recorded as
datoms. The doc's sketch is:

```
desired  := datalog over :service/desired           ; what you asked for
observed := vm.ports claims + process table + envs  ; what is
delta    := reconcile/diff desired observed         ; a pure function
effect   := spawn / drain / reload / re-route       ; capped, logged
```

This spike proves the first three lines and the *"Effects are facts"* habit on
the **real datom** — no runtime moving parts, no simulated machine.

## The idea

Conventional config management asks a machine *"are you in the right state?"* by
running a script, and the script's answer lives only in its stdout. That is
untestable (you need a machine to try it), unexplainable (the plan is not a
value you can print beforehand), and unauditable (the record of what happened is
free text).

The reconciler inverts this. It separates the **decision** from the **action**:

- `desired` is data — a set of services someone asked for.
- `observed` is a *sample* of the living node — read live, never stored, so there
  is exactly one stored truth.
- `diff` is a pure value→value function: `(desired, observed) → [effect …]`.
  It has no side effects, so you can unit-test it over maps instead of
  integration-test it over a machine, print it, and (in the full design) even hand
  it to z3 before running it.
- Every applied effect is *transacted back*, so the history of what the machine
  did is the same kind of data as the intent of what it should do.

Why this matters for devops: → because the delta is data, "what will change?" is
a value you show a human before changing anything ∴ the dangerous moment (acting)
is preceded by a readable, refusable one. And → because effects are facts,
"why did web reload at 03:12?" is a query, not an archaeology session. ✓ The two
habits together are the whole trick.

## Walkthrough

### Step 1 — Desired state has a schema, and ids are identity

The spike opens against the real `datom` library and declares the attributes its
data uses:

```clojure
(ns vps.reconciler (:require [datom]))

(def schema
  [{:db/ident :service/id    :db/valueType :db.type/string :db/unique :db.unique/identity}
   {:db/ident :service/src   :db/valueType :db.type/string}
   {:db/ident :service/hosts :db/valueType :db.type/string :db/cardinality :db.cardinality/many}
   {:db/ident :effect/kind   :db/valueType :db.type/keyword}
   {:db/ident :effect/svc    :db/valueType :db.type/string}
   {:db/ident :effect/why    :db/valueType :db.type/string}
   {:db/ident :effect/at     :db/valueType :db.type/long}])
```

Two things are load-bearing here. `:service/id` is `:db.unique/identity`, which
means *upsert*: transacting the same id twice folds onto the same entity instead
of forking a duplicate. And `:service/hosts` is `:db.cardinality/many`, so one
service can own several hostnames. Desired state is ordinary datom data — no
bespoke config format, which is the tutorial README's "one address space" in
miniature.

### Step 2 — `desired` is a query, not a file

```clojure
(defn desired-services [db]
  ;; the desired set, keyed by id → {:id :src}
  (into {}
    (map (fn [[id src]] [id {:id id :src src}])
         (datom/q '[:find ?id ?src
                    :where [?e :service/id ?id] [?e :service/src ?src]] db))))
```

The desired set is not stored *beside* the database; it is *read out of* the
database by a real datalog query. `datom/q` runs against the connection's
database value and returns a set of `[?id ?src]` tuples, which are folded into a
plain `id → {:id :src}` map. The doc says "desired := datalog over
:service/desired"; here the query is over `:service/id`/`:service/src` directly,
but it is the same move: the shape the brain consumes is derived by query.

### Step 3 — `diff` is the whole brain

This is the entire decision-making surface of the machine, and it is one pure
function of two maps:

```clojure
(defn diff
  "desired, observed : id → {:id :src}.  Returns effects, ordered."
  [desired observed]
  (let [ids (distinct (concat (keys desired) (keys observed)))]
    (vec (keep
           (fn [id]
             (let [d (get desired id) o (get observed id)]
               (cond
                 (and d (not o)) {:kind :spawn  :svc id :why "in desired, not observed"}
                 (and o (not d)) {:kind :drain  :svc id :why "in observed, not desired"}
                 (not= (:src d) (:src o))
                                 {:kind :reload :svc id
                                  :why (str (:src o) " → " (:src d))}
                 :else nil)))
           ids))))
```

Walk the `cond` top to bottom, because the order carries the logic:

- The id set is the *union* of desired and observed — an id only in one of them
  is exactly where an action is needed.
- `d ∧ ¬o` → **spawn**: it was asked for and is not running.
- `¬d ∧ o` → **drain**: it is running and no longer asked for.
- Both present but sources differ → **reload**: same service, new code.
- Otherwise → `nil`, and `keep` drops it. No effect, no noise.

The guard ordering is not cosmetic. When `d` is `nil`, `(:src d)` is `nil`; a
naively-first `reload` clause would fire on the spawn/drain rows. Putting the
existence checks first makes reload reachable *only* when both sides exist — so
matching services (like `web` below) correctly produce nothing.

`diff` reads no clock, touches no connection, and mutates nothing. That is the
purity the doc's three arguments (testable · explainable · provable) rest on.

### Step 4 — Effects become facts

```clojure
(defn record-effects! [conn effects]
  (datom/transact! conn
    (vec (map-indexed
           (fn [i e] {:db/id (- (- i) 1)
                      :effect/kind (:kind e) :effect/svc (:svc e)
                      :effect/why (:why e)  :effect/at (erlang/system_time :millisecond)})
           effects))))
```

Each effect is written back through `datom/transact!` as an entity carrying what
it was (`:effect/kind`), whom it touched (`:effect/svc`), why (`:effect/why`),
and when (`:effect/at`, a real Erlang millisecond clock). `(- (- i) 1)` produces
a distinct singleton tempid (`-1`, `-2`, …) per effect, so the records do not
collide. This is the doc's *"Every applied effect is transacted"* — history in
the same store as intent, so the two can be joined.

### Step 5 — The run: transact desired, sample observed

```clojure
(def conn (datom/connect schema))

;; operator transacts desired state: two services
(datom/transact! conn [{:db/id -1 :service/id "web" :service/src "v1" :service/hosts ["web.test"]}
                       {:db/id -2 :service/id "api" :service/src "v1"}])

;; observed = what is actually running (sampled, never stored)
(def observed {"web" {:id "web" :src "v1"}          ; matches
               "old" {:id "old" :src "v1"}})         ; drifted: running, undesired
```

`datom/connect` opens a fresh in-memory store over the schema. The operator then
transacts the *desired* world: `web` (with a hostname) and `api`, both at source
`v1`. The *observed* world is a literal map standing in for a live sample — and
it is deliberately out of step: `web` matches, but `old` is running and nobody
asked for it. That mismatch is the entire reason a reconcile is interesting.

### Step 6 — Compute and print the delta

```clojure
(def effects (diff (desired-services (datom/db conn)) observed))
(println "── delta ──")
(doseq [e effects] (println (str "  " (name (:kind e)) " " (:svc e) "  (" (:why e) ")")))
```

Note `(datom/db conn)`: the desired state is pulled out of the connection as an
immutable database value, then fed to `diff` alongside the sampled map. Both
inputs to the brain are plain values. The two effects printed are:

```
── delta ──
  spawn api  (in desired, not observed)
  drain old  (in observed, not desired)
```

(`web` is absent from the delta — its `src` matches.) The *set* of effects is
deterministic; the print order follows map iteration and is not part of the
contract.

### Step 7 — The audit is a datalog query

```clojure
(def why
  (datom/q '[:find ?svc ?kind ?why
             :where [?e :effect/svc ?svc] [?e :effect/kind ?kind] [?e :effect/why ?why]]
           (datom/db conn)))
```

Having recorded the effects, "why did anything happen?" is asked the same way
desired state was read — a query. This one returns two rows, one per effect.
There is no separate audit log to ship and parse; the audit *is* the effect
history, in the store.

### Step 8 — The assertions

```clojure
(def kinds (set (map :kind effects)))
(def ok (and (contains? kinds :spawn)     ; api: in desired, not observed
             (contains? kinds :drain)     ; old: observed, not desired
             (not (contains? kinds :reload)) ; web matches on src → no effect
             (= 2 (count effects))        ; exactly spawn(api) + drain(old)
             (= 2 (count why))))          ; both recorded as facts
```

The self-assertion pins both halves of the claim: the *delta* is exactly
`spawn(api) + drain(old)` with no spurious reload, and the *recording* is exactly
as many facts as effects. If either the pure function or the fact-transaction
were wrong, the run prints `FAIL`.

## What's real vs modelled

**Real, exercised as-is:**

- `datom/connect` — opens a genuine in-memory store (via `datom.conn/connect`)
  with the schema installed before any data.
- `datom/transact!` — real transactions: tempids, upsert through
  `:db.unique/identity`, cardinality-many, an explicit tempid per effect.
- `datom/db` — a real immutable database value is handed to `diff` and to the
  audit query.
- `datom/q` — the real datalog engine (`datom.query.engine/q`); both the
  desired-state read and the audit are actual datalog with real set semantics.
- `erlang/system_time` — the real millisecond clock behind `:effect/at`.

So the two habits the spike claims — *the delta is a value, and effects are
facts* — are demonstrated on the production datom, not a mock. There is no
simulated store, no fake query engine.

**Modelled or simplified in miniature:**

- **Effect application is not performed.** `record-effects!` writes the *record*
  of an effect; nothing calls a `vm.manager` to actually spawn/drain/reload a BEAM
  process. The spike proves the decision and the bookkeeping, not the executor.
  (The README's running tally flags this too: "the reconciler's effect
  application is direct rather than through the live `vm.manager`.")
- **`diff` is a local function, not the design's `reconcile/diff`.** It does not
  run inside the event-driven `proc.server` the doc describes (the reconciler that
  "wakes on events, not on a timer"), and it performs **no z3 proof** — the doc's
  "Provable" property (refuse an unprovably-safe delta) is absent here. `diff`
  always returns effects; it never returns a refusal.
- **Observed state is a literal map.** In the design, observed state is sampled
  live from `vm.ports` claims, the process table, and the env registry. Here it is
  a hand-written `{"web" … "old" …}` map, which is exactly the point of purity
  (you can feed it by hand) but is not a real sample.
- **Desired state is thinner than the doc's schema.** The doc lists
  `:service/heap-words`, `:service/schedules`, `:service/env-spec`, `:node/generation`
  and a `git@…#v1.1`-style source ref. The spike keeps only `id`, `src`, `hosts`
  and treats `src` as an opaque string — enough to exercise spawn/drain/reload,
  nothing more.
- **The recorded effect omits the structured reason.** The doc's fact carries
  `:effect/why-delta {:desired 2 :observed 1}`; the spike records a human string
  `:effect/why` (`"in desired, not observed"`). The *habit* (effects are facts) is
  faithful; the *payload* is simplified.
- **"Returns effects, ordered" is aspirational.** The effect *set* is
  deterministic, but the iteration order comes from `(keys …)` over Erlang maps,
  which is unspecified — so the printed order is not a guarantee. The assertions
  are written order-independently, which is why they hold regardless.

## Run it

```
./blx run research/vps_spike/01_reconciler.bl
```

Expected output ends with:

```
PASS 01_reconciler  effects=2 recorded=2
```

Cold start costs ~10–15s (JIT warmup); that latency is boot, not work.

## Exercises

1. **Bump `web`'s source.** In the desired transaction change `web`'s
   `:service/src` to `"v2"`. Predict first, then run: a third effect `reload web
   ("v1 → v2")` appears, `effects=3 recorded=3` — and the run prints **`FAIL`**,
   because the assertion hardcodes `(= 2 (count effects))`. Lesson: the diff is
   total (it finds every difference), and the assertions are what pin the
   *expected* delta.

2. **Add a third service.** Transact a `db` service (`{:db/id -3 :service/id "db"
   :service/src "v1"}`) alongside the others. Predict: a third effect
   `spawn db`, so `effects=3`, and again **`FAIL`** — but now with `spawn` twice.
   Shows the delta scales with desired state, and that the probe's arithmetic is
   the test, not the engine.

3. **Make the desired transaction idempotent.** Duplicate the `datom/transact!`
   of desired state (run it twice). Predict: no change at all — still two
   services — because `:service/id` is `:db.unique/identity` and the second
   transaction upserts onto the same entities. The delta stays `spawn api` +
   `drain old`. This is why re-running a converge is safe.

4. **Query the audit by time.** Change the audit query to
   `[:find ?svc ?kind ?at :where [?e :effect/svc ?svc] [?e :effect/kind ?kind]
   [?e :effect/at ?at]]` and sort the result by `?at`. Predict: the same two
   rows now arrive in wall-clock order, giving you a timeline. Confirms that the
   recorded effects are genuinely queryable facts — a timeline is one clause away.
