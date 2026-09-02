# The five bundles: end-user syntax and implementation plan

> `the-process-pattern-language.md` gave 23 patterns and showed the forms are
> bundles of them. Users don't write patterns; they write bundles. This document
> specifies the five an end user reaches for — **server, fence, registry, bus,
> supervisor** — the verbs that act on them, and how each is implemented on the
> shipped runtime.

Three facts fix the design:

1. **Inspectability is free.** The reader turns every form into a tree;
   `system/model` extracts the transition graph from any `receive` shape —
   *"five surface forms lower to the identical transition graph."*
   `codebase.bl` proves the same for call graphs. So no `def*` form has to
   return a "spec map" to be verifiable; `(system/verify 'ns/name)` reads the
   source. Syntax decides **ergonomics of use only**.
2. **One dialect per form.** `defserver`'s clause style — `(init …)`,
   `(handle-call PAT :when G [from state] …)` — is the house style; every
   other `def*` uses the same `(clause-head args…)` shape. No alternative
   map dialect.
3. **Verbs are generic and layered the BEAM's way.** No per-instance methods
   (`account/call` does not exist; slash means namespace). See §0.

---

## 0. The verb tiers

On the BEAM every verb is generic over a *behaviour*: `erlang:send` for any
process, `gen_server:call` for any gen_server, `supervisor:which_children`
for any supervisor. A user module adds only a **domain client API**
(`Account.withdraw/2`) that wraps the generic call. beam-lisp keeps exactly
that layering.

Supervisor, registry, and bus are all gen_servers (supervisor literally;
registry and bus are built with `defserver`), so `call`/`cast` are truly
universal.

| tier | where | verbs | holds for |
|---|---|---|---|
| **1 prelude** | top-level | `start` `start-link` `stop` · `call` `cast` · `monitor` `link` `kill` · `fence` `fence-fn` · `supervise` `worker` | every process |
| **2 behaviour** | `kind/` ns | `super/children` `super/child-of` `super/terminate` `super/restart` · `reg/register` `reg/unregister` `reg/whereis` `reg/where` · `bus/publish` · `flow/subscribe` (a bus *is* a producer) | every process of that kind |
| **3 domain** | your ns, plain `defn` | `(defn withdraw [a n] (call a [:withdraw n]))` | this protocol |
| **4 definition** | only inside a `def*` | `init handle-call handle-cast handle-info name invariant` · `ok reply noreply stop` · `keys` · `demand` · `strategy intensity child pool` | return vocabulary |
| **graph** | `system/` | `system/verify` `system/model` | beam-lisp's addition; the BEAM has no equivalent |

Cutovers implied: `server-start-link`/`server-call`/`server-cast`/`server-stop`
→ `start-link`/`call`/`cast`/`stop` (drop the prefix; they are generic).
`kill` is the generic `erlang/exit pid :kill`; the supervisor's child
termination is `super/terminate`, never `kill`.

**Names are values.** `[:registry key]` is accepted wherever a pid is.
Resolution happens once, inside `call`/`cast`/`stop`/`monitor`, not in each
form — the via-tuple idea, as a Lisp.

---

## 1. Server

Bundle: Loop-Carried State + Ask + Tell + Correlated Reply + Timeout Edge.

```clojure
(ns bank)

(defserver account
  (init [b] (ok b))
  (invariant [b] (>= b 0))                                   ; ○ new clause
  (handle-call [:withdraw n] :when (pos? n) [_from b]
    (if (>= b n)
      (reply [:ok (- b n)] (- b n))
      (reply [:insufficient b] b)))
  (handle-call [:withdraw n] [_from b] (reply [:invalid n] b))
  (handle-call :balance [_from b] (reply b b))
  (handle-cast :reset   [_b]      (noreply 0)))

;; domain client API — yours, plain defn
(defn withdraw [a n] (call a [:withdraw n]))
(defn balance  [a]   (call a :balance))

(def a (start-link account 100))
(withdraw a 30)                 ; → [:ok 70]
(cast a :reset)
(stop a)
(system/verify 'bank/account)   ; → :ok | {:unsafe …} — from source, no process
```

**Implementation.**
- `defserver` exists; the gen_server emitter in `compiler.bl` is unchanged.
- `(invariant [s] pred)` clause: stored as a `defn` `account-invariant` the
  emitter also asserts in dev builds; `system/verify` reads it for
  `establishes?`/`preserves?`. ~20 lines in `compiler.bl`.
- `call`/`cast`/`start`/`start-link`/`stop`: rename of `server-*` in the
  prelude, plus name resolution (`[:reg key]` → `reg/whereis`) at the top of
  each. `call` takes `{:timeout ms}` as optional third arg.

---

## 2. Fence

Bundle: Monitor + Ask + Timeout Edge. A **function**, not a form — nothing to
define, nothing to supervise.

```clojure
(fence 200 (risky-eval form))        ; → {:ok v} | {:crash reason} | {:timeout}

(match (fence 200 (risky-eval form))
  {:ok v}     v
  {:crash r}  (log :died r)
  {:timeout}  (log :hung))

(fence {:ms 200 :kill? true :as :throw} (risky-eval form))
;; :kill? true → exit the child on timeout (default true)
;; :as :throw  → raise instead of returning the map

(map #(fence-fn 50 %) thunks)        ; higher-order; composes with flow/map-stage
```

**Implementation.** `priv/fence.bl`, ~30 lines:

```clojure
(defmacro fence [opts & body] `(fence-fn ~opts (fn [] ~@body)))

(defn fence-fn [opts f]
  (let [{:keys [ms kill?]} (norm-opts opts)
        me  (self)
        {:keys [pid ref]} (spawn-monitor (fn [] (erlang/send me [:fence-ok (self) (f)])))]
    (receive
      [:fence-ok p v]             :when (= p pid) (do (demonitor ref :flush) {:ok v})
      [:DOWN r :process _ reason] :when (= r ref) {:crash reason}
      (after ms (do (when kill? (erlang/exit pid :kill))
                    (demonitor ref :flush)
                    {:timeout})))))
```

The `:when` guards are Correlated Reply under beam-lisp's rebinding `receive`.
`demonitor :flush` on every exit is the leak hand-rolled fences miss.
Cut over: `spell` `fence.bl` (2 copies) and `ward`'s per-test wrapper.

---

## 3. Registry

Bundle: Loop-Carried State (a relation) + Ask + Monitor (auto-retract).

```clojure
(defregistry sessions
  (keys :user-id :node))             ; attributes stored with each pid

(def r (start sessions))
(reg/register   r pid {:user-id 42 :node (node)})
(reg/whereis    r {:user-id 42})     ; → pid | nil
(reg/where      r '[:find ?p :where [?e :node "b@h"] [?e :pid ?p]])   ; datalog
(reg/unregister r pid)
;; an entry retracts itself when its pid dies

;; a name is a value — every prelude verb accepts one
(call [:sessions {:user-id 42}] :balance)

;; a server names itself; registered on start, retracted on ⊥
(defserver session
  (name [:sessions {:user-id 42}])
  (init [_] (ok {}))
  …)
```

**Implementation.** `defregistry` expands to a `defserver` whose state is a
datom conn: `handle-call [:register pid attrs]` asserts `{:pid pid …attrs}`
and `erlang/monitor`s; `[:whereis attrs]` / `[:where q]` query;
`handle-info [:DOWN _ :process pid _]` retracts every datom with that `:pid`.
Invariant: every `:pid` in the db is alive — the Monitor rule (`:DOWN`
handled in the only state) is what `system/verify` checks. `(name …)` on
`defserver` → `init` prepends `reg/register`. `priv/registry.bl`, ~100 lines;
`vitals.bl`'s atom registry cuts over. Single-node only in this slice.

---

## 4. Bus

Bundle: Fan-Out (broadcast) + Demand + End-of-Stream — gen_event with
backpressure.

```clojure
(defbus payments
  (demand 16))                       ; per-subscriber pull size (default 8)

(def b (start payments))
(flow/subscribe b :ledger ledger/record!)                       ; a fn
(flow/subscribe b :big    (flow/filter-stage #(> (:amount %) 1000) email/send!)
                          {:on-lag :drop-oldest})               ; a stage + policy
(bus/publish b {:type :paid :amount 42})
(stop b)                             ; End-of-Stream to every subscriber
```

Each subscriber pulls at its own demand. A slow one backs up only its own
queue to `:max-lag` (default 1024), then its policy fires: `:block` (the
*publisher* is slowed — end-to-end backpressure), `:drop-oldest`, or `:detach`
(unsubscribed, a `:lagged` event published).

**Implementation.** `defbus` expands to a `defserver` with state
`{:subs {id {:pid :demand :queue :policy}} :closed? false}` speaking `flow`'s
existing `[:subscribe]/[:demand]/[:events]/[:done]` protocol — so every flow
consumer already speaks bus and `flow/subscribe` needs no bus-specific code.
`[:publish ev]` appends to each queue then drains `min(demand queue)` per
subscriber; lag policy applied in drain; `:DOWN` auto-unsubscribes.
`priv/bus.bl`, ~80 lines. `flow/broadcast` (any producer → bus) is the same
server started from a producer instead of `bus/publish`.

---

## 5. Supervisor

Bundle: Monitor|Link + Healing Edge + Governor + Invariant Gate.

```clojure
(defsupervisor billing
  (strategy  :one-for-one)
  (intensity 3 5000)                          ; Governor: 3 restarts / 5 s
  (child :acct    account 100)                ; anything startable + start args
  (child :bus     payments)
  (child :reg     sessions)
  (child :workers (pool worker 4))            ; sub-supervisor, one-for-one
  (child :ledger  ledger {:restart :transient :shutdown 5000}))

(system/verify 'bank/billing)   ; whole-graph gate, before boot
(def s (start-link billing))
(super/children s)              ; → [{:id :acct :pid … :restarts 0} …]
(call (super/child-of s :acct) :balance)
(super/terminate s :acct)       ; → healed: new pid, restarts 1

;; existing wrapping form — same result
(supervise :one-for-one {:intensity [3 5000]}
  [(worker :acct (fn [] (start-link account 100)))])
```

`child` takes **any** startable name — a server, bus, registry, another
supervisor — so no form needs a `child_spec` callback. `pool` is N identical
children under a `one-for-one` sub-supervisor with a Fan-Out(distribute)
front: `(cast (super/child-of s :workers) job)` reaches one worker with demand.

**What `system/verify` checks on a tree:**

| check | pattern | verb |
|---|---|---|
| each child `s0 ⊨ invariant` | Healing Edge | `establishes?` |
| every child edge keeps its invariant | — | `preserves?` |
| no child has a lasso through `⊥` | Governor | `find-lasso` |
| every Ask between siblings is answered | Ask | `all-senders-guarantee?` |
| no two siblings Ask each other | — | `deadlocked` |
| `one-for-all`: no sibling `s0` violates another's invariant | Healing Edge (cross-form) | `establishes?` over the union |
| link topology agrees with strategy | Link | link-closure vs strategy (new) |

The last two exist only at tree level — they need the union graph.

**Implementation.** `defsupervisor` expands to a `defn billing-spec` returning
OTP child specs whose `start` is `(fn [] (start-link child args))`, and
`start-link billing` → `Supervisor/start_link` — the **existing**
`BeamLisp.Supervisor` path in `rt.ex`. OTP does Healing Edge and Governor; no
new restart machinery. `supervise`/`worker` are rewritten to produce the same
specs. `system/verify` on a supervisor name = `system.core` verbs over
`(system.model/system-model children-sources)` plus the two new checks
(~40 lines, `priv/super.bl`). `super/children`/`child-of`/`terminate`/`restart`
wrap `Supervisor/which_children`/`terminate_child`/`restart_child` as maps.
`vitals.bl`'s hand-rolled supervisor cuts over.

---

## 6. All five in one program

```clojure
(ns jobs)

(defserver worker
  (name [:workers {:id (gensym)}])
  (init [_] (ok {:done 0}))
  (handle-cast [:job j] [s]
    (match (fence 50 (process j))
      {:ok v}     (do (bus/publish [:results] v)               (noreply (update s :done inc)))
      {:crash r}  (do (bus/publish [:errors] {:job j :r r})    (noreply s))
      {:timeout}  (do (bus/publish [:errors] {:job j :r :hung}) (noreply s))))
  (handle-call :stats [_ s] (reply s s)))

(defbus results (demand 32))
(defbus errors  (demand 8))
(defregistry workers (keys :id))

(defsupervisor app
  (strategy :one-for-one)
  (intensity 5 10000)
  (child :workers-reg workers)
  (child :results     results)
  (child :errors      errors)
  (child :pool        (pool worker 8)))

(system/verify 'jobs/app)                              ; :ok
(def s (start-link app))
(flow/subscribe (super/child-of s :errors) :log println)
(doseq [j job-list] (cast (super/child-of s :pool) [:job j]))
(call [:workers {:id some-id}] :stats)
```

---

## 7. Build plan — each step a green cutover

| # | step | files | test / cutover |
|---|---|---|---|
| 1 | **Docs trued** (this commit) | `the-process-pattern-language.md`, `the-five-bundles.md` | — |
| 2 | **Generic verbs**: `call` `cast` `start` `start-link` `stop` in prelude; name resolution hook (no-op until 5) | `priv/prelude.bl` (or wherever `server-call` lives), `compiler.bl` client API | `examples/server.bl`, `guards.bl` green using new names; `server-*` removed (cutover) |
| 3 | **`fence`** | `priv/fence.bl` | new `examples/fence.bl`: three outcomes green; `ward` per-test wrapper cut over; note for spell to cut its two copies |
| 4 | **`defserver (invariant …)`** clause + `system/verify` on a server name | `compiler.bl`, `priv/system/core.bl` | `guards.bl` `account` gains invariant; `(system/verify 'account)` → `:ok`; a deliberately bad server → `{:unsafe …}` |
| 5 | **`defregistry`**, `(name …)` clause, name resolution in verbs | `priv/registry.bl`, `compiler.bl`, prelude | `examples/registry.bl`: register / whereis / where / auto-retract on kill; `vitals.bl` atom registry cut over |
| 6 | **`defbus`** on flow's protocol, `flow/broadcast` | `priv/bus.bl`, `priv/flow.bl` | `examples/bus.bl`: two subscribers, one slow, `:drop-oldest` observed; `stop` reaches both |
| 7 | **`defsupervisor`**, `child`, `pool`, `super/*`, `system/verify` over a tree; `supervise`/`worker` as skin | `priv/super.bl`, `rt.ex` (specs only), `priv/system/core.bl` | `examples/supervision.bl` green; `system/verify` **rejects** a child with a lasso; `vitals.bl` hand-rolled sup cut over |
| 8 | **§6 example** + pattern ledger ◐/○ → ✅ | `examples/bundles/00-all-five.bl`, `the-process-pattern-language.md` | example green end to end |

Steps 2 and 3 are independent (parallel). 4 needs 2. 5–7 each need 2; 7 needs
4 (verify) and benefits from 5 (`child-of` by name). 8 needs all.

Stated unbuilt after step 8: cluster-scoped registry, hot tree upgrade
(`super/apply` via `reload`), `^pin` in `receive`.
