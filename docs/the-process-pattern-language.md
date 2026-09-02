# The process pattern language

> `docs/the-fundamental-form.md` established one primitive: **a process is a
> transition relation** — `state --[message / guard]--> state'`, plus an
> invariant. This document names and specifies the **patterns** that were used
> throughout the concurrency arc without ever being defined: demand, correlated
> reply, parked waiter, healing edge, governor, heartbeat, … Each is pinned to
> the part of the relation it touches, so that the seven forms (`server`,
> `machine`, `bus`, `registry`, `flow`, `supervisor`, `system`) are shown to be
> **compositions of patterns**, not primitives of their own. Patterns are the
> API design surface: every `defprocess` option, every stdlib fn in `flow`,
> `super`, `reg`, and every guarantee `system.core` can prove, should map to
> exactly one named pattern here.

Format per pattern (Alexander-style, adapted):

- **Intent** — what problem it solves, one sentence.
- **Forces** — the tensions it resolves.
- **Shape** — its expression in the relation: which of `:state`, `:on`,
  `:invariant`, `:emit`, and which *kind* of edge (state edge · composition
  edge · failure edge · observation).
- **Protocol** — the messages, as data.
- **Guarantee** — what the graph can *prove* about it (via `system.core`).
- **API** — the surface name(s). ✅ = shipped · ◐ = shipped under another name
  or hand-rolled · ○ = specified here, unbuilt.
- **Grounding** — where the arc already used it.
- **Related** — patterns it composes with or is confused with.

---

## 0. The substrate: `defprocess`

Every pattern is a constraint on this one form. Spec of the form itself, so
patterns have something concrete to attach to.

```clojure
(defprocess NAME
  {:state     INITIAL                       ; carried value — REQUIRED
   :on        {PATTERN (fn [state msg] …)   ; state edges — REQUIRED (≥1)
               …}
   :invariant (fn [state] bool)             ; must hold after EVERY edge
   :emit      (fn [state] [msgs state'])    ; outputs owed downstream
   :after     [ms (fn [state] …)]           ; the timeout edge (§1.5)
   :meta      {…}})                         ; open: patterns add keys here
```

Semantics, fixed:

1. `:on` handlers return the **next state**. A handler may return
   `[:stop reason state']` to take the terminal edge deliberately.
2. `:invariant` is checked by the verifier statically (`preserves?`) and may be
   asserted at runtime in dev; violation is a **crash** (takes the failure
   edge, §3), never a silent continue.
3. A `defprocess` **is** a `(loop [s] (receive …))` — `system.model`'s
   `extract-loop-receive` reads it identically. It compiles to a real
   `gen_server` when the Ask pattern (§1.2) is present, else to a bare process.
4. Every process has two implicit edges the author never writes:
   - **failure**: `∀s. s --[crash]--> ⊥`
   - **exit**: `s --[:stop]--> ∎` (the deliberate terminal)
   Patterns in §3 operate on the first; End-of-Stream (§2.6) on the second.

The pattern **categories** are the four things you can do with a relation:

| § | category | what it touches |
|---|---|---|
| 1 | **state patterns** | edges *within* one process |
| 2 | **composition patterns** | edges *between* processes (messages as wiring) |
| 3 | **failure patterns** | the implicit `⊥` edge and what re-enters from it |
| 4 | **observation patterns** | reading the graph without adding edges |

---

## 1. State patterns — edges within one process

### 1.1 Loop-Carried State

- **Intent.** Hold state across messages without mutation: the "state" is the
  argument of a tail-recursive loop.
- **Forces.** Immutability vs. a long-lived thing that changes; wanting the
  state to be a *value* (diffable, snapshotable) not a place.
- **Shape.** `:state`. The whole `:on` map is the loop body; every handler's
  return is the next loop argument. This IS the transition relation's node set.
- **Protocol.** None — internal.
- **Guarantee.** `reachable-states` is the set of loop arguments the graph can
  produce; `discover-invariant` mines it. Because state is a value, the
  verifier sees it *without running the process*.
- **API.** ✅ `(loop [s] (receive …))` · ✅ `defserver` · ○ `defprocess :state`.
- **Grounding.** `flow/producer-loop [gen gstate demand sub]`,
  `impl/chan-loop {:cap :buf :puts :takes :closed}`, `vitals/worker-loop [id]`.
- **Related.** every other pattern assumes it; Snapshot (§4.2) reads it.

### 1.2 Ask (call)

- **Intent.** Send a message and *wait for the answer*.
- **Forces.** Synchronous semantics on an asynchronous substrate; the caller
  must not hang forever; the answer must be *this* request's answer.
- **Shape.** A state edge whose handler also produces an `:emit` to the sender.
  In `:on`: `[:tag args from ref]`. Introduces a **reply edge** into the caller.
- **Protocol.** `caller → p : [tag payload caller ref]` then
  `p → caller : [ref result]`. `ref` per Correlated Reply (§1.4). Caller blocks
  in a Selective Receive (§1.3) on `[ref r]` with a Timeout Edge (§1.5).
- **Guarantee.** `all-senders-guarantee?` — every Ask edge has a matching
  reply on every path (no request the graph can leave unanswered).
  `deadlocked` catches two processes Asking each other.
- **API.** ✅ `gen_server/call` via `defserver` · ◐ hand-rolled in
  `impl/put!` `take!` `close!` · ○ `(ask p msg)` as the one native verb.
- **Grounding.** every `impl.bl` client op:
  `(erlang/send ch [:take me ref]) (receive [:take-done r v] …)`.
- **Related.** Tell (§1.3-dual), Correlated Reply, Timeout Edge.

### 1.3 Tell (cast)

- **Intent.** Send a message and *don't wait*.
- **Forces.** Decoupling in time; the sender must never be slowed by the
  receiver (which is exactly what makes it dangerous: see Demand §2.2).
- **Shape.** A state edge with no reply `:emit`. `[:tag args]` — no `from`.
- **Protocol.** `sender → p : [tag payload]`. Fire and forget.
- **Guarantee.** None about delivery timing — that's the point. What the
  graph can prove: the edge exists and the handler `preserves?` the
  invariant. Tell without Demand is the **unbounded mailbox** hazard; the
  verifier can flag a Tell edge whose sender has no Demand relation to `p`.
- **API.** ✅ `erlang/send` · ✅ `gen_server/cast` · ○ `(tell p msg)`.
- **Grounding.** `vitals` `[:kill-worker id]`; `flow` `[:demand n]` (Demand is
  a Tell — a demand signal must *itself* never block).
- **Related.** Ask (dual), Demand (the Tell that makes Tell safe).

### 1.4 Correlated Reply

- **Intent.** Match a reply to the exact request it answers, even when several
  are outstanding or messages arrive out of order.
- **Forces.** beam-lisp `receive` **rebinds** pattern variables — it does not
  Erlang-pin them. So `(receive [:done ref v] …)` with `ref` already bound
  matches *any* `:done`. Correlation must be explicit.
- **Shape.** Not an edge — a **label** on the Ask/reply edge pair. The
  `ref` is a fresh unique value (`erlang/make_ref`) created by the caller.
- **Protocol.** Caller creates `ref`; sends `[tag … ref]`; the receiver echoes
  it; caller matches with a guard `(when (= r ref))` or, once the runtime
  supports it, a pin `^ref`.
- **Guarantee.** With the tag threaded, the verifier can pair each Ask edge to
  its reply edge by label — the basis of `all-senders-guarantee?`. Without it
  the pairing is ambiguous and the checker must report "unpaired reply".
- **API.** ✅ `erlang/make_ref` + guard · ○ a `^pin` reader form in `receive`.
- **Grounding.** `impl.bl` every op; memory gotcha "receive REBINDS".
- **Related.** Ask, Selective Receive (the mechanism that lets the guard skip
  non-matching mail).

### 1.5 Timeout Edge

- **Intent.** Bound every wait; make "nothing arrived" a transition, not a hang.
- **Forces.** Liveness vs. a receiver that may be dead; timeouts as *edges* so
  the graph sees them; a long idle wait that is not a bug.
- **Shape.** A state edge with **no message** — labelled `[after ms]`. In
  `defprocess`: `:after [ms f]`. In `receive`: the `(after ms …)` clause.
- **Protocol.** None. Fires when the mailbox has no matching message for `ms`.
- **Guarantee.** `verify-liveness`: every receive has either an `after` edge or
  a proof that a sender must eventually send. A receive with neither is the
  graph's "may block forever" node.
- **API.** ✅ `(after ms …)` · ✅ `impl/timeout` (a channel that closes after
  ms — a Timeout Edge lifted to a value so `select` can race it).
- **Grounding.** `flow/producer-loop` `(after 3600000 …)` (long idle re-loop);
  `impl/select` races data vs `(timeout ms)`.
- **Related.** Ask (the caller's wait must carry one), Heartbeat (§4.1 —
  a periodic Timeout Edge that *does work*).

### 1.6 Selective Receive

- **Intent.** Take the message you need *now*; leave the rest queued.
- **Forces.** Protocol ordering vs. mailbox arrival order; a reply may arrive
  while unrelated Tells are queued ahead of it.
- **Shape.** Property of the `:on` map: patterns are tried against the *whole*
  mailbox in order, not just its head. The graph edge is the same; the
  runtime semantics are what let a Correlated Reply be found behind noise.
- **Protocol.** None.
- **Guarantee.** Verified in-arc: non-matching messages stay queued. Hazard the
  verifier can flag: a state whose `:on` matches *nothing* a live sender can
  send → mailbox grows unboundedly (the "forgotten message" leak).
- **API.** ✅ `receive` (native semantics).
- **Grounding.** memory episode "Selective receive works".
- **Related.** Correlated Reply, Parked Waiter (§1.7 — a queue the process
  keeps *itself* when the mailbox's selectivity isn't enough).

### 1.7 Parked Waiter

- **Intent.** When a request cannot be satisfied *yet*, remember the requester
  in state and answer it later — instead of blocking the process.
- **Forces.** A process must keep serving others while one requester waits;
  rendezvous semantics (unbuffered channel) need both sides present.
- **Shape.** `:state` gains a queue of `[from ref …]`. Two edges: the request
  edge that *parks* (`state → state+waiter`, no reply), and a later edge that
  *drains* (`state+waiter → state`, `:emit` the reply to the parked `from`).
- **Protocol.** Request as Ask; reply deferred; a **cancel** edge `[:cancel
  ref]` removes a waiter (needed for `select`, so a losing branch is
  withdrawn).
- **Guarantee.** `verify-capacity` / `synthesize-capacity`: the waiter queue
  is bounded iff the drain edge is reachable from every park edge. An
  unreachable drain = a parked requester that never returns = a leak the
  graph sees.
- **API.** ◐ `impl` `:puts`/`:takes` + `handle-cancel` · ○ `(park state
  from ref)` / `(drain state pred)` helpers in `defprocess`.
- **Grounding.** `impl/handle-put` "buffer full → block this putter";
  `handle-take` "hand a blocked putter's value directly across".
- **Related.** Ask, Selective Receive, Demand (the pull-based alternative
  that avoids parking by never over-asking).

---

## 2. Composition patterns — edges between processes

### 2.1 Pipeline

- **Intent.** Chain stages so each transforms what the previous emits.
- **Forces.** Locality (each stage knows only its upstream) vs. end-to-end
  properties (backpressure, completion) that must hold across the chain.
- **Shape.** A composition edge `p_i --[events]--> p_{i+1}`. Each stage's
  `:emit` is the next's input. The system graph is the union of stage graphs
  plus these edges.
- **Protocol.** Downstream *subscribes*: `[:subscribe consumer]`; upstream
  emits `[:events [e…]]`; and — if Demand (§2.2) is used — demand flows the
  other way.
- **Guarantee.** `simulates?`: a pipeline of stages simulates the eager
  composition of their functions (arc example `09-multi-rate` proved
  byte-identical output). Completion propagates: End-of-Stream (§2.6)
  reaches the sink.
- **API.** ✅ `flow/transform` `map-stage` `filter-stage` · ✅ `core.async`
  `pipeline` (shim, push).
- **Grounding.** `03-pipeline.bl`, `07-native-flow.bl`.
- **Related.** Demand (makes it safe), Metered Stage (§2.3, when rates differ).

### 2.2 Demand (pull)

- **Intent.** A producer may emit only what a consumer has explicitly asked
  for. Backpressure by *construction*, not by buffer size.
- **Forces.** Tell is unbounded; buffers just move the overflow; the consumer
  is the only party that knows its capacity.
- **Shape.** A **reverse composition edge** `consumer --[:demand n]-->
  producer`, plus a `demand` counter in the producer's `:state`. The producer's
  emit edge is **guarded**: `emit ⇐ demand > 0`, and each emit decrements.
  Demand is a Tell (must never block).
- **Protocol.**
  ```
  C → P : [:subscribe C]
  C → P : [:demand n]           "I can take n more"
  P → C : [:events [e…]]        |e…| ≤ outstanding demand
  P → C : [:done]               End-of-Stream
  ```
- **Guarantee.** *The producer's in-flight count never exceeds the largest
  single demand* — proven in `08-backpressure-proof` (high-water = batch).
  Statically: the emit edge's guard references the demand counter, so
  `verify-capacity` can bound the mailbox of every Demand consumer to `n`.
  A Tell edge into a process with no Demand edge is the flagged hazard.
- **API.** ✅ `flow/producer` `from-seq` `run` `run-each` (`batch` = demand
  size).
- **Grounding.** all of `flow.bl`; "THAT quiet is the backpressure".
- **Related.** Tell, Pipeline, Metered Stage, Fan-Out (demand splits).

### 2.3 Metered Stage (demand arithmetic)

- **Intent.** Keep the Demand contract when a stage's input:output rate is not
  1:1 (flatMap expands, filter contracts).
- **Forces.** Forwarding demand 1:1 through a ×3 expansion emits 3× the
  promise; through a filter it starves. Demand must be *computed*, not
  relayed.
- **Shape.** `:state` = `{:buf :want :up-out :done?}` — undelivered outputs,
  outstanding downstream demand, outstanding upstream demand, upstream
  finished. Two guarded emit edges: *deliver from buffer* (`want > 0 ∧ buf
  ≠ ∅`) and *pull upstream* (`want > |buf| ∧ up-out = 0 ∧ ¬done?`).
- **Protocol.** Same as Demand on both sides; the stage owns the arithmetic.
- **Guarantee.** Two invariants the verifier checks with `preserves?`:
  (a) `delivered ≤ want` always (never overrun), (b) if `¬done?` and
  `want > 0` then a pull edge is enabled (never starve). `09-multi-rate`
  proved both empirically (15 evens, byte-identical).
- **API.** ✅ `flow/flat-transform` `expand-stage` `mapcat-stage`.
- **Grounding.** the `MULTI-RATE stage` block in `flow.bl`.
- **Related.** Demand, Pipeline, Parked Waiter (buffer of *outputs* instead of
  *requesters*).

### 2.4 Fan-Out

- **Intent.** One source, many consumers.
- **Forces.** *Broadcast* (every consumer sees every event) vs. *distribute*
  (each event goes to exactly one consumer — a work pool). Slowest-consumer
  problem under broadcast.
- **Shape.** One producer with N composition edges. Broadcast: the emit edge
  is replicated. Distribute: the emit edge is guarded by *which consumer has
  demand*, and each event takes exactly one edge.
- **Protocol.** Broadcast under Demand: producer emits `min(demand_i)` to all
  (slowest consumer sets the pace — this is the gen_event fix). Distribute
  under Demand: event goes to any consumer with `demand_i > 0`.
- **Guarantee.** Broadcast: no consumer overrun (from Demand). Distribute:
  each event delivered exactly once — an `:emit` edge with N targets and a
  `one-of` guard; `simulates?` against the sequential fold.
- **API.** ◐ `core.async` `mult`/`pub` (shim) · ◐ `vitals` shared-atom job
  pull (distribute, hand-rolled) · ○ `flow/broadcast` `flow/distribute`.
- **Grounding.** `05-fan-in-out.bl`; `vitals` "a real shared-atom pull, the
  fan-out pattern".
- **Related.** Demand, Fan-In, Bus (= Fan-Out broadcast + Demand).

### 2.5 Fan-In

- **Intent.** Many sources, one consumer.
- **Forces.** Fairness among sources; a consumer's single demand must be
  apportioned; completion only when *all* sources are done.
- **Shape.** N composition edges into one process. `:state` tracks per-source
  outstanding demand and done-flags. Emit-to-downstream is a merge.
- **Protocol.** Consumer demand `n` is split across live sources (round-robin
  or by availability); `[:done]` from a source marks it; overall End-of-Stream
  when all marked.
- **Guarantee.** Total in-flight ≤ downstream demand (sum of per-source
  allocations = `n`). Completion is correct: verifier checks the sink's done
  edge is reachable only from the all-done state.
- **API.** ◐ `core.async` `merge` (shim) · ○ `flow/merge`.
- **Grounding.** `05-fan-in-out.bl`.
- **Related.** Fan-Out, End-of-Stream, Demand.

### 2.6 End-of-Stream

- **Intent.** Say "there will be no more" so downstream can finish, and make
  that a first-class edge.
- **Forces.** Finite streams; a consumer blocked on demand must be released;
  distinguishing "quiet because backpressured" from "quiet because finished".
- **Shape.** The deliberate terminal edge `s --[:done]--> ∎` on the producer,
  and a matching input edge on every consumer. In a Metered Stage the
  `:done?` flag lets the buffer *outlive* the message and drain on later
  demand.
- **Protocol.** `P → C : [:done]`. A channel's `close!` is the same edge under
  the push model (`:closed true` then takes drain then return `nil`).
- **Guarantee.** `verify-liveness`: every consumer's wait has a path to
  `[:done]` or an `after`. Every stage must forward `:done` (the verifier
  flags a stage with an input `:done` edge and no output `:done` edge —
  the "swallowed completion" bug).
- **API.** ✅ `flow` `[:done]` · ✅ `impl/close!`.
- **Grounding.** `flow` "upstream exhausted → flush what remains";
  `impl/handle-close`.
- **Related.** Timeout Edge (the *other* way a wait ends), Fan-In.

### 2.7 Registry

- **Intent.** Find a process by a name that survives its restarts.
- **Forces.** Pids die with the process; callers must not hold them; lookup
  must be cheap and, ideally, a *query* (find all sessions on node X).
- **Shape.** A process whose `:state` is a relation `name → pid` (or richer:
  `{:name :pid :node :attrs}`); Ask edges `[:register name pid]`,
  `[:lookup name]`; and — crucially — a **Monitor** edge (§3.1) on every
  registered pid so entries auto-retract on death.
- **Protocol.** `[:register name pid from ref] → [ref :ok | :taken]`;
  `[:whereis name from ref] → [ref pid | nil]`; internal
  `[:DOWN _ :process pid _] → retract`.
- **Guarantee.** Invariant: `∀ entry. alive?(pid)` — preserved by the
  `:DOWN` edge; the verifier checks that every register edge has the monitor
  established (a register edge without a `:DOWN` handler is a stale-entry
  leak). Backed by datom, lookup is `q` — so "all pids whose node died" is
  the same query language as reachability.
- **API.** ◐ `vitals` `registry` atom + supervisor `:DOWN` · ○ `defregistry`
  / `reg/register` `reg/whereis` `reg/where` (datalog).
- **Grounding.** `vitals.bl` "The registry: process-name → pid".
- **Related.** Monitor, Ask, Healing Edge (the restarted pid re-registers).

---

## 3. Failure patterns — the `⊥` edge and what re-enters from it

Every process has `∀s. s --[crash]--> ⊥`. These patterns are the only ones
that add edges *out of* `⊥`.

### 3.1 Monitor (failure as data)

- **Intent.** Learn that another process died — as a *message*, without dying
  yourself.
- **Forces.** Observation must not couple fates; the observer needs the
  *reason*; monitors must be established by the process that will handle
  the `:DOWN` (they are per-observer).
- **Shape.** An **observation edge** from `q` to `p`'s `⊥`: when `p` takes
  `⊥`, an input edge `[:DOWN ref :process pid reason]` fires in `q`. Adds
  nothing to `p`'s graph; adds one input edge to `q`'s.
- **Protocol.** `(erlang/monitor :process pid) → ref`; later
  `[:DOWN ref :process pid reason]` arrives in the monitoring process's
  mailbox. Exactly once.
- **Guarantee.** `q`'s `:on` must handle `:DOWN` in every state where a
  monitor is outstanding, else the message leaks (Selective Receive hazard).
  The verifier: "every `monitor` call site is dominated by a `:DOWN` handler".
- **API.** ✅ `erlang/monitor` · ✅ `spawn-monitor` (ward).
- **Grounding.** `fence.bl` one-shot; `ward` per test; `vitals` supervisor.
- **Related.** Link (the coupled dual), Healing Edge (what a supervisor does
  *with* the `:DOWN`), Bounded Isolation.

### 3.2 Link (failure as propagation)

- **Intent.** Couple fates: if you die, I die too.
- **Forces.** Some processes are meaningless without each other (a
  connection and its reader); cleanup by propagation is simpler than by
  message; but propagation is *unconditional* and can cascade.
- **Shape.** A bidirectional edge between `p.⊥` and `q.⊥`: taking one takes
  the other. Unless `q` **traps exits**, in which case it degrades to Monitor
  (an `[:EXIT pid reason]` input edge instead).
- **Protocol.** `(erlang/link pid)`; on death the linked process exits with
  the same reason, or receives `[:EXIT pid reason]` if trapping.
- **Guarantee.** The verifier can compute the **link closure**: the set of
  processes one crash takes down. A supervisor's children must not be
  link-closed to each other unless the strategy is `one-for-all` (else the
  restart policy and the link topology disagree — a flaggable inconsistency).
- **API.** ✅ `erlang/link` · ✅ `spawn_link` · `defprocess :meta {:trap-exit
  true}` ○.
- **Grounding.** OTP internals of `supervise`; `staying-alive` doc §links.
- **Related.** Monitor, Healing Edge, Governor.

### 3.3 Healing Edge (restart)

- **Intent.** Return from `⊥` to a known-good state.
- **Forces.** A fresh state beats an unknown-bad one ("let it crash");
  restarting must not resurrect the *cause*; the restarted process has a new
  pid — every holder of the old one is now wrong (→ Registry).
- **Shape.** The supervisor adds `child.⊥ --[restart]--> child.s0` to the
  child's graph. **Strategy** = which siblings' healing edges fire together:
  `one-for-one` (only the dead one), `one-for-all` (every sibling's `s →
  ⊥ → s0`), `rest-for-one` (the dead one and all started after it).
- **Protocol.** Supervisor receives Monitor/Link failure; spawns the child's
  start fn; re-monitors; (if Registry) the child re-registers.
- **Guarantee.** *Restart re-establishes the invariant*: `establishes?`
  on the start fn — `s0 ⊨ invariant`. And the **cross-form** guarantee only a
  whole-graph query can express: under `one-for-all`, no sibling's `s0` is a
  state another sibling's invariant forbids.
- **API.** ✅ `supervise` `worker` (native) · ◐ hand-rolled `vitals` sup ·
  ○ `defsupervisor` with `:strategy`.
- **Grounding.** `examples/supervision.bl`; `vitals` "turns a :DOWN into a
  fresh pid" (pid 777 → 781, observed).
- **Related.** Monitor, Governor (bounds this edge), Registry (fixes the
  stale-pid problem it creates).

### 3.4 Governor (restart intensity / escalation)

- **Intent.** Stop restarting when restarting isn't fixing it; hand the
  failure to a level with more scope.
- **Forces.** A healing edge with no bound is a livelock (crash-restart-crash
  forever); the right responder for a systemic failure is *higher* in the
  tree; local knowledge can't tell "flaky" from "broken" — only frequency can.
- **Shape.** A **guard on the healing edge**: `restart ⇐ count(⊥→s0 in last
  T) < N`. When the guard fails, the supervisor takes *its own* `⊥` — the
  failure edge propagates one level up, where the parent's Healing Edge
  restarts the whole subtree from `s0`.
- **Protocol.** None external; internal counter in supervisor `:state`.
  Escalation = the supervisor's own exit with reason `:shutdown`/
  `:max-restarts`.
- **Guarantee.** `find-lasso` on the child graph: a reachable cycle through
  `⊥` with no path out = a guaranteed Governor trip. The verifier reports it
  *before boot*: "this child will exhaust its restart budget". This is the
  `{:liveness :bounded}` field in the maximalist supervisor design.
- **API.** ✅ OTP `max_restarts`/`max_seconds` under `supervise` · ○
  `defsupervisor :intensity [n t]`.
- **Grounding.** `staying-alive` "restart intensity = escalation"; the
  cybernetic *governor* framing.
- **Related.** Healing Edge (what it guards), Link (how escalation propagates).

### 3.5 Bounded Isolation (fence)

- **Intent.** Run untrusted or possibly-hanging work so that its crash or hang
  becomes a *value* to the caller — a one-shot, not a supervised service.
- **Forces.** Isolation (its crash must not be mine) + a bound (it must not
  hang me) + a result (I want its value, or its failure as data).
- **Shape.** Spawn a fresh process (own graph); Monitor it; Ask it with a
  Timeout Edge; collapse three outcomes into one value: `{:ok v}` /
  `{:crash reason}` / `{:timeout}`. It composes Monitor + Ask + Timeout
  Edge into a single **function** — the process is an implementation detail.
- **Protocol.** `spawn-monitor f` → wait `[ref v] | [:DOWN …] | after ms`.
- **Guarantee.** Termination of the *caller* is unconditional (the after
  edge). The verifier can prove a fence never leaks the monitor (every
  branch demonitors/flushes) — the classic bug in hand-rolled fences.
- **API.** ✅ `ward` (per test) · ◐ `spell/fence.bl` (hand-rolled) · ○
  `(fence f ms)` in stdlib so both stop hand-rolling it.
- **Grounding.** `fence.bl` `mon (erlang/monitor :process pid)` + `[:DOWN _
  :process _ reason]`; ward's isolated forks.
- **Related.** Monitor, Ask, Timeout Edge. **Not** Healing Edge — a fence
  never restarts; that distinction is why spell doesn't need a supervisor.

---

## 4. Observation patterns — reading the graph without adding edges

### 4.1 Heartbeat

- **Intent.** Prove a process is *alive and progressing*, not merely
  existing (a wedged process is alive by `Process/alive?` and dead by any
  useful measure).
- **Forces.** Liveness is not existence; polling is cheap but must not
  perturb; the signal must be a *value* others can query.
- **Shape.** A periodic Timeout Edge (`:after [ms work]`) that does work
  **and** records a tick (`:emit` a beat, or bump a counter readable by
  Snapshot). Observed as `ticks(t2) > ticks(t1)`.
- **Protocol.** Either push (`[:beat id t]` to an observer) or pull (observer
  reads `ticks` via Snapshot). The arc chose pull — passive, no perturbation.
- **Guarantee.** A process with an `:after` work edge whose `ticks` is not
  monotone between two snapshots is **wedged** — a runtime fact no static
  check gives, and the *complement* of `find-lasso` (static livelock vs.
  observed stall).
- **API.** ◐ `vitals` `worker-loop` sleep+tick · ○ `defprocess :after` +
  `vitals/beating?`.
- **Grounding.** `vitals` "heartbeat = did this worker do work since the last
  frame?"
- **Related.** Timeout Edge, Snapshot, Governor (a stalled heartbeat is what
  a *liveness-aware* supervisor would restart on — beyond OTP).

### 4.2 Snapshot (passive introspection)

- **Intent.** Read a running process's vitals as data without sending it a
  message.
- **Forces.** Observation must not change the observed (an Ask would consume
  scheduler time and mailbox order); the VM already exposes mailbox length,
  memory, reductions, links, monitors.
- **Shape.** No edge. A **read** of the VM's view: `erlang/process_info` →
  `{:message_queue_len :memory :reductions :links :monitors :status}`. Fed
  into the same datom the graph lives in, so observed facts and structural
  facts are one relation.
- **Protocol.** None — passive.
- **Guarantee.** Enables *runtime* checking of static claims: Demand's
  "mailbox ≤ n" is a `:message_queue_len` read; Parked Waiter's bound is a
  memory read. A `:message_queue_len` that grows across snapshots on a
  process with no Demand edge is the unbounded-Tell hazard, *observed*.
- **API.** ✅ `erlang/process_info` · ◐ `vitals/pid-vitals` · ○
  `vitals/snapshot` as a stdlib fn returning datoms.
- **Grounding.** `vitals.bl` "process_info is a passive read".
- **Related.** Heartbeat, Invariant Gate (static counterpart).

### 4.3 Invariant Gate (verify before boot)

- **Intent.** Refuse to start a process/tree whose graph provably violates a
  property.
- **Forces.** Crashing at boot is cheap; crashing in production is not; the
  graph is available *before* any process exists, so check it then.
- **Shape.** No edge. A function over the graph, run by the starter:
  `(verify graph) → :ok | {:unsafe what why}`. Composes the shipped verbs:
  `establishes?` (s0 ⊨ inv), `preserves?` (every edge keeps inv),
  `deadlocked` (no state without an out-edge unless terminal),
  `find-lasso` (no unbounded restart cycle), `all-senders-guarantee?`
  (every Ask answered), `verify-capacity` (bounded queues).
- **Protocol.** None. The gate runs in the *starting* process, before spawn.
- **Guarantee.** Whatever the composed verbs prove. The **whole-graph**
  guarantees (the ones spanning process + supervisor + sibling) are only
  expressible here, because only here is the union graph in hand.
- **API.** ✅ `system.core/verify-process` (single) · ○ `super/verify` /
  `system/verify` (tree) · ○ `defsystem` runs it in `start`.
- **Grounding.** `the-maximalist-supervisor.md` "verify the tree before
  boot"; `system/core` verbs.
- **Related.** every §1–3 pattern's *Guarantee* line is a clause of this
  gate; Snapshot is its runtime twin.

### 4.4 Simulation (equivalence to the eager program)

- **Intent.** Prove a concurrent composition computes the same thing as its
  sequential meaning.
- **Forces.** Concurrency should be an *implementation strategy*, not a
  semantic change; the eager fold is the spec.
- **Shape.** No edge. `simulates?` between the pipeline's union graph and the
  eager function; empirically, run both and compare outputs.
- **Protocol.** None.
- **Guarantee.** The arc's strongest empirical result: `09-multi-rate`
  byte-identical to eager; `08-backpressure-proof` bounded in-flight. The
  static verb `simulates?` is shipped; wiring it to a pipeline is unbuilt.
- **API.** ✅ `system.core/simulates?` · ○ `flow/check` (run + compare).
- **Grounding.** `08`, `09` examples.
- **Related.** Pipeline, Metered Stage, Invariant Gate.

---

## 5. The seven forms as pattern compositions

This is the payoff for API design: each form is a *named bundle*, and the
bundle is the spec. Nothing in a form is not a pattern above.

| form | = patterns |
|---|---|
| **server** | Loop-Carried State + Ask + Tell + Correlated Reply + Timeout Edge |
| **machine** | Loop-Carried State (enum) + Invariant Gate (reachability of bad states) |
| **bus** | Fan-Out (broadcast) + Demand + End-of-Stream |
| **registry** | Loop-Carried State (relation) + Ask + Monitor (auto-retract) |
| **flow** | Pipeline + Demand + Metered Stage + Fan-In/Out + End-of-Stream + Simulation |
| **supervisor** | Monitor (or Link) + Healing Edge + Governor + Invariant Gate |
| **system** | union of the above + Invariant Gate over the union + Snapshot/Heartbeat feed |
| **fence** *(the eighth "form" that turned out to be a function)* | Monitor + Ask + Timeout Edge |

Two consequences for the API:

1. **Every stdlib fn names one pattern.** `flow/producer` is Demand;
   `flow/flat-transform` is Metered Stage; `super/verify` is Invariant Gate;
   `(fence f ms)` is Bounded Isolation. If a proposed fn does two, split it.
2. **Every guarantee is a pattern's Guarantee line.** The verifier's error
   messages should name the pattern: *"Tell edge into `p` with no Demand
   relation — unbounded mailbox"*, *"Healing Edge for `w` has a lasso through
   ⊥ — Governor will trip"*, *"monitor at line N not dominated by a :DOWN
   handler"*. The pattern name is the diagnosis.

---

## 6. Build status ledger

| pattern | status |
|---|---|
| Loop-Carried State, Ask, Tell, Selective Receive, Timeout Edge | ✅ native |
| Correlated Reply | ✅ via `make_ref` + guard; ○ `^pin` |
| Parked Waiter | ◐ in `impl.bl`; ○ `defprocess` helpers |
| Pipeline, Demand, Metered Stage, End-of-Stream | ✅ `flow.bl` |
| Fan-Out, Fan-In | ◐ shim + hand-rolled; ○ `flow/broadcast` `distribute` `merge` |
| Registry | ◐ `vitals` atom; ○ `defregistry` on datom |
| Monitor, Link | ✅ native |
| Healing Edge | ✅ `supervise`; ○ `defsupervisor` |
| Governor | ✅ OTP intensity; ○ `find-lasso` pre-check wired in |
| Bounded Isolation | ◐ `ward`, `fence.bl`; ○ stdlib `fence` |
| Heartbeat, Snapshot | ◐ `vitals.bl`; ○ stdlib fns |
| Invariant Gate | ✅ per-process; ○ per-tree |
| Simulation | ✅ verb; ○ wired to `flow` |

**Honest next slice (unchanged from the-fundamental-form.md, now precise):**
`defprocess` with `:state :on :invariant :after`; lower `defserver` to it;
`(fence f ms)` in stdlib (kills two hand-rolled copies in spell); and
`super/verify` composing the §4.3 verbs over one two-worker tree — the
smallest set that makes §5's "every fn names one pattern" true in code.
