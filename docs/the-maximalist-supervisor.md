# The beam-lisp maximalist supervisor — and the OTP surface, reinterpreted

> This is the piece that got dropped when the "build a tool" pivot swallowed the
> turn. It is the *design*: what OTP's whole concurrency vocabulary becomes when
> you interpret it "the beam-lisp way," and why that consecrates evolutionary
> biology and emergence in a way no previous BEAM language could.

---

## 0. The one move that makes everything else follow

Every previous BEAM language treats a running process as an **opaque box**: you
can send it messages, link it, supervise it, and observe it *from outside* with
a separate tool (`:observer`, `:sys`, `recon`). The code that *defines* the
process and the graph that *describes* its behaviour are two different things —
source in a file, behaviour in a runtime you inspect.

beam-lisp collapses that gap. Because the language is homoiconic and ships
`system/model`, **a process's code IS a transition graph you can query**. I
verified this in the tree: `system.model/graph` turns any `defserver` or
receive-loop into `{states, transitions}`; `system.core` then runs
`verify-process`, `reachable-states`, `deadlocked`, `find-lasso`,
`discover-invariant`, and even `repair-process` / `repair-transition` over it.

So the beam-lisp way is not "OTP with parentheses." It is:

> **A process, its supervisor, and its failure modes are all VALUES the program
> can read, query, verify, and repair — including about itself.**

Hold that. Every noun and verb below is an application of it.

---

## 1. What already exists (grounded, not assumed)

Before designing, the honest inventory — what I confirmed by reading the source:

| capability | status | evidence |
|---|---|---|
| `supervise` / `worker` | ✅ native (Wave 22) | `BeamLisp.Supervisor.supervise/2,3` in `rt.ex`; `examples/supervision.bl` kills a child and OTP restarts it |
| `defserver` → real gen_server | ✅ | compiles `@behaviour :gen_server`; `:sys`/`Supervisor` recognise it |
| `Agent` / `Task` | ✅ interop | `examples/processes.bl` |
| a process → transition graph | ✅ | `system.model/graph`, `transitions`, `extract-defserver` |
| verify / repair a process | ✅ | `system.core/verify-process`, `repair-process`, `discover-invariant`, `find-lasso` |
| `flow` (demand/GenStage) | ✅ built earlier this thread | `priv/flow.bl` |
| **`defsupervisor` (declarative tree)** | ❌ not yet | only raw `supervise` + interop |
| **gen_statem / gen_event / Registry / Application** | ❌ not yet | interop-only or absent |

So the maximalist supervisor is not greenfield — it is **a declarative skin +
the verification layer, over primitives that already restart processes.** The
novelty is making the tree *introspectable and provable*, not making it restart.

---

## 2. The maximalist supervisor

### 2.1 The tree is literally data

A supervision tree in OTP is *conceptually* data (a child spec list). In
beam-lisp it is *literally* a value you can build, inspect, diff, and query:

```clojure
(defsupervisor billing
  {:strategy   :one-for-one          ; :one-for-one | :one-for-all | :rest-for-one
   :intensity  {:restarts 3 :within 5000}   ; the governor (see §2.3)
   :children
   [{:id :ledger    :start (server ledger conn)   :restart :permanent}
    {:id :collector :start (worker collect-fn)    :restart :transient}
    {:id :reporter  :start (server reporter)      :restart :temporary
     :shutdown 5000}
    (subtree audit-supervisor)]})     ; ← a child MAY be another supervisor
```

`defsupervisor` lowers to the existing native `supervise`/`worker` — it adds no
new runtime, only a **declarative surface + a value you can read back**:

```clojure
(super/tree billing)      ; → the spec AS DATA, the live pids grafted in
(super/which billing)     ; → [{:id :ledger :pid #PID<…> :alive true} …]
(super/diff billing billing')  ; → what a hot reconfig would add/remove/restart
```

The last one matters: because the tree is a value, **reconfiguring a supervisor
is a diff**, not a stop-the-world restart. That is the `reload`-transaction
ethic (from the "staying alive" doc) applied to topology.

### 2.2 The restart strategies, honestly

Nothing exotic — the OTP three, but each is *a policy value*, swappable and
inspectable:

- `:one-for-one` — a child dies → restart just it.
- `:one-for-all` — a child dies → restart *all* siblings (they only work as a set).
- `:rest-for-one` — a child dies → restart it + everything started after it (a
  dependency chain).

The maximalist addition is that the strategy is **queryable against the model**:
`(super/explain billing :collector)` can answer *"if `:collector` crashes, what
else restarts, and is that set safe?"* — because the child graph is data and the
strategy is a pure function over it.

### 2.3 Restart intensity = the governor (the cybernetics)

`{:restarts 3 :within 5000}` is the load-bearing idea most tutorials skip: if a
supervisor restarts more than N times in T ms, it concludes *restarting isn't
fixing this* and **kills itself**, escalating to its own supervisor. This is a
**hierarchical control loop**: local correction saturates → control passes to a
level with more scope. beam-lisp keeps the OTP semantics but makes the escalation
**observable as an event value** on the `reload/subscribe` bus, so the vitals
observatory (built last turn) can render an escalation climbing the tree live.

### 2.4 The thing no other BEAM language can do: a **provable** supervisor

Because `system.core` already ships `verify-process` and `find-lasso`, a
maximalist supervisor can gate its own children at *definition* time:

```clojure
(defsupervisor billing
  {:verify {:no-deadlock   true       ; every child's graph is deadlock-free
            :restart-safe  true       ; a restart re-establishes each child's invariant
            :liveness      :bounded}   ; no child has an infinite-restart lasso
   :children [...]})
```

`:no-deadlock` runs `deadlocked` over each child's transition graph. `:liveness`
runs `find-lasso` to prove no child can wedge into a restart cycle. This is
**supervision + model-checking in one declaration** — the supervisor refuses to
start a child it can prove will wedge. OTP restarts blindly; this restarts
*with a proof that the restart re-establishes the invariant* (`establishes?` /
`preserves?` are already in `system.core`).

---

## 3. The full OTP surface, reinterpreted the beam-lisp way

This is the "remaining nouns and verbs." Each row: the OTP primitive, and what
it *becomes* when a process is a value you can query.

### 3.1 `gen_statem` → **a state machine that is its own model**

OTP's `gen_statem` is a callback module with `state_functions`. The beam-lisp
form makes the state graph *the same value* verification reads:

```clojure
(defmachine turnstile
  {:initial :locked
   :states
   {:locked   {:coin :unlocked  :push :locked}
    :unlocked {:push :locked     :coin :unlocked}}
   :invariant (fn [s] (contains? #{:locked :unlocked} s))})
```

`defmachine` lowers to a real `gen_statem` (so `:sys` and Supervisor recognise
it), AND registers its transitions with `system.step/register-step!` — which I
read: it makes `:~step` a **computed datalog relation**. So:

```clojure
(machine/reachable? turnstile :unlocked)     ; datalog over :~step
(machine/path-to turnstile :unlocked)        ; the shortest coin/push sequence
(machine/verify turnstile :invariant)        ; model-check the invariant
```

The state machine and its proof are one artifact. `gen_statem` gave you the
runtime; beam-lisp gives you the runtime *and the reachability query over it*,
with no drift possible because the graph is derived from the code.

### 3.2 `gen_event` → **a demand-aware event manager**

OTP's `gen_event` is a push manager (handlers registered, events broadcast). The
beam-lisp reinterpretation routes it through `flow`, so downstream handlers exert
**backpressure** (the demand tier from earlier in this thread):

```clojure
(defbus audit
  {:handlers [log-handler metric-handler]
   :backpressure :demand})    ; a slow handler slows the source, never floods
```

`gen_event`'s notorious weakness (one slow handler blocks the manager, or events
pile unboundedly) dissolves because `flow`'s demand protocol is the transport.

### 3.3 `Registry` / `:global` / `pg` → **a process registry that is a query**

Naming processes ("who handles user 42?") becomes a datom query rather than a
lookup against an opaque table:

```clojure
(defregistry sessions {:key :user-id})
(reg/put sessions 42 pid)
(reg/where sessions '[:find ?pid :where [?p :user-id 42] [?p :pid ?pid]])
```

Because the registry is datom-backed, "which sessions are on a dead node?" is the
*same shape of query* as the supervisor-decision-as-query I proved in
`08-otp.bl`. One query language for state AND liveness AND topology.

### 3.4 `Application` → **a system that boots as a value and is verified as one**

An OTP `application` is a boot spec + a root supervisor. The maximalist form is a
**value whose entire tree can be verified before it boots**:

```clojure
(defsystem billing-app
  {:root billing              ; the root supervisor value from §2.1
   :verify :restart-safe      ; prove the WHOLE tree before start
   :env {:pool-size 8}})

(system/verify billing-app)   ; → :ok | {:unsafe child reason}  — BEFORE boot
(system/start billing-app)
```

This is the endgame: **boot-time model-checking of a supervision tree**, which
OTP structurally cannot do because in OTP the tree is code, not data.

### 3.5 The noun/verb table, whole

| OTP noun | beam-lisp form | new verbs it unlocks |
|---|---|---|
| `supervisor` | `defsupervisor` | `tree` · `which` · `diff` · `explain` · `verify` |
| `gen_server` | `defserver` (exists) | `+ model` · `+ verify-process` · `+ repair` |
| `gen_statem` | `defmachine` | `reachable?` · `path-to` · `verify` |
| `gen_event` | `defbus` | `+ :demand` backpressure |
| `Registry`/`pg` | `defregistry` | `where` (datalog naming) |
| `Application` | `defsystem` | `verify` (boot-time proof) |
| `Task` | `flow` producer / `go` | (compat + demand) |
| child spec | a **map value** | inspect · diff · graft |
| restart strategy | a **policy value** | `explain` against the graph |
| the whole tree | a **datom** | query topology + liveness together |

The verbs on the right are the ones **no previous BEAM language has**, and every
one is an application of §0: the process is a value.

---

## 4. What beam-lisp is *uniquely* able to do — the biology

The ask was: how does this consecrate **evolutionary biology** and **emergence
in systems theory**? Not as metaphor — as a real correspondence the machinery
now supports.

### 4.1 Supervision is homeostasis; beam-lisp adds the genome

Erlang already gave the BEAM **homeostasis**: nested control loops (supervision
trees) that sense deviation (a crash) and restore a setpoint (known-good state),
escalating when local correction saturates. That is the architecture of every
living system — cell → tissue → organ → organism, each a regulatory loop handing
off to the next.

But biology has a *second* layer Erlang never captured: the **genome** — a
readable, mutable, *inheritable* description of the organism, separate from the
organism running. In OTP the "genome" (the code) and the "phenotype" (the running
process) are divorced: you read the genome in a file, you observe the phenotype
in `:observer`, and nothing connects them at runtime.

beam-lisp reunites them. `system.model/graph` is the phenotype **read back as
genotype** — the running behaviour, recovered as an inspectable description. And
`reload` makes that description **mutable in place, transactionally, on the live
organism**. That is the missing biological primitive: an organism that carries
its own genome, can read it, and can edit it while alive without dying.

### 4.2 `repair-process` is directed evolution

The verb that stopped me cold when I found it: `system.core/repair-process` (and
`repair-transition`, `discover-invariant`, `synthesize-capacity`). OTP's answer
to a broken process is *restart the same code* — reproduction without variation.
Evolution needs three things: **variation, selection, heredity.**

- **variation** — `repair-transition` *synthesizes a changed transition* that
  fixes a violated invariant. The organism's genome is altered, not just copied.
- **selection** — `verify-process` / `find-lasso` are the fitness function: a
  variant that deadlocks or wedges is rejected *before* it runs.
- **heredity** — `reload`'s coherent commit installs the repaired genome into the
  live image; children spawned after inherit it.

So beam-lisp has, in the tree already, the loop: **observe a failing process →
synthesize a repaired variant → prove it fitter (no deadlock, invariant
re-established) → inherit it into the live system.** That is not "let it crash and
restart the same thing." That is **directed evolution of a running program** —
apoptosis (let it crash) *plus* mutation-with-selection (repair-and-verify). No
previous BEAM language has the second half, because none holds the process as a
verifiable, editable value.

### 4.3 Emergence: local rules, global proof

Emergence in systems theory is **global order from local interaction with no
central controller** — a flock, an ant colony, a market. The BEAM is already an
emergence substrate: millions of processes, each following local message rules,
producing global behaviour no one process encodes.

The classic problem with emergence is that it's **opaque**: you cannot look at
the local rules and know the global behaviour (that's what "emergent" *means*).
Every complexity science reaches for simulation because the global property isn't
analytically available from the parts.

beam-lisp's unique move: because each process is a transition graph AND those
graphs compose (`system.model/system-model`, `simulates?`), you can sometimes
**prove a global property from the local rules** — `reachable-states` over the
composed system, `find-lasso` for global livelock, `all-senders-guarantee?` for
an emergent invariant. It doesn't defeat emergence (undecidability is real, and
the tools are sound-but-incomplete — they say "proven safe" or "don't know,"
never a false "safe"). But it shifts the line: **some** global order becomes
*derivable* from local rules instead of only observable. That is the systems-
theory prize — a partial bridge from local mechanism to global guarantee, built
because the parts are values, not black boxes.

### 4.4 The distilled claim

> Erlang gave the BEAM **homeostasis** — self-regulating trees that stay in a
> viable envelope. beam-lisp adds the two things biology has that OTP lacked: a
> **genome the organism can read and edit while alive** (`model` + `reload`), and
> **variation-under-selection** (`repair` + `verify`) — turning "let it crash"
> from reproduction-without-variation into **directed evolution of a running
> system**. And by keeping every process as a composable transition value, it
> makes **some emergent global order provable from local rules** — the standing
> hard problem of systems theory, cracked open a sound inch at a time.

Apoptosis, homeostasis, genome, directed evolution, provable emergence — these
are not analogies decorating a concurrency library. Each names a specific verb
that already exists in `system.core` / `system.model` / `reload`, waiting to be
composed under the maximalist supervisor.

---

## 5. What is real vs. what is design (honesty ledger)

- **Real, verified this thread:** `supervise`/`worker` restart (native);
  `defserver` gen_servers; `flow` demand tier; `system.model/graph`,
  `system.core/verify-process`/`find-lasso`/`repair-process` exist as shipped
  functions; the vitals observatory renders a live kill-and-heal.
- **Designed here, not yet built:** `defsupervisor`, `defmachine`, `defbus`,
  `defregistry`, `defsystem`, and the `super/verify` boot-time gate. Each is a
  declarative skin over primitives that already exist — the same shape as the
  `flow`→`core.async` split, where the engine was real and the surface was thin.
- **The biology (§4) is a correspondence, not a completed system.** The verbs it
  rests on (`repair-process`, `discover-invariant`, `simulates?`) are shipped;
  wiring them into an *automatic* observe→repair→inherit loop under a supervisor
  is unbuilt, and would need its own proof (a repaired process that measurably
  re-establishes an invariant a crash violated).

The honest next build is `defsupervisor` + `super/verify` over one real tree —
the smallest slice that turns "a supervisor is a value you can prove" from claim
into a green test.
