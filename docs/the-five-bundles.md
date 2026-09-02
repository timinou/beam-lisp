# The five bundles: end-user syntax and implementation plan

> `the-process-pattern-language.md` gave 23 patterns and showed the forms are
> bundles of them. Users don't write patterns; they write bundles. This document
> specifies the five an end user reaches for — **server, bus, registry,
> supervisor, fence** — with (a) the primary syntax, (b) an alternative
> syntax, (c) what each composes with, and (d) exactly how it is implemented on
> top of `defprocess` and the shipped runtime.

Design constraints that hold across all five:

1. **Data first, macro second.** Every bundle has a *map form* (a plain value
   you can build, diff, store in datom, verify) and a *macro form* (sugar that
   produces the map). The macro is never the only way in. This is the
   composability lever: a supervisor's children are just values, so a tree can
   be computed, filtered, merged.
2. **One primitive underneath.** Each bundle lowers to `defprocess`
   (`{:state :on :invariant :after :emit}`) — except fence, which lowers to a
   *function* over three patterns and owns no process definition.
3. **Verify is a value op.** `(verify x)` works on any bundle value *before*
   it is started. Same fn, every bundle; the pattern name is the diagnosis.
4. **Existing surface stays.** `defserver` (OTP-callback style) and
   `supervise`/`worker` remain, re-expressed as thin skins. No parallel impls.

---

## 0. `defprocess` — the substrate the bundles lower to

```clojure
(defprocess counter
  {:state     0
   :on        {:inc        (fn [n]      (inc n))            ; Tell edge
               [:add k]    (fn [n]      (+ n k))            ; Tell w/ payload
               [:get ?rep] (fn [n]      (reply ?rep n n))}  ; Ask edge
   :invariant (fn [n] (>= n 0))
   :after     [5000 (fn [n] (log "idle" n) n)]})            ; Timeout Edge
```

- `:on` keys are **receive patterns**; `?rep` is a reply handle (Correlated
  Reply — the macro allocates `from`+`ref`, the user never sees them).
- `(reply ?rep value state')` sends `[ref value]` back and returns `state'`.
  A handler that returns a bare value is a Tell edge (no reply).
- `:invariant` → `preserves?`/`establishes?` at verify time; runtime assert
  in dev.

**Implementation.** `defprocess` is a macro in `priv/process.bl`. Expansion:

```clojure
(def counter
  {:process/name  'counter
   :process/state 0
   :process/on    [[:inc        (fn …)] [[:add k] (fn …)] …]   ; ordered
   :process/inv   (fn …)
   :process/after [5000 (fn …)]})
```

— a **value**. `(start counter)` spawns
`(loop [s state] (receive …clauses… (after ms …)))` from it. Because that
loop is literally what `system.model/extract-loop-receive` reads, `(verify
counter)` = `system.core/verify-process` over the model of that loop: **zero
new verifier code**. When any `:on` handler uses `?rep`, `start` instead
emits a `gen_server` module (reusing `compiler.bl`'s `defserver` emitter, one
callback per edge) so `:sys`, `observer`, and OTP tooling see it.

---

## 1. Server

**What it is.** A process that holds state and answers requests. Bundle:
Loop-Carried State + Ask + Tell + Correlated Reply + Timeout Edge.

### Primary syntax — `defserver` (existing, unchanged for users)

```clojure
(defserver account
  (init [balance] (ok balance))
  (handle-call [:withdraw n] :when (pos? n) [_from balance]
    (if (>= balance n)
      (reply [:ok (- balance n)] (- balance n))
      (reply [:insufficient balance] balance)))
  (handle-call :balance [_from b] (reply b b))
  (handle-cast :reset [_] (noreply 0)))

(def acct (account/start 100))
(account/call acct [:withdraw 30])   ; → [:ok 70]
(account/cast acct :reset)
```

This is the OTP-callback dialect and it stays: it is the right thing for
people arriving from Erlang/Elixir, and its `:when` guard clauses are already
a maximalist feature (validity lives in the edge, not the handler).

### Alternative syntax — `defprocess` map form (the native dialect)

```clojure
(defprocess account
  {:state     100
   :invariant (fn [b] (>= b 0))
   :on {[:withdraw n ?r] :when (pos? n)
          (fn [b] (if (>= b n)
                    (reply ?r [:ok (- b n)] (- b n))
                    (reply ?r [:insufficient b] b)))
        [:balance ?r]     (fn [b] (reply ?r b b))
        :reset            (fn [_] 0)}})

(def acct (start account {:state 100}))     ; override initial state
(ask  acct [:withdraw 30])                  ; → [:ok 70]   (Ask; 5s default timeout)
(ask  acct [:withdraw 30] {:timeout 100})
(tell acct :reset)                          ; Tell
```

Why both: `ask`/`tell` are the two verbs a user needs — Ask and Tell by
name. `?r` makes Correlated Reply invisible. The map form is a value:
`(assoc-in account [:on :reset] …)` adds an edge at runtime; `(verify
account)` reads it.

### Composability

- `(merge-on account audit-edges)` — mix in a map of edges (e.g. a standard
  `:ping ?r` health edge every server gets).
- `(with-invariant account (fn …))` — strengthen an invariant; verify still
  works because it is still a map.
- A server value is a valid **child spec** for a supervisor (§4) as-is.

### Implementation

- `defserver` becomes a *skin*: its clauses are rewritten into the
  `:process/on` vector (`handle-call PAT …` → edge with `?r`;
  `handle-cast` → edge without; `handle-info` → edge; `init` → `:state` fn).
  Then the existing gen_server emitter in `compiler.bl` runs unchanged.
  Cutover, not a parallel path: one emitter, two front-ends.
- `ask` = `make_ref` + `send [pat… self ref]` + `receive [ref v] (after ms
  (throw :timeout))`. For gen_server-backed processes it is
  `GenServer/call`. One name, dispatched on the process's `:process/kind`.
- `reply` for the bare-loop backend = `(erlang/send from [ref v])`; for
  gen_server = `GenServer/reply`. The `?r` handle carries which.

---

## 2. Bus

**What it is.** Broadcast events to N handlers **with backpressure** —
gen_event without the flooding. Bundle: Fan-Out(broadcast) + Demand +
End-of-Stream.

### Primary syntax

```clojure
(defbus payments
  {:demand 16})                          ; per-handler demand batch (default 8)

(def b (start payments))

;; handlers are flow consumers — anything with a demand contract
(subscribe b :ledger  (fn [ev] (ledger/record! ev)))
(subscribe b :metrics (fn [ev] (metrics/tick! (:amount ev))))
(subscribe b :mailer  (flow/filter-stage (fn [ev] (> (:amount ev) 1000))
                                          email/send!))   ; a stage, not a fn

(publish b {:type :paid :amount 42})   ; Tell into the bus
(close b)                              ; End-of-Stream to every handler
```

### Alternative syntax — the bus as a flow producer you fan

```clojure
(def b (flow/broadcast (flow/from-mailbox :payments)))   ; any producer → bus
(flow/run-each b ledger/record! 16)                      ; each run is a subscriber
(flow/run-each (flow/filter-stage b big?) email/send! 4)
(erlang/send :payments {:type :paid :amount 42})
```

This dialect says out loud what a bus *is*: a producer with a broadcast
fan-out. `defbus` is just a name and a registry of subscribers around it.

### Semantics that make it a maximalist bus

- Each subscriber has its own demand counter; the bus emits to subscriber
  `i` only `min(demand_i, queued)`. A slow subscriber slows **only the
  bus's queue for itself** up to `:max-lag` (default 1024), after which the
  bus applies the configured policy: `:block` (the *publisher* is slowed —
  true end-to-end backpressure), `:drop-oldest`, or `:detach` (the
  subscriber is unsubscribed and a `:lagged` event published). Policy is
  per-subscriber: `(subscribe b :metrics f {:on-lag :drop-oldest})`.
- `subscribe` with a `flow` stage means transformation *and* filtering
  happen on the subscriber's side of the demand boundary, so an expensive
  handler cannot slow the bus for others.

### Composability

- A bus is a producer → it plugs into any `flow` stage: `(flow/map-stage b
  f)` is a derived bus.
- Two buses merge: `(flow/merge a b)` (Fan-In).
- A server can subscribe: `(subscribe b :acct (partial tell acct))` — bus
  events become Tell edges on the server. Verifier sees the edge.

### Implementation

- `defbus` → `defprocess` with
  `:state {:subs {id {:pid :demand :queue :policy}} :closed? false}` and
  edges `[:subscribe id pid opts]`, `[:demand id n]`, `[:publish ev]`,
  `[:close]`, `[:DOWN …]` (auto-unsubscribe — Monitor). `[:publish ev]`
  appends to every sub's queue then runs `drain`, which for each sub emits
  `min(demand queue)` as `[:events …]` and decrements. Lag policy applied
  in `drain`. ~80 lines in `priv/bus.bl`, all on top of `flow`'s existing
  `[:subscribe]`/`[:demand]`/`[:events]`/`[:done]` protocol so every flow
  consumer already speaks bus.
- `flow/broadcast` (alt syntax) = the same process, started from a producer
  instead of a mailbox; `defbus` calls it. One engine.

---

## 3. Registry

**What it is.** Name → process, self-healing on death, queryable. Bundle:
Loop-Carried State(relation) + Ask + Monitor(auto-retract).

### Primary syntax

```clojure
(defregistry sessions
  {:keys [:user-id :node]})              ; attributes stored alongside pid

(def r (start sessions))

(register r pid {:user-id 42 :node (node)})
(whereis  r {:user-id 42})               ; → pid | nil   (Ask)
(where    r '[:find ?pid :where [?e :node "b@host"] [?e :pid ?pid]])  ; datalog
(unregister r pid)
```

Processes registered die → entries retract automatically (Monitor edge).
A restarted worker re-registers in its `:state` init.

### Alternative syntax — via-tuple style, no explicit registry object

```clojure
(defprocess session
  {:name  [:sessions {:user-id 42}]     ; ← registered on start, retracted on ⊥
   :state {} :on {…}})

(start session)
(ask [:sessions {:user-id 42}] :ping)  ; addressing by name, ask resolves it
```

The `:name` key on any `defprocess` is the ergonomic path: users mostly
don't want a registry, they want *to name things*. `[:sessions attrs]`
selects a registry and the attributes; the default registry `:global` exists
without declaration.

### Composability

- Registry state is a datom db: `where` is `datom/q` over it. Reachability
  facts (`:~reachable`) and registry facts live in the same relational
  space, so *"pids on a node that just went down, whose process can reach
  state X"* is one query.
- A supervisor can address children by name: `(child sup [:sessions
  {:user-id 42}])`.
- Cross-node: a registry started with `{:scope :cluster}` replicates entries
  via `pg`-style gossip — **unbuilt; single-node only in the first slice.**

### Implementation

- `defregistry` → `defprocess` with `:state` = a datom conn; edges
  `[:register pid attrs ?r]` (assert `{:pid pid …attrs}`, `erlang/monitor
  pid`, reply), `[:whereis attrs ?r]` (query, reply), `[:where q ?r]`,
  `[:unregister pid ?r]`, `[:DOWN _ :process pid _]` (retract all datoms with
  that `:pid`). Invariant: every `:pid` in the db is `alive?` — the verifier
  checks the `:DOWN` handler exists in the only state (Monitor pattern rule).
- `:name` on `defprocess`: `start` does `(register (registry-of name) self
  attrs)` first thing in the spawned process; the registry's monitor handles
  retract. `ask`/`tell` accept `[reg attrs]` and resolve via `whereis` (one
  hop, cached per call).
- `priv/registry.bl`, ~100 lines; `vitals.bl`'s hand-rolled atom registry is
  cut over to it (one need, one impl).

---

## 4. Supervisor

**What it is.** A policy over children's failure edges, verified before boot.
Bundle: Monitor|Link + Healing Edge + Governor + Invariant Gate.

### Primary syntax — tree as data

```clojure
(defsupervisor billing
  {:strategy  :one-for-one
   :intensity [3 5000]                        ; Governor: 3 restarts / 5s
   :children  [(child :acct    account {:state 100})
               (child :bus     payments)
               (child :workers (pool worker {:size 4}))   ; a sub-supervisor
               (child :ledger  ledger {:restart :transient})]})

(verify billing)   ; → :ok | {:unsafe :workers {:pattern :governor :lasso [...]}}
(def s (start billing))
(children s)       ; → [{:id :acct :pid … :state :alive :restarts 0} …]
(kill s :acct)     ; → healed; (children s) shows a new pid, restarts 1
```

- `child` builds a child spec from **any bundle value** (server, bus,
  registry, another supervisor, a bare `defprocess`). Per-child `:restart
  :permanent|:transient|:temporary`, `:shutdown ms`.
- `pool` = N identical children under a `one-for-one` sub-supervisor with a
  Fan-Out(distribute) front: `(tell (pool-of s :workers) job)` goes to one
  worker with demand.

### Alternative syntax — supervision as a wrapping form

```clojure
(supervise :one-for-all {:intensity [3 5000]}
  (worker :acct   (start account {:state 100}))
  (worker :bus    (start payments))
  (supervise :one-for-one (pool worker 4)))
```

This is today's `supervise`/`worker`, extended to nest and accept bundle
values. Same semantics; it reads as a tree drawn in code. Both forms yield
the same `:sup/…` map; `verify` and `start` don't care which you wrote.

### What verify checks (the Invariant Gate composed)

| check | pattern | shipped verb |
|---|---|---|
| each child's `s0 ⊨ invariant` | Healing Edge | `establishes?` |
| every child edge keeps its invariant | — | `preserves?` |
| no child has a lasso through `⊥` | Governor | `find-lasso` |
| every Ask between siblings is answered | Ask | `all-senders-guarantee?` |
| no two siblings Ask each other | — | `deadlocked` |
| `one-for-all`: no sibling `s0` violates another's invariant | Healing Edge (cross-form) | `establishes?` over the union |
| link topology agrees with strategy | Link | link-closure vs strategy (new, small) |

The last two are the **whole-graph** checks that don't exist per-process:
they need the union graph, which the tree value provides.

### Composability

- Trees are values: `(update billing :children conj (child :cache cache))`,
  `(merge-trees a b)`, `(filter-children billing #(= :permanent (:restart
  %)))`. A deploy can `diff` two trees.
- `(start billing {:children {:acct {:state 0}}})` overrides child args.
- `vitals` renders any started tree: `(vitals/watch s)`.
- Hot upgrade: `(reload/stage billing')` + `(super/apply s billing')` starts
  new children, stops removed, restarts changed — **designed, unbuilt.**

### Implementation

- `defsupervisor`/`child`/`pool` → a map `{:sup/strategy :sup/intensity
  :sup/children [{:id :spec :restart :shutdown}]}`.
- `start` lowers to OTP: `Supervisor/start_link` with child specs whose
  `start` is `(fn [] (start spec))` — the **existing** `BeamLisp.Supervisor`
  path in `rt.ex`. No new restart machinery; OTP does Healing Edge and
  Governor. `supervise`/`worker` are rewritten to build the same map (skin).
- `verify` = `system.core` verbs over `(system.model/system-model (map
  :spec children))`; the two new checks (`one-for-all` cross-invariant,
  link-closure) are ~40 lines in `priv/super.bl`.
- `children`/`kill` = `Supervisor/which_children` + `terminate_child`, shaped
  as maps. `vitals.bl` cuts over from its hand-rolled sup to this.

---

## 5. Fence

**What it is.** Run something isolated and bounded; get `{:ok v}`,
`{:crash reason}`, or `{:timeout}`. Bundle: Monitor + Ask + Timeout Edge. Not
a process form — a **function**.

### Primary syntax

```clojure
(fence 200 (risky-eval form))           ; → {:ok v} | {:crash r} | {:timeout}

(match (fence 200 (risky-eval form))
  {:ok v}      (use v)
  {:crash r}   (log "died" r)
  {:timeout}   (log "hung"))
```

`fence` is a macro: body runs in a fresh spawned process; caller monitors,
waits ≤ ms, demonitors + flushes on every exit (the leak hand-rolled fences
get wrong).

### Alternative syntax — fence as a value / option map

```clojure
(fence {:ms 200 :kill? true :as :either} (risky-eval form))
;; :kill? true  → on timeout, exit the child (default true)
;; :as :either  → return [:ok v] | [:err {:crash r}] (Either shape for →>)
;; :as :throw   → throw on crash/timeout (for code that wants exceptions)

(fence-fn 200 f)                        ; fn form, for higher-order use:
(pmap (partial fence-fn 200) fns)      ; fence a batch
```

### Composability

- With flow: `(flow/map-stage up (partial fence-fn 50))` — a stage whose
  every element is isolated; a poison element yields `{:crash …}` downstream
  instead of killing the stage.
- With server: an `:on` handler body wrapped in `fence` turns "handler
  crashes → server restarts" into "handler failure → reply `{:crash r}`" —
  choose per edge whether to let it crash or fence it.
- With supervisor: `ward` = fence per test + a collector; `spell/fence.bl` =
  fence + a reply — both become one call.

### Implementation

- `priv/fence.bl`, ~30 lines:
  ```clojure
  (defmacro fence [opts & body]
    `(fence-fn ~opts (fn [] ~@body)))
  (defn fence-fn [opts f]
    (let [{:keys [ms kill?]} (norm opts)
          {:keys [pid ref]} (spawn-monitor (fn [] (erlang/send (self) [ref (f)])))]  ; ← see NB
      (receive
        [r v]     :when (= r ref)   (do (demonitor ref :flush) {:ok v})
        [:DOWN r :process _ reason] :when (= r ref) {:crash reason}
        (after ms (do (when kill? (erlang/exit pid :kill))
                      (demonitor ref :flush) {:timeout})))))
  ```
  NB: reply is sent to the *caller* (captured before spawn) with the
  monitor ref as the correlation tag — the `:when` guards are the Correlated
  Reply pattern under beam-lisp's rebinding `receive`. Cut over
  `spell/fence.bl` (2 copies) and `ward`'s per-test wrapper to call it.

---

## 6. How they compose — one program using all five

```clojure
(defprocess worker
  {:name  [:workers {:id (gensym)}]                      ; registry
   :state {:done 0}
   :on    {[:job j] (fn [s] (match (fence 50 (process j))  ; fence per job
                              {:ok v}   (do (publish :results v) (update s :done inc))
                              {:crash r} (do (publish :errors {:job j :r r}) s)
                              {:timeout} (do (publish :errors {:job j :r :hung}) s)))
           [:stats ?r] (fn [s] (reply ?r s s))}})           ; server edge

(defbus results {:demand 32})
(defbus errors  {:demand 8 :on-lag :drop-oldest})

(defsupervisor app
  {:strategy :one-for-one :intensity [5 10000]
   :children [(child :registry (registry :workers))
              (child :results  results)
              (child :errors   errors)
              (child :workers  (pool worker {:size 8}))]})

(verify app)                     ; whole-graph gate: :ok
(def s (start app))
(subscribe (child s :errors) :log println)
(doseq [j jobs] (tell (pool-of s :workers) [:job j]))   ; distribute
(ask [:workers {:id …}] :stats)
```

Every line is one named pattern; every value is inspectable, verifiable,
diffable; nothing is a black box.

---

## 7. Build plan (order chosen so each step is a green cutover)

1. **`priv/process.bl`** — `defprocess`, `start`, `ask`, `tell`, `reply`,
   `verify` (delegating to `system.core`). Test: `counter` above, verified +
   run. Bare-loop backend only.
2. **`priv/fence.bl`** — `fence`/`fence-fn`. Test: three outcomes. Cut over
   `ward`'s per-test wrapper. (Independent of 1; do in parallel.)
3. **`defserver` → skin** over `defprocess` + the existing gen_server emitter.
   Test: `examples/server.bl`, `guards.bl` unchanged and green.
4. **`priv/registry.bl`** — `defregistry`, `:name` on `defprocess`,
   name-addressed `ask`/`tell`. Cut over `vitals.bl`'s atom registry.
5. **`priv/bus.bl`** — `defbus` on `flow`'s protocol; `flow/broadcast`.
   Test: two subscribers, one slow, lag policy observed.
6. **`priv/super.bl`** — `defsupervisor`/`child`/`pool`, `verify` over the
   tree (incl. the two new cross-form checks), `supervise`/`worker` as skin.
   Cut over `vitals.bl`'s hand-rolled supervisor. Test: `examples/supervision.bl`
   green + one `verify` that *rejects* a child with a lasso.
7. **§6 example** as `examples/bundles/00-all-five.bl`, and the
   `the-process-pattern-language.md` ledger updated from ◐/○ to ✅.

Unbuilt after this plan, stated plainly: cluster-scoped registry, hot
tree upgrade (`super/apply`), `^pin` in `receive`.
