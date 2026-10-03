# 04 — LWW-Register: one value, converged by a deterministic tiebreak

**Thesis:** A Last-Writer-Wins Register converges a single-valued fact — "node vps-2 is `:up`" — by keeping the write with the greatest `(timestamp, node-id)`, a *total* order that every replica evaluates identically, so the same winner emerges no matter what order the reports arrive in.

---

## The problem

Picture the fleet's health view. Node `a` probes service `web` and reports `:up`. Node `b` probes it a moment later and reports `:down`. Node `c` probes it at the same moment as `b` and reports `:up` again. Three observations of *one* fact — the current health of `web` — and they disagree.

The fact is single-valued: we do **not** want a set of opinions, we want *the* status. So we need a rule that collapses three reports into one answer, and — this is the whole game — **every node must collapse them to the same answer**, or the fleet never converges on what "the status of `web`" even is.

The naive rule is **"keep whichever report arrived last"**:

```
replica-1 receives:  a(up), b(down), c(up)   → last arrival = c = :up
replica-2 receives:  c(up), a(up),  b(down)  → last arrival = b = :down   ✗
replica-3 receives:  b(down), c(up), a(up)   → last arrival = a = :up      ✗
```

Messages do not arrive in the same order at every node — networks reorder, retry, and partition. "Last" defined by *arrival* is a property of the network, not of the data, and the network is exactly the thing that differs per replica. Arrival-order gives us three different answers and a fleet that never agrees. ✗

The other naive rule — "the coordinator decides, everyone asks it" — reintroduces the thing we are avoiding for this data class: a central bottleneck and, worse, something that can be on the far side of a partition. Health reports must flow during a split; we can't require a round-trip to a leader to say "node 7 is alive."

We want: no coordination, any delivery order, one answer, everywhere.

## The idea

Stop defining "last" by *when it showed up*. Define it by *the data itself*.

Attach to every write two extra facts: a **timestamp** (when the write happened, as far as we can tell) and the **node-id** of the writer. Now "last" is a comparison we run on the values, not on the delivery stream:

```
write = (timestamp, node-id, value)
"last" = the maximum under the order (timestamp, then node-id)
```

Because the comparison reads only the two writes — never the network — every replica computes the same winner from the same pair of writes. Merge two reports in `a,b,c` order or `c,a,b` order and you compare the same `(ts, node)` pairs and pick the same max. **The result is independent of delivery order.** ✓

Why the node-id at all? Because timestamps tie. Node `b` and node `c` both stamped their probes `12`, and their clocks cannot be trusted to differ when they "really" happened at different instants. A tie on time leaves two candidates and no rule to choose — and *if the tiebreak is not the same on every replica, they pick different winners and diverge again*. So we add a second key with two properties:

1. **Total** — every pair of writers is strictly ordered, so there is never a remaining tie to break.
2. **Identical everywhere** — every replica compares `"node-b"` and `"node-c"` the same way.

Node ids give us both: unique per node, and strings (or integers) have a total order that every replica agrees on. `"node-c" > "node-b"` ∴ the later-of-equals wins by name. Ties resolve the same way on every replica ⇒ convergence restored. ✓

The shape, then:

```
┌───────────────────────────────┐
│  {:val v  :ts 12  :node "c"}  │   the register: one value + provenance
└───────────────────────────────┘
merge(a, b) = max(a, b) by (ts, then node)
```

One more thing worth seeing early: this is a **register**, not a set. It holds *one* value; a merge discards the loser entirely. That discard is a feature for health (a newer probe should supersede an older one) and a hazard for data where the losing write carried intent (more on that below). LWW is honest about being lossy.

## How it works

The mechanism is a single merge function with one job: given two registers, return the one that wins.

The order it uses is total:

```
a ≤ b   ⟺   ts_a < ts_b   OR   ( ts_a = ts_b   AND   node_a ≤ node_b )
```

`merge(a, b)` is exactly **max under this order** — return whichever of the two is greatest. Two consequences, and they are the entire correctness argument:

**Convergence.** A total order has a unique maximum, so folding `merge` over any multiset of writes yields the same element regardless of the order the fold visits them. Equivalently, `merge` is a **join-semilattice** operation:

- **commutative** — `merge(a, b) = merge(b, a)`
- **associative** — `merge(merge(a, b), c) = merge(a, merge(b, c))`
- **idempotent** — `merge(a, a) = a`

Commutativity + associativity = the fold result does not depend on order. Idempotence = re-delivering a report (the network *will* do this) changes nothing. Together they are precisely the CRDT convergence theorem: *if merge is a join-semilattice, every replica that has seen the same set of writes holds the same value* — no locks, no leader, no retries needed for correctness. ✓

**Determinism of the winner.** The total order guarantees the maximum is *unique*, and the node-id tiebreak guarantees it is *computable identically* on every replica. Had we only compared timestamps, ties would be broken by "whichever argument happened to be first" — a local, arbitrary choice — and replicas would disagree again. The node-id is what converts a partial comparison (times can tie) into a total one.

So the whole invariant is one line:

> **After merging the same set of writes, every replica holds `max` under `(ts, node)` — hence the same single value.**

`ts` here is a *logical* time (an integer tick). That matters: it keeps the spike's correctness argument free of wall-clock skew, isolating the tiebreak as the thing under test.

## Walkthrough

### Step 0 — the register's shape

```clojure
(defn reg [val ts node] {:val val :ts ts :node node})
```

Three fields. `:val` is the health status being tracked, `:ts` is the write's timestamp, `:node` is the writer's id — the tiebreak key. Nothing else; the provenance *is* the record.

### Step 1 — merge: one total order, two branches

```clojure
(defn lww-merge [a b]
  (cond
    (> (:ts a) (:ts b)) a
    (< (:ts a) (:ts b)) b
    ;; equal timestamps: break the tie deterministically by node id
    (>= (compare (:node a) (:node b)) 0) a
    :else b))
```

Read it as the order from the last section. The first two branches are "greater timestamp wins." The third is the tiebreak: when `ts` is equal, compare node-id — `compare` returns a sign, and `>= 0` means `a`'s node id is at least `b`'s, so `a` wins; otherwise `b`. That `>=` is where the "higher node-id wins" rule lives. Because `compare` is defined identically on every replica and node-ids are distinct, exactly one of `a`/`b` wins and every replica picks the same one. *Note:* `>= 0` (rather than `> 0`) means that if the two registers are literally identical, either is returned — the identical choice, so it is harmless.

### Step 2 — three concurrent reports

```clojure
(def from-a (reg :up   10 "node-a"))
(def from-b (reg :down 12 "node-b"))
(def from-c (reg :up   12 "node-c"))
```

`a` observed `:up` at tick 10. `b` observed `:down` at tick 12. `c` observed `:up` at tick 12 — an intentional **tie with `b`**, so the tiebreak is exercised. Three replicas will see these three reports, each in a different arrival order.

### Step 3 — fold the same reports in three orders

```clojure
(def r1 (lww-merge (lww-merge from-a from-b) from-c))   ; a,b,c
(def r2 (lww-merge (lww-merge from-c from-a) from-b))   ; c,a,b
(def r3 (lww-merge from-b (lww-merge from-c from-a)))   ; b,(c,a)
```

Each `rN` is a fold over the same three reports, but nested left, differently, and right. This is the associativity-and-commutativity test made concrete: if merge were order-sensitive, `r1 ≠ r2 ≠ r3` and the fleet would be broken. Run them and print:

```clojure
(println "── three health reports, merged in three orders ──")
(println (str "  a=" (pr-str from-a)))
(println (str "  b=" (pr-str from-b)))
(println (str "  c=" (pr-str from-c)))
(println (str "  order a,b,c → " (pr-str r1)))
(println (str "  order c,a,b → " (pr-str r2)))
(println (str "  order b,c,a → " (pr-str r3)))
```

### Step 4 — did they converge, and which value won?

```clojure
(def converged (= r1 r2 r3))
(def winner (:val r1))
(def winner-node (:node r1))
```

`converged` is the property under test — all three orders agree. Trace the winner by hand: `a`'s `ts=10` loses to both `12`s. `b` and `c` tie at `12`, so the node-id decides — `"node-c" > "node-b"`, so `c` wins and the value is `:up`, `winner-node` is `"node-c"`. The tie was resolved, deterministically, in favour of the alphabetically-later writer. Swap the names and the outcome flips (see the exercises) — that is the point: *the rule is mechanical and identical everywhere.*

### Step 5 — idempotence, and the wall-clock hazard, named

```clojure
(def idem (= (lww-merge r1 r1) r1))
```

Merging the converged register with itself returns itself — idempotence, the property that makes re-delivery safe. Then the spike leaves a comment worth reading twice:

```clojure
;; NOTE: with real wall clocks, a node with a fast clock can "win" forever — LWW
;; silently drops the loser's write. That is acceptable for HEALTH (a later probe
;; supersedes an earlier one) but NOT for desired state, which is why desired
;; state uses Raft (spike 06), not LWW.
```

This is the honest boundary of LWW. Its merge is lossy: the loser's value is *gone*, not remembered. For health that is exactly right — the newest observation of liveness is the truth, and an older one is stale by definition. For **desired state** ("billing runs on host 3") it would be a disaster: a config change whose write loses the race is silently erased, and the cluster converges — confidently — on the *wrong* config. A lossy register converges; it does not converge *to what you meant*. That is why desired state gets Raft, which refuses to lose an acknowledged write.

### Step 6 — the assertions

```clojure
(def ok (and converged                 ; all delivery orders agree
             (= :up winner)             ; c's :up @12 beats b's :down @12 by node-id
             (= "node-c" winner-node)
             idem))
(println "")
(println (str (if ok "PASS" "FAIL") " 04_lww  (last-writer-wins converges with a deterministic tiebreak)"))
```

Four checks, each a different facet of the same law: **convergence** (order-independence), **the correct winner by the documented rule** (both value and node), and **idempotence**. `PASS` means the register's defining algebra held under all three delivery orders — the property, asserted, not assumed.

## Where it fits the fleet

This spike serves the **membership / health** row of the per-data-class map in `research/fleet_spike/README.md`:

| data class | example | algorithm | spike |
|---|---|---|---|
| membership / health | who is alive, node status | **LWW-Register + gossip/SWIM** | **`04_lww.bl`**, `07_gossip_swim.bl` |

**Why LWW here.** Health is exactly the shape a register wants:

- **Single-valued.** A node is `:up` or `:down` — not a set. Newer observations *supersede* older ones; you never want yesterday's `:up` to linger against today's `:down`. LWW's lossy merge is the correct semantics.
- **High-rate, best-effort.** Probes fire constantly. Paying consensus (a majority round-trip) per probe would be absurd; LWW merges locally in O(1) with no coordination at all.
- **Partition-tolerant by design.** During a split, each side keeps converging on its best-known statuses; when the split heals, merges reconcile by timestamp. No side is blocked waiting for a leader. This is the AP choice the fleet makes deliberately for liveness data.

**Why not the alternatives.**

- **Not Raft (`06_raft.bl`).** Consensus is reserved for **desired state**, the one class where we *refuse* conflict-free convergence because converging on the wrong answer is worse than not converging. Health is the opposite: any convergent answer that tracks the newest probe is fine, and requiring agreement to publish a health status would make a partition freeze our entire liveness view. Overkill + wrong failure mode.
- **Not an OR-Set (`03_orset.bl`).** OR-Set is for **routes/claims**, where additions and removals accumulate and concurrent ops must both survive. Health is not accumulative — `:up` then `:down` should leave *one* value, not a set of both.
- **Not G-Set (`02_gset_crdt.bl`).** G-Set is grow-only, for **events** (metrics, audit). Health overwrites; a grow-only set would keep every stale status forever.
- **Not vector clocks (`05_vector_clocks.bl`).** Vector clocks **detect concurrency** but, by themselves, do not *resolve* it — they tell you two writes are concurrent and stop there. LWW is the resolution rule that says "and when they are concurrent, the greater `(ts, node)` wins." The two are complementary: vector clocks answer *"did X happen-before Y?"*; LWW answers *"if they didn't, which one do I keep?"*

**Its companion is gossip.** LWW defines *what* a merged health fact is; it says nothing about how nodes exchange them. That is `07_gossip_swim.bl`: anti-entropy gossip propagates statuses (as CRDT merges) with no broadcast bottleneck, and SWIM decides *when to publish `:down`* without crying wolf on one dropped packet. `07` mints the reports; `04` orders them. Together they are the membership/health row end to end. (And when a node's SWIM verdict and a rival's conflict, it is this register's tiebreak that settles it.)

## What's real vs modelled

- **Real.** The LWW merge is genuinely implemented in bl as a pure state function, and its **defining algebraic property — order-independent convergence with a deterministic total-order tiebreak — is really asserted** (`converged`, `idem`, and the specific winner). You can reorder or restructure the folds and the invariant will hold or fail for real.
- **Modelled.** The spike is an **in-process simulation of nodes and message delivery**: the three reports are values, and the three arrival orders are enumerated by hand rather than produced by a live network with reordering, duplication, and partitions. There are **no sockets**; between machines the transport is BEAM messaging in production, and transport is not the thing under test here. (Unlike `07_gossip_swim.bl`, this spike does not run a delivery sim at all — it demonstrates the algebra directly by folding fixed orders.)
- **Timestamps.** `:ts` is a plain integer standing in for a logical/hybrid clock. The spike deliberately uses ticks so the tiebreak is the star; it does *not* model wall-clock skew. The hazard is stated in a comment rather than simulated — the honest reading is: the convergence proof holds for *any* timestamps, but the *value that wins* is only as good as the clock that produced it, and real deployments need monotonic/hybrid clocks plus the node-id tiebreak to be safe.
- **Production note.** This is the standard LWW pattern used by Dynamo-style stores (Cassandra, Riak) — LWW with a per-writer tiebreaker. The candidate generation / sibling-resolution machinery those systems add is their answer to the same lossiness this spike names. There is no external library doing the work here: the register, the merge, and the assertions are the spike.

## Run it

```
./blx run research/fleet_spike/04_lww.bl
```

Cold start (first BEAM boot) takes roughly **10–15 s**; subsequent runs are quick. Expected final line, verbatim:

```
PASS 04_lww  (last-writer-wins converges with a deterministic tiebreak)
```

Before it you will see the three reports, the three merged orders printing the identical winning register, and the `converged` / `idempotent` flags.

## Exercises

1. **Flip the tiebreak, predict the value.** Rename `"node-c"` to `"node-0"` in `from-c` (leaving `"node-b"`). Now `"node-b" > "node-0"`, so the `ts=12` tie resolves to `b`. *Predict* the new `winner` and `winner-node` before running. Does `converged` still hold? (It should — convergence is about the *order being total and identical*, not about *which* node happens to win.) This is the cleanest way to feel that the tiebreak is arbitrary-but-fixed.

2. **Break the tiebreak, watch divergence.** Delete the third branch of `lww-merge` so a `ts` tie returns `a` (the first argument). Re-run. *Predict* which of `r1`, `r2`, `r3` disagree. Then argue why: the winner now depends on fold order, which is a property of the network — the exact bug the node-id tiebreak exists to kill.

3. **Make the order partial.** Change the tiebreak to compare only the first character of the node id (`(compare (first (:node a)) (first (:node b)))`). With `"node-b"` and `"node-c"` this still works — so pick two nodes sharing a first letter (e.g. `"node-b"` vs `"node-b2"`). *Predict* what `converged` does now: is the order still total? What happens to the tie?

4. **Model a fast clock.** Give `from-a` a huge timestamp `9999` (a node whose clock runs fast) and re-run. *Predict* the winner. Then reason about the fleet: if that node's clock is *always* fast, what happens to every other node's health updates? Connect this to the code comment and to `06_raft.bl` — why is "a fast clock wins forever, silently dropping losers" tolerable for health but fatal for desired state?
