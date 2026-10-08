# 07 — Gossip & SWIM: spreading facts and finding the dead, without a coordinator

Spread one fact to every node in O(log N) rounds with no bottleneck, and decide a
node is dead only when it is unreachable from *several* independent vantage
points — so a single dropped packet never kills a healthy node.

This is the tutorial for `research/fleet_spike/07_gossip_swim.bl`. It implements
two mechanisms that travel together in a real fleet: **anti-entropy gossip**
(how a fact reaches everyone) and **SWIM failure detection** (how everyone
agrees who is gone). Read [`../README.md`](../README.md) first for the
"consistency chosen per data class" model that organizes the whole suite — this
spike is the plumbing that carries several of those classes.

---

## The problem

A fleet has facts that need to reach *every* node — a new route, a config
change, a health update. And it has a question that must be answered *everywhere,
the same way*: who is alive?

### Spreading a fact without a broadcast

Take 8 nodes. Node 0 learns one new fact, `:route-web`, and every node must know
it. The naive answers are both bad:

- **One central broadcaster.** Node 0 sends the fact to the other 7. That works
  — until node 0 is the node that dies, or is slow, or is the one under load.
  One node carries O(N) work and is a single point of failure: if it falls over
  mid-broadcast, the fact dies with it. This is the shape we are trying to
  *escape*, so reintroducing a coordinator to *disseminate* defeats the point.
- **Everyone tells everyone.** Each node periodically messages all N−1 others.
  That is O(N²) messages per round — fine for 8 nodes, ruinous for 8,000. And it
  burns the network to say "nothing changed" N² times.

Packet loss makes it worse. Any scheme that says "I sent it once, so it landed"
is wrong on a network that drops packets. You need delivery that is robust to
loss, duplication, and reordering *for free*.

### Deciding a node is dead without false alarms

The naive failure detector: *"if I miss one heartbeat from node T, T is dead."*

One dropped packet → T declared dead. But T is fine; the packet wasn't. In a
fleet, a false death is not a cosmetic error — it triggers rescheduling,
rebalancing, and data movement, which piles load onto the surviving nodes, which
makes *them* look slow, which can cascade into more false deaths. A detector
that cries wolf is worse than none.

The bug in the naive rule is a conflation: **a failed ping tells you the *path*
failed, not the *node*.** T may be perfectly healthy behind a link that happens
to be lossy *from the prober* (congested NIC, a bad route, a GC pause — anything
asymmetric). Declaring death from one vantage point treats "I can't reach T" as
"nobody can reach T" — which is exactly what let those 7 messages above become a
single point of failure in the first place.

---

## The idea

### Gossip: tell one random peer everything you know

Forget broadcast. Instead, run an **epidemic**:

> Each round, every node picks **one** random peer and they exchange state,
> each taking the **union** of what both knew.

That is anti-entropy gossip. Information spreads like a disease: node 0 is
"infected" with `:route-web`, it infects one peer, now two nodes are infected,
they infect two more, and so on. The infected set roughly **doubles each round**,
so it takes about **log₂ N** rounds to infect everyone.

```
8 nodes, node 0 infected:
round 1: 1 → 2 infected        (×2)
round 2: 2 → 4
round 3: 4 → 8   ✓ all know it     ~ log₂ 8 = 3 rounds
```

Two properties fall out of this that no broadcast has:

- **No bottleneck, no single point of failure.** Every node sends to exactly one
  peer per round. Load is flat, and there is no node whose death stops the
  spread — if node 0 dies right after round 1, the two infected nodes carry on.
- **Loss, duplication, reordering are all harmless.** Because the merge is a set
  **union**, receiving the same fact twice changes nothing, and missing a round
  just means you catch it next round. Gossip needs no acks, no ordering, no
  retries. That is the CRDT property from spike `02` doing the work: gossip's
  payload is *any* join-semilattice state, and union is the simplest one.

```
union is: commutative  (A∪B = B∪A)      → order of messages doesn't matter
          associative  ((A∪B)∪C = A∪(B∪C)) → grouping doesn't matter
          idempotent   (A∪A = A)         → duplicates don't matter
          monotonic    (A ⊆ A∪B)         → you never lose a fact you had
∴ final state = union of all facts ever injected, regardless of delivery
```

### SWIM: a failed ping means "ask someone else"

For failure detection, separate the two questions the naive rule smooshes
together:

- "Can **I** reach T?" — a fact about your *link*.
- "Can **anyone** reach T?" — a fact about the *node*.

SWIM (Scalable Weakly-consistent Infection-style process group Membership) turns
the first into evidence for the second, carefully:

```
prober P wants to check T:
  1. direct ping to T
     ack? ────────────────────────────→ T alive     (:via :direct)
     no ack ↓
  2. indirect probe: ask k other members to ping T on P's behalf
     any of them ack? ─────────────────→ T alive     (:via :indirect)
     none ack ↓
  3. T is dead                        (:status :dead, :via :none)
```

The insight: **a single failed ping is evidence about a path, not about a node.**
Before concluding T is dead, cross-check from other vantage points. If *anyone*
can reach T, then T is alive and it is P's link that is broken — no false death.
Only when P's direct probe **and** all k independent indirect probes fail do we
declare T dead.

Under independent per-probe loss `p`, the false-death probability collapses:

```
naive:  P(false dead) = p            (one lost packet)
SWIM:   P(false dead) = p · pᵏ = pᵏ⁺¹   (direct AND all k indirect lost)
```

With `p = 0.1` and `k = 3`, that is `0.1⁴ = 0.0001` — a 10,000× drop in false
alarms. SWIM also does this *cheaply*: the indirect probes are delegated to other
members (who send a single extra ping), so no node monitors all others, and the
whole thing stays O(N) probes, not O(N²). In the full algorithm the same pings
piggyback membership updates (infection-style dissemination) — gossip and SWIM
are one protocol in production.

---

## How it works

### Gossip: the invariant and why it converges

Each node holds a **set of known facts**. The only operation is union; nothing is
ever removed. That single constraint — **monotonicity** — is the whole
correctness story:

- `merge(A, B) = A ∪ B` is a **join** on the lattice of sets (the join-semilattice
  argument from `02_gset_crdt.bl`). Join is commutative, associative, idempotent.
- ∴ the system converges to a **unique** fixed point — the union of every fact
  ever injected anywhere — no matter the delivery order, duplicates, or dropped
  rounds. You cannot get a wrong answer from a lost message; you can only get a
  *late* one, and the next round fixes that.

**Progress** (as opposed to safety) is probabilistic: at each round, an uninformed
node is missed with some probability < 1, and the *number* of informed nodes
roughly doubles, so the expected time to full infection is O(log N) rounds.
That is the entire reason gossip scales: N nodes, log N latency, constant work
per node per round.

Note what gossip can *not* do: it cannot enforce a single truth. Union converges,
but it converges to whatever everyone injected — two conflicting facts both
survive as two members of the set. That is fine for events, routes, and health
(where *any* convergent answer is acceptable — the README's AP classes) and
*fatal* for desired state ("billing runs here"), which is why desired state gets
Raft in `06_raft.bl` and is never gossiped. Gossip is the wrong hammer for a
class where conflicting truths must not coexist.

### SWIM: the law and why it removes false positives

The law the detector maintains:

> Declare T dead **only** when T is unreachable from k+1 independent vantage
> points (the prober plus k delegates).

A false positive therefore requires a *correlated* failure of every probe, which
for independent losses has probability `pᵏ⁺¹` instead of `p`. The cost is
asymmetric and deliberately so: one extra probe round of latency to confirm a
death, in exchange for eliminating the churn that false deaths cause.

The probe results must be **independent** to get that `pᵏ⁺¹` — if all k delegates
share the prober's broken link, you have one vantage point pretending to be
k+1. Real SWIM picks the k delegates at random, which makes correlated failure
unlikely; the spike passes the indirect results in directly so the arithmetic is
visible.

---

## Walkthrough

Every line below is quoted from `07_gossip_swim.bl`. The spike prints three
stages: the gossip run, three SWIM verdicts, and the PASS/FAIL line.

### Stage 1 — the fleet model

```clojure
(def N 8)
(defn peer-of [node round]
  (let [p (rem (erlang/phash2 [node round] 1000000) N)]
    (if (= p node) (rem (inc p) N) p)))            ; never self
```

`N` is the fleet size. `peer-of` picks this round's gossip target for a node.
Real gossip uses a *random* peer; here `erlang/phash2` (Erlang's deterministic
hash) gives a pseudo-random but **reproducible** choice from `[node round]`, so
the spike prints the same number every run and the test is not flaky. The `if`
guarantees a node never gossips to itself — that would be a round that
disseminates nothing.

### Stage 2 — one gossip round

```clojure
(defn gossip-round [states round]
  ;; each node pushes its state to one peer; peer unions it in (push gossip)
  (reduce (fn [st node]
            (let [peer (peer-of node round)]
              (update st peer (fn [s] (clojure.set/union s (get st node))))))
          states (range N)))
```

`states` is a map `node → set-of-facts`. The `reduce` visits every node and has
it **push** its current facts to its chosen peer, which **unions them in** — a
push-gossip round.

Two things worth noticing:

- The merge is `clojure.set/union`, i.e. the CRDT join. Delivering the same fact
  twice is a no-op, and a node that receives from two senders in a round just
  ends up with the union of both — no ordering, no conflict resolution needed.
- The `reduce` **threads `st` through the fold**, so a peer updated at step *i*
  is visible when the fold later reaches that peer's own turn at step *j > i*.
  Information can therefore hop more than once in a single round. It only ever
  speeds things up; it does not break the union invariant.

### Stage 3 — when is everybody done?

```clojure
(defn all-know? [states fact]
  (every? (fn [node] (contains? (get states node) fact)) (range N)))
```

The stopping condition: every node's set contains the fact. `every?` over all N
nodes, `contains?` on the set — O(N) per check, run once per round.

### Stage 4 — seed the epidemic

```clojure
;; node 0 starts knowing :route-web; everyone else empty
(def init (into {} (map (fn [i] [i (if (= i 0) #{:route-web} #{})]) (range N))))
```

Only node 0 knows `:route-web`. This is the worst case for dissemination (a
single infected node) and so the honest test of how fast gossip covers the fleet.

### Stage 5 — run until infected (or give up)

```clojure
(def rounds
  (loop [st init r 0]
    (if (or (all-know? st :route-web) (> r 20))
      r
      (recur (gossip-round st (inc r)) (inc r)))))
```

`loop`/`recur` counts rounds until `all-know?` fires, with a hard cap of 20 so a
broken merge can't spin forever. `rounds` is the answer the spike reports and
asserts on.

### Stage 6 — print the gossip result

```clojure
(println "── anti-entropy gossip (8 nodes, push) ──")
(println (str "  fact :route-web reached all " N " nodes in " rounds " rounds  (~log2 N = "
              (erlang/round (/ (erlang/apply :math :log (list N)) (erlang/apply :math :log (list 2)))) ")"))
```

The second line reports the measured `rounds` alongside `~log2 N = 3` — computed
right there with `math:log(N)/math:log(2)`, rounded — so you can see the observed
latency against the log-bound the theory promises.

### Stage 7 — the SWIM prober

```clojure
(defn ping [alive? target] (alive? target))

(defn swim-check [target direct-ok? indirect-oks k]
  ;; direct probe; on failure, k indirect probes via other members
  (if direct-ok?
    {:status :alive :via :direct}
    (let [acked (some identity (take k indirect-oks))]
      (if acked
        {:status :alive :via :indirect}          ; someone reached it ⇒ not dead
        {:status :dead  :via :none}))))            ; nobody reached it ⇒ dead
```

`swim-check` is the detection decision as a **pure function** — no timers, no
state, just: a direct probe result, k indirect probe results, and a verdict.

- `direct-ok?` true ⇒ `{:status :alive :via :direct}`. Done; no indirect probes
  needed.
- otherwise look at the indirect results: `(some identity (take k indirect-oks))`
  is true iff **at least one** of the first k probes acked (a delegate reached T,
  so T is alive and the prober's link was the problem) ⇒
  `{:status :alive :via :indirect}`.
- none acked ⇒ `{:status :dead :via :none}`.

### Stage 8 — the three cases

```clojure
;; case A: target healthy — direct ack
(def healthy (swim-check "n7" true [] 3))
;; case B: target behind ONE lossy link to the prober, but reachable by others.
;; naive detector would false-positive; SWIM's indirect probes save it.
(def lossy (swim-check "n7" false [false true false] 3))
;; case C: target genuinely dead — direct fails AND all indirect fail
(def dead (swim-check "n7" false [false false false] 3))
```

- **A — healthy.** Direct ping answered: `{:status :alive :via :direct}`.
- **B — prober's link is lossy.** Direct ping fails, *but* indirect probe #2
  reaches `n7`. Verdict: alive via indirect. This is the exact scenario a naive
  "one missed heartbeat ⇒ dead" detector gets **wrong**; SWIM gets it right. Note
  case B deliberately has a `true` in the *middle* of the list — the code must
  scan, not just look at the first result.
- **C — genuinely dead.** Direct fails and all three indirect fail: nobody can
  reach `n7`, so it really is gone: `{:status :dead :via :none}`.

### Stage 9 — the assertions

```clojure
(def ok (and (<= rounds 12)                      ; gossip converges fast (O(log N)-ish)
             (= :alive (:status healthy))
             (= :alive (:status lossy))          ; SWIM avoids the false positive
             (= :indirect (:via lossy))          ; ...specifically via indirect probe
             (= :dead (:status dead))))          ; only declares dead when truly unreachable
(println "")
(println (str (if ok "PASS" "FAIL") " 07_gossip_swim  (gossip spreads in O(log N); SWIM avoids false deaths)"))
```

The four claims, each checked:

1. `rounds ≤ 12` — gossip converged well inside the O(log N)-ish budget (log₂8 = 3;
   the cap of 12 leaves generous headroom for a particular hash seed).
2. `healthy` is `:alive` — a healthy node is not misreported.
3. `lossy` is `:alive` **and** `:via :indirect` — SWIM's whole reason for existing:
   it avoided the false death, and specifically *because* it used the indirect
   probes (not by luck).
4. `dead` is `:dead` — and only then is death declared.

All four ⇒ `PASS`.

---

## Where it fits the fleet

In the README's per-data-class model, this spike owns the row **membership /
health** and the *transport* that all the AP classes ride on:

| data class | algorithm | this spike's role |
|---|---|---|
| **membership / health** | LWW-Register + gossip/SWIM | SWIM decides alive/dead; gossip disseminates the verdict |
| **events** (G-Set) | `02_gset_crdt.bl` | gossip carries the G-Set; its merge *is* the union here |
| **routes / claims** (OR-Set) | `03_orset.bl` | gossip carries OR-Set deltas to every node |
| **desired state** | Raft (`06_raft.bl`) | **not** gossiped — needs one agreed truth, not a convergent set |

**Why this algorithm and not another, for these classes.** Membership and health
are *AP* data: under a partition you want every node to keep operating and to
converge once healed, not to block on a majority. Gossip gives exactly that —
always available, eventually consistent, no coordinator. The alternative, a
central health-monitor or a broadcast tree, is the single point of failure we
set out to eliminate. And the *choice to diffuse via CRDT merge* (rather than
ack'd reliable delivery) is what makes gossip robust for free: union is
idempotent and commutative, so packet loss and reordering cost latency, never
correctness.

**The boundary with Raft is the sharp one.** The README draws it explicitly:
desired state is the *one* class where a convergent-but-conflicting answer is
*wrong* — "billing runs here" on two nodes must not silently merge. So that
class gets Raft (`06_raft.bl`), whose commit-by-majority and split-brain refusal
give one agreed truth — and it is deliberately *not* gossiped. Membership is the
opposite: a node's own liveness is a fact the fleet wants to learn **fast and
loss-tolerantly**, so LWW (`04_lww.bl`) gives it a deterministic last-writer-wins
value and gossip/SWIM gets it to everyone. Causality questions (did event X
happen-before Y?) belong to vector clocks (`05_vector_clocks.bl`); placement
(which node owns a key) belongs to consistent hashing (`01_sharding.bl`).

The two mechanisms in this spike are the same protocol in production: SWIM's
pings *carry* gossip payloads, so one message both checks liveness and spreads
the latest membership view. The spike keeps them as two visible pieces so the
mechanism of each is unobstructed.

---

## What's real vs modelled

**Real, and really asserted:**

- The anti-entropy gossip mechanism is implemented as written: each node pushes
  its fact-set to one peer per round, the peer takes the **union**. The
  convergence property is *measured* — the spike counts rounds until every node
  knows the fact and asserts `rounds ≤ 12`.
- The SWIM detection decision is implemented as a pure state function: direct
  probe, then k indirect probes, "any ack ⇒ alive else dead". Its defining
  property — **no false death behind one lossy link** — is asserted, and asserted
  *specifically* as `:via :indirect`, so the test proves the indirect path did
  the work rather than the scenario accidentally passing.

**Modelled / simplified (the honest boundary):**

- **In-process simulation.** Nodes are integer keys `0..N-1` in a map, not
  processes; a "message" is a function call; a "round" is a fold, not wall-clock
  time. There are no sockets. In production the transport is **BEAM messaging**
  (location-transparent sends and monitors between processes) — that transport is
  exactly what is *not* under test here.
- **Deterministic peer choice.** `erlang/phash2` stands in for real randomness so
  runs are reproducible; production would use `rand`, making dissemination
  probabilistic-but-log-in-expectation. The measured round count is therefore one
  particular trajectory, not an average.
- **No reordering or loss *in this file's loop*.** The transport here happens to
  deliver each round atomically, but that does not weaken the proof: the union
  merge is commutative/associative/idempotent, so correctness holds under any
  delivery order by construction. (Sibling spikes `02`/`03`/`05` are where
  reordering and partitions are actually exercised.)
- **SWIM's timers and refutation are not modelled.** Real SWIM has a ping
  *timeout*, goes to a **suspect** state first, has **incarnation numbers** so a
  wrongly-suspected node can refute ("I'm alive, version+1"), and *piggybacks*
  membership updates in the indirect probes. The spike implements the *decision
  core* — direct + k indirect probe results → verdict — and passes the k indirect
  results in directly rather than having delegates actually send pings.
- **`k` is a fixed input.** Real SWIM chooses the k delegates at random among
  members to keep the vantage points independent; here they are supplied as a
  list.

So: the *mechanisms* are the real ones and their *properties* are really
asserted; only the nodes-as-processes, the network, the timers, and the
randomness are simulated. For the Raft counterpart in this suite the production
implementation is named explicitly — **Ra** (`rabbitmq/ra`, Jepsen-tested), which
implements the full RPC/timer protocol, whereas `06_raft.bl` shows the safety
core as pure state functions. Similarly, here the production-grade answer for
membership is a real SWIM implementation (e.g. HashiCorp's memberlist) with BEAM
messaging as transport; the spike shows you the core so you can reason about it
rather than trust it as a black box.

---

## Run it

```sh
./blx run research/fleet_spike/07_gossip_swim.bl
```

Expected final line (verbatim):

```
PASS 07_gossip_swim  (gossip spreads in O(log N); SWIM avoids false deaths)
```

Cold-start latency is ~10–15 s (the `blx` boot, not the algorithm — the algorithm
itself is microseconds).

---

## Exercises

**1. Grow the fleet.** Change `(def N 8)` to `(def N 64)` and predict how `rounds`
changes before running. (Hint: log₂ is your friend — going from 8 to 64 nodes
should add about 3 rounds, not multiply the count.) Then ask: why does a
*central* broadcaster's cost grow ∝ N while gossip's grows ∝ log N?

**2. Break the randomness.** Replace the body of `peer-of` with
`(rem (inc node) N)` — a fixed ring where each node always tells its neighbour.
Predict `rounds` for N=8, then run it. You should see dissemination become O(N):
the fact must walk the ring one hop per round. This is the experiment that shows
*why* the random peer matters — random long-range links are what turn a slow ring
into a log-time epidemic.

**3. Break the merge.** Replace `clojure.set/union` in `gossip-round` with a
plain overwrite (`(fn [s] (get st node))`) so a peer *replaces* its state instead
of unioning. Predict what happens to `rounds` (or whether it ever converges) and
why. This is the counterexample to the CRDT argument: without a
commutative/idempotent merge, a fact arriving "out of order" can be clobbered,
and dissemination is no longer guaranteed to cover the fleet.

**4. Tune SWIM's `k`.** In case B, change the indirect results to
`[false false false]` and predict the verdict, then set `k` to `0`. Now restore
`[false true false]` but set `k` to `1`: `(take 1 …)` takes only the *first*
result (`false`), so the reachable probe at index 2 is never consulted and the
node is misdeclared dead. Explain why real SWIM must actually query `k`
*independent* members — and connect it to the false-positive probability `pᵏ⁺¹`:
what does raising `k` buy you, and what does it cost?
