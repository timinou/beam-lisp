# 05 — Vector clocks

A vector clock is a per-node counter map, bumped locally and merged by elementwise
max on receive, that lets any two events be classified as *happened-before* or
*concurrent* using only counters and message passing — no synchronized global clock.

## The problem

Distributed systems want to answer one deceptively simple question about any two
events: **did one happen before the other?**

Why anyone cares: when a fleet has two copies of some state and they differ, only
two outcomes are possible.

- B is simply a **newer version** of A (A happened-before B) → keep B, discard A. No conflict.
- A and B are **concurrent edits** (neither has seen the other) → there is a real conflict; apply a merge rule (add-wins, LWW, …) or you will silently lose a write.

Get this classification wrong and the failure is silent: divergent replicas that
never reconverge, or a lost update nobody notices. So the classification must be
*correct*, and it must be *available on any node* — each node has to make the call
alone, without asking anyone.

The naive answer is the **wall clock**: tag every event with `System.time()`, then
"A happened before B iff A.timestamp < B.timestamp". This is wrong, and wrong for
two independent reasons.

**(1) Clock skew.** Physical clocks are not synchronized and drift. A node's clock
can be a second slow or fast. Concretely, take the spike's own scenario:

```
A does event a1 at A-clock t=100.2
B does event b1 at B-clock t=99.8   (B's clock is behind)
B receives a1, then does b2          ← b2 causally follows a1
```

Because B's clock lags, `b2.timestamp` may still read *smaller* than `a1`'s. The
naive comparison now says `b2` came first — the exact opposite of the truth.
Causality is a fact about information flow; timestamps are a fact about two
independent oscillators. They diverge precisely when you need them most.

**(2) Even a perfect clock cannot express concurrency.** Suppose clocks were
perfect. Two events with different timestamps are ordered — but events on different
nodes that never exchanged messages are **not** causally ordered at all. They are
*concurrent*. A single scalar timestamp has no way to say "these two are
incomparable"; it is forced to invent an order that isn't there. Worse, merging by
"later timestamp wins" then silently drops one of two genuinely concurrent writes,
which is exactly the update you were supposed to merge.

The root cause: **causality is a partial order** (some pairs are comparable, some
are not), and a scalar is a *total* order (every pair is comparable). You cannot
embed a partial order into a total order without lying about some pairs. Vector
clocks keep the full partial order.

## The idea

Forget time. Trace **information flow**. If node B ever received a message from
node A (directly or transitively), then everything A knew at that point is in B's
causal past.

So give every node a counter it maintains for *every* node, including itself. A
node's vector clock does not record "what time it is". It records:

> **how many events of each node this node knows about.**

Node A's own slot counts A's events. Node B's slot, as seen by A, counts how many
of B's events A has heard about. The clock is a *knowledge ledger*, not a time.

Two rules keep the ledger truthful:

1. **On a local event**, a node increments **its own** counter. ("Another thing
   happened here.")
2. **On receiving a message**, a node takes the **elementwise max** of its own
   clock and the incoming clock, then increments its own counter. The max absorbs
   everything the sender knew (every counter the sender had is at least as high),
   so the receiver can never "un-know" an event; then it ticks to mark the receive.

Merging by max is the key move: knowledge only grows, never shrinks. If B's ledger
says "A: 5" and A's says "A: 7", B learns the newer count 7, not something lower.

Now compare two clock readings A and B:

```
A happened-before B   iff   A ≤ B  elementwise   AND   A ≠ B
A and B are concurrent iff   A ≰ B   and   B ≰ A
```

Read `A ≤ B` as: **B's ledger contains everything in A's ledger, and more.** B's
clock dominates A's in every slot ⇒ B has seen every event A had seen ⇒ B sits
downstream of A. If instead each clock holds something the other lacks (A knows
events B hasn't seen, *and* B knows events A hasn't seen), then neither is
downstream of the other — they are concurrent. The two ledgers are simply
**incomparable**.

That third possibility is the whole point. A scalar clock can only say `<`, `=`,
or `>`; a vector clock additionally says **∥** — "no causal relationship".

## How it works

The mechanism is six small functions. Three are the update rules, three are the
comparisons.

**Update — local event** (increment own slot):

```clojure
(defn vc-inc [vc node] (update vc node (fn [n] (inc (or n 0)))))
```

`(or n 0)` handles the first time a node appears: absent ⇒ assume 0, then inc to 1.

**Update — merge** (elementwise max over the union of node keys):

```clojure
(defn vc-merge [a b]
  (let [nodes (distinct (concat (keys a) (keys b)))]
    (into {} (map (fn [n] [n (max (get a n 0) (get b n 0))]) nodes))))
```

The union of keys matters: if `a` has never heard of node C, `(get a "C" 0)` treats
it as 0, and the result correctly picks up `b`'s C count. Absent = 0 = "no
knowledge", the identity for max.

**Update — receive** (merge, then tick own):

```clojure
;; on receive: merge the incoming clock, then tick your own
(defn vc-recv [local incoming node] (vc-inc (vc-merge local incoming) node))
```

Order is load-bearing: absorb the sender's knowledge **first**, then record your
own receive event. If you ticked before merging, your clock could end up
"≤" the incoming one for the slots you just received, and you'd miss that the
receive itself is a new event on this node.

**Compare — the partial order**:

```clojure
(defn vc-leq [a b]                                  ; a ≤ b elementwise?
  (every? (fn [n] (<= (get a n 0) (get b n 0)))
          (distinct (concat (keys a) (keys b)))))
(defn vc-before? [a b] (and (vc-leq a b) (not= a b)))
(defn vc-concurrent? [a b] (and (not (vc-leq a b)) (not (vc-leq b a))))
```

### The law, and why it guarantees correctness

`vc-leq` is the standard **product order** on vectors: `a ≤ b` iff every coordinate
of `a` is ≤ the same coordinate of `b`, with missing coordinates read as 0. That
relation is a genuine **partial order** — it is

- **reflexive** (`a ≤ a`),
- **antisymmetric** (if `a ≤ b` and `b ≤ a` then `a = b`),
- **transitive** (`a ≤ b ≤ c` ⇒ `a ≤ c`).

`vc-before?` is the strict version (`≤` and not equal). `vc-concurrent?` is "neither
direction" — the incomparability test. These three are the only outcomes for a
distinct pair: *before*, *after*, or *concurrent*.

Correctness rests on one invariant, maintained by the two update rules:

> **Invariant (causal soundness):** for every real event `e` on any node, the clock
> carried by `e` is `≥` (elementwise) every clock that causally precedes `e`.

Proof sketch by induction over the happens-before relation:

- **Local step.** If `e` follows `e'` on the same node, `e`'s clock = `e'`'s clock
  with one own-slot increment. Incrementing a coordinate preserves `≥` and makes
  the vector strictly larger, so `e' ≤ e` and `e' ≠ e` ⇒ `vc-before? e' e` is true.
- **Message receive.** If B receives A's clock, B's clock is
  `inc(vc-merge(B, A))`. Elementwise max is `≥` both inputs; the subsequent inc
  keeps it `≥`. So every event in A's past, and A's own send, is `≤` B's post-receive
  clock and strictly so ⇒ `vc-before?` holds. The same argument chains transitively:
  if `x ≤ A` and `A ≤ B` then `x ≤ B`.

That establishes `a → b ⇒ vc-before?(clock a, clock b)`. The converse — that
`vc-before?` implies a real causal path — holds because the only ways a coordinate
can grow are a local tick (a causal step) or a merge from a message (a causal
step). A coordinate of B strictly greater than A's therefore had to be deposited
by some chain of ticks and receives reaching B from that node. No clock can grow
without a cause. So `vc-before?` **characterizes** happens-before exactly — it is
not merely a sound approximation (as a scalar Lamport clock is; that one is sound
but incomplete, ordering concurrent events arbitrarily).

Two more properties fall out of the merge being elementwise max:

- **Commutative, associative, idempotent.** `max` is; applied coordinatewise and
  unioned over keys, `vc-merge` is too. So the set of vector clocks is itself a
  **join-semilattice** with `vc-merge` as join — the same algebraic shape that makes
  the CRDTs in spikes 02–04 converge. (That is not a coincidence: causality
  bookkeeping is naturally monotone, which is why CRDTs *want* it.)
- **Monotone.** A node's clock never decreases in any slot. Knowledge only grows.

## Walkthrough

The spike builds four clock readings — a short causal chain and a concurrent fork —
then makes the three judgments and turns the concurrency verdict into a resolution.

### Step 1 — a causal chain and a concurrent fork

The scenario is annotated in the source:

```clojure
;; a1: node A does a local event.               A={A:1}
;; b1: node B does a local event (independent).  B={B:1}
;; b2: B receives A's a1, then does an event.    merge+tick ⇒ {A:1 B:2}
;; a2: A does another local event.               A={A:2}
;; Now compare: a1→b2 (causal), a2 vs b2 (concurrent, neither saw the other).
(def a1 (vc-inc {} "A"))                            ; {A 1}
(def b1 (vc-inc {} "B"))                            ; {B 1}
(def b2 (vc-recv b1 a1 "B"))                        ; B receives a1 then ticks ⇒ {A1 B2}
(def a2 (vc-inc a1 "A"))                            ; {A 2}  (A never saw b1/b2)
```

Trace each value:

- `a1` = `vc-inc {} "A"` → `{"A" 1}`. A's first event.
- `b1` = `vc-inc {} "B"` → `{"B" 1}`. B's first event, made independently — A and B
  have never spoken, so neither clock mentions the other.
- `b2` = `vc-recv b1 a1 "B"` → merge `{"B" 1}` with `{"A" 1}` = `{"A" 1, "B" 1}`,
  then tick B → `{"A" 1, "B" 2}`. B now "knows about" A's event; its ledger is
  strictly ahead of `a1`.
- `a2` = `vc-inc a1 "A"` → `{"A" 2}`. A just does another local event. A has
  *never* seen B, so its clock still has no B slot. This is the crux: A's clock
  grew independently while B's clock was absorbing A's — the two histories forked.

This prints:

```
── clocks ──
  a1={"A" 1}  b1={"B" 1}
  b2={"A" 1, "B" 2}  (B merged a1 then ticked)
  a2={"A" 2}  (A ticked, never saw B)
```

(Map key order is not guaranteed; the counts are.)

### Step 2 — the judgments causality lets us make

```clojure
(def a1-before-b2 (vc-before? a1 b2))              ; true: b2 causally follows a1
(def a2-conc-b2   (vc-concurrent? a2 b2))          ; true: neither saw the other
(def b1-before-b2 (vc-before? b1 b2))              ; true: same node, later
```

- `a1-before-b2`: is `{"A" 1} ≤ {"A" 1, "B" 2}` elementwise? `A:1≤1` ✓, `B:0≤2` ✓,
  and they differ ⇒ **before**. Correct: B received a1, so a1 is in b2's causal past.
- `a2-conc-b2`: is `{"A" 2} ≤ {"A" 1, "B" 2}`? `A:2≤1` ✗. So not `≤`. Is
  `{"A" 1, "B" 2} ≤ {"A" 2}`? `B:2≤0` ✗. So not the other way either ⇒ **concurrent**.
  Look at *why*: A knows an event B doesn't (A's second), and B knows an event A
  doesn't (everything about B). Each ledger holds something the other lacks.
- `b1-before-b2`: is `{"B" 1} ≤ {"A" 1, "B" 2}`? ✓, differ ⇒ **before**. Same-node
  ordering: B's later event sits downstream of B's earlier one.

This prints:

```
── judgments ──
  a1 → b2 (happened-before): true
  a2 ∥ b2 (concurrent):      true
  b1 → b2 (happened-before): true
```

The `→` is happens-before; the `∥` is the relation a wall clock cannot express.

### Step 3 — from concurrency to a merge decision

The payoff. The spike turns the classification into the action a fleet would take:

```clojure
;; If a2 and b2 were causally ordered, we'd keep the later. Because they are
;; CONCURRENT, a fleet must apply a merge rule (OR-Set add-wins, LWW, etc.) rather
;; than blindly overwrite — vector clocks are what DETECT that this is needed.
(def resolution (if a2-conc-b2 :must-merge :keep-later))
```

Because `a2` and `b2` are concurrent, `resolution` is `:must-merge`. Had they been
ordered (say A had first received `b2`), the same code would yield `:keep-later` and
the fleet could simply take the causally-newer value. This one `if` is the entire
value proposition: **a vector clock tells you *whether* you need a merge rule, so
you never silently overwrite a concurrent write.**

It prints:

```
  ∴ a2 vs b2 resolution: :must-merge
```

### Step 4 — the assertions

```clojure
(def ok (and a1-before-b2                 ; causal chain detected
             b1-before-b2
             a2-conc-b2                    ; concurrency detected
             (not (vc-before? a2 b2))      ; and it is NOT a happens-before
             (not (vc-before? b2 a2))
             (= :must-merge resolution)))
(println "")
(println (str (if ok "PASS" "FAIL") " 05_vector_clocks  (happened-before vs concurrent, no global clock)"))
```

Five checks, each asserting one defining property: the causal chain `a1→b2` is
detected; the same-node chain `b1→b2` is detected; the independent fork `a2∥b2` is
detected as concurrent; that fork is asserted **not** to be a happens-before in
either direction (the negative half — soundness against false positives); and the
concurrency verdict drives the merge decision. All five hold ⇒ `PASS`.

## Where it fits the fleet

In the README's per-data-class map, vector clocks are the **causality** row:

| data class | needs | algorithm | spike |
|---|---|---|---|
| causality | did X happen-before Y? detect concurrency without a global clock | **vector clocks** | `05_vector_clocks.bl` |

But the interesting placement is *underneath* the CRDTs. **A vector clock is not
itself the CRDT that stores your data — it is the primitive that tells a CRDT when
a merge is required.** The README frames the boundary between desired state and the
AP classes as: concurrent conflict-free convergence to a *wrong* answer is fine for
routes/health/events, fatal for desired state. Vector clocks are the instrument
that decides which situation you are in:

- `03_orset.bl` (routes / claims) and `04_lww.bl` (membership / health) converge by
  a merge that is a join-semilattice. Their merges are *safe* precisely because they
  only ever get applied to genuinely concurrent inputs; if the inputs were causally
  ordered, the "merge" should have been a plain overwrite. Vector clocks are what
  distinguish the two cases — hence the spike's closing line, "the primitive under
  every CRDT".
- `04_lww.bl` shows the *other* strategy for the same problem: when you don't want to
  carry a causality vector, approximate it with a `(timestamp, node-id)` total order
  and accept that the loser's write is dropped. That is a conscious downgrade of the
  causality information — cheap and convergent, but it can't tell concurrency from
  causation, so it just picks a winner. Vector clocks keep the distinction; LWW
  throws it away.
- `02_gset_crdt.bl` (events) is the case that needs *none* of this: a grow-only set
  unions safely regardless of order or concurrency, so it can skip causality entirely.
- `06_raft.bl` (desired state) solves the same "which version is newer?" question the
  *opposite* way: instead of tracking causality, it uses consensus to force a single
  total order (term + log index). Where vector clocks *detect* concurrency and hand
  the decision to a merge rule, Raft *eliminates* concurrency for the one data class
  that cannot tolerate it.

**Why vector clocks and not another mechanism.** A global physical clock is
unavailable (skew, and it can't represent concurrency). A scalar **Lamport clock**
is sound ordering-wise (`a → b ⇒ Lamport(a) < Lamport(b)`) but incomplete: it cannot
recover the concurrency relation, so `a ∥ b` and `b → a` look identical. Vector
clocks are the exact characterization of happens-before for message-passing systems,
at the cost of `O(n)` counters per clock (a real cost the exercises and the next
section both touch).

## What's real vs modelled

**Real.** The algorithm is genuinely implemented in bl — the two update rules and
the three comparisons are pure state functions over ordinary maps, and the spike's
defining property (detect happens-before vs concurrent with no global clock) is
really exercised: a causal chain and a concurrent fork are constructed, and the
judgments are asserted, including the negative check that the fork is *not* a
happens-before. The partial order, the elementwise merge, and the concurrency test
are the real thing, not a stand-in.

**Modelled.** Following the README's fidelity note, this runs as an **in-process
simulation**: "nodes" are just bl values (maps) and "message delivery" is a direct
function call — `vc-recv` is invoked explicitly with the sender's clock, rather than
a message arriving over a socket. There is no transport, no reordering, no loss, and
no wall-clock skew under test; the transport is BEAM messaging in production and is
not the thing being modelled here. Consequences worth naming:

- The spike models a **two-node + one fork** scenario. There is no vector-clock
  **garbage collection**: real systems prune dead-node slots (or use *dotted version
  vectors*) so clocks don't grow without bound as nodes come and go; the spike keeps
  them small and doesn't touch pruning.
- Because delivery is a direct call, the run does not exercise *out-of-order* or
  *duplicate* delivery. (The algorithm is robust to both — `vc-merge` is commutative
  and idempotent, so re-receiving or reordering messages cannot corrupt a clock — but
  the spike demonstrates the property rather than simulating the schedule.)
- The comparison to production is instructive: like `06_raft.bl` is to **Ra**
  (rabbitmq/ra, Jepsen-tested) for consensus, this spike is to a real vector-clock
  library. Where Raft's spike implements the safety core as pure state functions and
  leaves the timers/RPC out, this spike implements the *entire* causality core — the
  only thing outside the tank is the message bus. For contrast on the "real substrate"
  end, `02_gset_crdt.bl` operates on actual `datom` tx-datoms; here there is no such
  substrate because causality is a property of event ordering, not of stored data.

## Run it

```
./blx run research/fleet_spike/05_vector_clocks.bl
```

Expected final line (verbatim from the spike):

```
PASS 05_vector_clocks  (happened-before vs concurrent, no global clock)
```

Cold-start latency is ~10–15s (blx JIT warmup) — that time is boot, not work. The
full suite runs with `research/fleet_spike/run.sh`.

## Exercises

1. **Add a third node.** After the existing scenario, add `(def c1 (vc-inc {} "C"))`
   (node C's first local event) and ask `(vc-before? c1 b2)` and
   `(vc-concurrent? c1 b2)`. *Predict before running:* C has never exchanged messages
   with anyone, and `b2` has no C slot. Which way does each judgment fall, and why is
   the answer forced by the missing slots rather than by timing?

2. **Drain the fork.** Add `(def a3 (vc-recv a2 b2 "A"))` — A finally receives `b2`
   and ticks. Now recompute `(vc-concurrent? a3 b2)` and the `resolution` for `a3`
   vs `b2`. *Predict:* A has now absorbed everything B knew, so the concurrency should
   evaporate and the resolution should flip to `:keep-later`. Confirm the exact
   resulting clock of `a3`, and explain why one `vc-recv` was enough to restore a
   total order between these two histories.

3. **Break the merge.** Change `vc-merge` to take the elementwise `min` instead of
   `max` (replace `(max (get a n 0) (get b n 0))` with `(min (get a n 0) (get b n 0))`).
   *Predict:* recompute `b2` by hand, then the three judgments, then the `PASS`/`FAIL`.
   Why does a merge that *forgets* knowledge make causal-chain detection
   (`a1 → b2`) fail, and why can a clock only ever be allowed to grow?

4. **Collapse to a scalar.** Replace each map with a single integer and use Lamport's
   rule: local event ⇒ `inc`; receive ⇒ `max(local, remote) + 1`. Re-run the same
   four-value scenario. *Predict:* `a1 → b2` and `b1 → b2` still work, but what happens
   to `a2` vs `b2`? You will find the two scalars are plainly ordered, so
   `vc-concurrent?` can never return `true` and the `:must-merge` resolution is lost —
   replacing a merge with a silent overwrite. State precisely which property a scalar
   clock cannot express, and why it costs `O(n)` counters to recover it.
