# 02 — The G-Set: your append-only log is already a CRDT

> Thesis: merging two nodes' event logs is *just set union* — and because union is commutative, associative, and idempotent, any two nodes that have seen the same facts end up with the identical set, with no coordination, no ordering, and no dedup bookkeeping.

Companion spike: [`research/fleet_spike/02_gset_crdt.bl`](../02_gset_crdt.bl) · run it with `./blx run research/fleet_spike/02_gset_crdt.bl`.

## The problem

A fleet emits events constantly: metrics samples, audit lines, latency observations. Every node produces them, so we have to ship them between nodes and end up with *one* history, not five slightly-different ones. The naive approach is: **each node keeps a list, and replication appends the other node's list onto yours.**

That fails in several concrete ways, all at once:

- **Duplicate delivery.** Networks redeliver. A retransmitted batch concatenated twice puts every event in twice. If you try to compensate with a "seen" buffer, you have reinvented state you must also replicate.
- **Reordering.** A list's value depends on arrival order. Two nodes that received the *same* events in different orders now hold *different* lists, so they have not actually converged — they merely both have "everything."
- **Re-applying your own log after a restart** grows the list again. Any anti-entropy loop that re-ships state (see the gossip spike, [`07_gossip_swim.bl`](../07_gossip_swim.bl)) will do this by design.
- **The "dedup by id" tempting fix loses data.** If two nodes both minted the id `e=3` for two genuinely different events and you key by that id to dedup, one of the two events silently disappears. This is worse than a duplicate: it is *silent data loss*, and it is exactly what per-connection counters produce (below).

So we need a merge that is provably **insensitive to order and to duplication**, plus an identity scheme that **never conflates two different facts**. The good news: this is already what an immutable append-only log is.

## The idea

Forget "logs" for a moment and look at what a datom actually is:

```
a datom is [e a v tx op]      ; entity, attribute, value, transaction, asserting?
```

It is **immutable** and **append-only**: you never edit a fact in place, you add a new fact (a retraction is itself a fact, with `op=false`). So the set of all facts a node holds is, literally, a **set**. Facts only ever get *added* to it.

Once you see that, replication has an obvious definition:

```
merge(A, B) = A ∪ B          ; "make my set the union of yours and mine"
```

And union is special. It obeys three laws:

```
commutative:   A ∪ B  =  B ∪ A            ; order of the two operands is irrelevant
associative:  (A ∪ B) ∪ C  =  A ∪ (B ∪ C) ; grouping / sequence of merges is irrelevant
idempotent:    A ∪ A  =  A                ; merging the same thing twice changes nothing
```

Those three laws are *exactly* the conditions for **convergence without coordination**. Idempotence is why duplicates are free: re-merging a fact you already have is a no-op. Associativity + commutativity are why delivery order is free: folding `∪` over the same collection of received deltas always lands on the same set. So convergence is a **theorem**, not an engineering promise — we do not need a coordinator, a global clock, or an ordering protocol. The whole mechanism fits in one word: **union**.

Two consequences worth naming up front:

- **Our state can only grow** (grow-only set, "G-Set"). Nothing removes a fact. That monotonicity is the precondition every CRDT needs, and it is why the append-only log is the perfect host for one.
- **Union cannot fix identity.** If two different events get called *the same fact*, union will happily treat them as one and lose data. So the only real hazard is **id collision**, and the fix is to partition the id space per node — the very last part of this tutorial.

## How it works

### The state and the merge, precisely

Let a node's state `S` be a set of **facts** — tuples like `["A" 1 :request]` (who, sequence, kind). Define:

```
⊔  =  ∪                       (merge is union)
⊑  =  ⊆                       (happens-before / information order is set inclusion)
⊥  =  ∅                       (the empty set: no information)
```

`(S, ⊑, ⊔)` is a **join-semilattice**: every pair of states has a *least upper bound* under `⊑`, and that bound is their union. Two facts of this structure matter:

```
S ⊑ S ⊔ T                     ; merged state contains everything I knew  (upper bound)
S ⊔ T = least such superset   ; and it adds nothing extra                (least)
```

The "least" part is what stops a node from fabricating facts neither side produced. The "Grow-only ⇒ monotonic" part is what stops a node from ever going *backwards*: `S ⊑ S ⊔ T` says information is never lost by merging.

### Why the three laws give convergence (the actual argument)

Suppose every node applies each delta it receives with `⊔`. A node's state is then a fold:

```
state(D) = d₁ ⊔ d₂ ⊔ … ⊔ dₙ        where D = {d₁ … dₙ} is the set of deltas it received
```

- **associativity** ⇒ the parenthesization of that fold (i.e. the *order* in which deltas arrived) does not matter;
- **commutativity** ⇒ the permutation of the operands does not matter;
- **idempotence** ⇒ a delta received twice contributes once.

Therefore `state(D)` depends **only on the set `D`**, not on how it was assembled. So:

> Any two replicas that have received the same set of deltas hold the same state. ∎

That is the entire correctness proof, and it never mentions time, leaders, or locks. In the code, `commutative`, `associative`, and `idempotent` are computed as booleans on concrete sets, and `converged` is the convergence claim itself — asserted, not assumed.

### It is a *delta*-CRDT: ship the new facts, not the whole state

The spike calls this a **G-Set δ-CRDT**, and the δ is doing work. There are two equivalent ways to replicate:

```
state-based:  ship my whole set every round;  peer does  peer ⊔ shipped
delta-based:  ship only the NEW facts since our last exchange;  peer does  peer ⊔ delta
```

Because the merge is the same `∪` over the same facts, shipping deltas reaches the *same* final state while sending far less. In the spike, the delta is exactly the tx-datoms one `transact!` produced, projected to portable facts.

### The invariant: identity must be globally unique

Union is only a *correct* merge if the two sides' facts are **disjoint identifiers** for genuinely distinct events. The hazard:

```
datom allocates e and tx from a per-connection monotonic counter.
Node A mints e=1, e=2, e=3 …     Node B independently mints e=1, e=2 …
⇒ A's log and B's log are NOT disjoint as sets of ids.
If replication keys facts by that bare id, A's e=1 and B's e=1 are "the same key"
⇒ union collapses them ⇒ one event is LOST (silently).
```

The fix is the standard one: **partition the id space per node.** Each node owns a disjoint range of identifiers (a node prefix, or a node-scoped counter). Then two nodes' facts can never collide, `A ∩ B = ∅` for distinct origins, and `∪` is a clean merge rather than a conflation. The spike models the partition by **tagging every event with its origin node** (`:ev/node`), so the two nodes' facts are disjoint *by construction*.

That partition is the precondition that promotes "a pile of rows" into "a **G-Set** of globally unique immutable facts." With it, the datom log *is* a CRDT, and the datom log drives the whole events row of the fleet model.

## Walkthrough

We walk the spike top to bottom. Each section prints a labelled stage; we cover them in order.

### Step 1 — Prove the semilattice laws on plain sets first

Before any datom machinery, the spike establishes the algebra on ordinary sets, so the laws are unmistakable:

```clojure
(defn union [a b] (clojure.set/union a b))
(def A #{1 2 3}) (def B #{3 4}) (def C #{4 5})
(def commutative (= (union A B) (union B A)))
(def associative (= (union (union A B) C) (union A (union B C))))
(def idempotent  (= (union A A) A))
(println "── G-Set merge is a join-semilattice ──")
(println (str "  commutative: " commutative "   associative: " associative "   idempotent: " idempotent))
```

Note that `B` deliberately shares element `3` with `A`, and `C` shares `4` with `B` — overlapping sets are where an order-dependent merge would show itself. All three booleans come out `true`, printing:

```
── G-Set merge is a join-semilattice ──
  commutative: true   associative: true   idempotent: true
```

This is the algebra the rest of the spike rests on.

### Step 2 — Two nodes produce events independently, in partitioned id spaces

Two nodes are modelled as two datom connections, each with its own event schema:

```clojure
(defn node-conn []
  (datom/connect [{:db/ident :ev/node :db/valueType :db.type/string}
                  {:db/ident :ev/seq  :db/valueType :db.type/long}
                  {:db/ident :ev/kind :db/valueType :db.type/keyword}]))

(defn emit! [conn node seq kind]
  (datom/transact! conn [{:db/id -1 :ev/node node :ev/seq seq :ev/kind kind}]))
```

Two things to see here:

- `:db/id -1` is a **tempid** — datom assigns the real entity id at transaction time. So the two connections genuinely mint ids independently; that is precisely the collision hazard in miniature.
- The event carries `:ev/node` — the partition tag. `seq` is per-node and may repeat across nodes harmlessly; the `(node, seq)` pair is the globally unique identity, which is exactly "each node prefixes its own ids."

Then each node records its own events, with **no** coordination:

```clojure
(def na (node-conn))
(def nb (node-conn))
(emit! na "A" 1 :request) (emit! na "A" 2 :request) (emit! na "A" 3 :error)
(emit! nb "B" 1 :request) (emit! nb "B" 2 :timeout)
```

### Step 3 — The replication unit is a projection to portable facts

A node does not ship raw internal rows (they carry node-local `e`/`tx` ids). It projects its datoms to portable, semantics-only facts `(node, seq, kind)`:

```clojure
(defn facts-of [conn]
  (set (datom/q '[:find ?node ?seq ?kind
                  :where [?e :ev/node ?node] [?e :ev/seq ?seq] [?e :ev/kind ?kind]] (datom/db conn))))
(def fa (facts-of na))
(def fb (facts-of nb))
```

This is a **real datalog query against the real datom database** — `datom/connect`, `datom/transact!`, `datom/q`, `datom/db`. The projection to `(node, seq, kind)` is the δ (the delta) and it drops the collision-prone local ids from the wire, keeping the partitioned identity. It prints each node's set (set ordering is arbitrary):

```
── each node's events (a G-Set of facts) ──
  A: #{["A" 1 :request] ["A" 2 :request] ["A" 3 :error]}
  B: #{["B" 1 :request] ["B" 2 :timeout]}
```

### Step 4 — Merge in arbitrary order, with duplicates and re-merges

Now the actual gossip, deliberately made hostile to order and duplication — A receives B's facts *twice*, B receives A's, and A re-applies its own:

```clojure
(def a-merged (union (union fa fb) fb))            ; A gets B's facts, twice (dup)
(def b-merged (union fb fa))                       ; B gets A's facts
(def a-remerged (union a-merged fa))               ; A re-applies its own (idempotent)
(println "── after gossip (arbitrary order + duplicates) ──")
(println (str "  A sees " (count a-merged) " events, B sees " (count b-merged) " events"))
```

`(union fa fb)` and `(union fb fa)` are the same set by commutativity; `(union … fb)` twice is the same set by idempotence. The two nodes arrive at 5 distinct events each despite the different paths — no dedup code written, no ordering enforced.

### Step 5 — Assert convergence, and count the facts

```clojure
(def converged (= a-merged b-merged a-remerged))
(def total (union fa fb))
(println (str "  converged: " converged "   total distinct events: " (count total)))
```

`converged` is a three-way equality: A-with-duplicates, B, and A-re-merged are the identical set. `total` is the ground truth: 3 from A + 2 from B. Output:

```
  A sees 5 events, B sees 5 events
  converged: true   total distinct events: 5
```

Five events in, five events out — **nothing lost, nothing duplicated** — from a merge that knows only `∪`.

### Step 6 — The counter-example: why partitioning is mandatory

The spike then shows what the collision would do, stripped of datom, with two nodes that "reused ids 1 and 2":

```clojure
(def bad-a #{[1 :request] [2 :request]})           ; node A's facts keyed by bare id
(def bad-b #{[1 :timeout] [2 :error]})             ; node B reused ids 1,2
(def bad-merge (union bad-a bad-b))                ; 4 distinct only by luck of value
(def keyed-by-id (set (map first bad-merge)))      ; the ID set collapses to {1,2}
(println "── why partitioning matters ──")
(println (str "  bare-id merge keeps " (count bad-merge) " tuples but only "
              (count keyed-by-id) " distinct ids → an event would be lost if keyed by id alone"))
```

The union of the four tuples has size 4 **only because the `v` halves differ** — the tuples are not equal. But project to the identity the merge is *supposed* to key on (the id, `first`), and the identity set collapses to `{1, 2}`: A's `e=1` and B's `e=1` are the same id. If replication keyed by id, one event vanishes. Output:

```
── why partitioning matters ──
  bare-id merge keeps 4 tuples but only 2 distinct ids → an event would be lost if keyed by id alone
```

This is the negative proof that Step 2's `:ev/node` tag is not decoration — it is the precondition.

### Step 7 — The assertions

The spike closes by asserting the whole story at once:

```clojure
(def ok (and commutative associative idempotent
             converged                       ; union converges regardless of order/dups
             (= 5 (count total))             ; 3 from A + 2 from B, none lost
             (= 2 (count keyed-by-id))))      ; bare ids WOULD collide (motivating partition)
(println "")
(println (str (if ok "PASS" "FAIL") " 02_gset_crdt  (datom log = G-Set; union converges; partition ids)"))
```

Five claims: the three semilattice laws, that the deltas converged under adverse delivery, that no event was lost, and that bare ids *would* have collided (which is why the partition exists). All true ⇒ `PASS`.

## Where it fits the fleet

`fleet/README` factors a fleet by **data class** and matches one algorithm to each seam. This spike serves exactly one row:

| data class | example | needs | algorithm | spike |
|---|---|---|---|---|
| **events** | metrics, audit, latency samples | append-only, high volume, must never conflict | **G-Set δ-CRDT (grow-only)** | `02_gset_crdt.bl` |

Events are the class where **any convergent answer is fine**. Nobody cares whether the ordering of two latency samples is A-then-B or B-then-A; they care that *both* are present and nothing was dropped. That is precisely the regime a CRDT is built for, and the simplest CRDT that suffices is the G-Set — because an immutable, append-only datom log *already is* a grow-only set. No mapping needed; the data is the CRDT.

Why this and not another:

- **Not Raft ([`06_raft.bl`](../06_raft.bl)).** Desired state *refuses* a CRDT precisely because conflict-free convergence would converge to the *wrong* thing; only *the agreed* answer is correct there. For events, there is no "wrong" convergent answer — losing an event is the only failure, and union never loses one. Paying for consensus on the event stream would add a leader, a round trip, and a partition-stall for zero benefit.
- **Not the OR-Set ([`03_orset.bl`](../03_orset.bl)).** The OR-Set exists to support **removal** (routes and claims get de-provisioned). A G-Set only grows — which is exactly right for events, which are immutable and never un-happen. Spike 03 is the honest extension of 02: it adds tombstones and the add-wins rule the moment removal enters the picture.
- **Not LWW ([`04_lww.bl`](../04_lww.bl)).** LWW picks one winner among conflicting *values* (a node's health status). Events do not conflict — they accumulate — so LWW's "discard all but the last" is the opposite of what this class wants.
- **Vector clocks ([`05_vector_clocks.bl`](../05_vector_clocks.bl)) are the layer beneath.** They are how you *detect* that two edits are concurrent (and therefore that a merge rule is needed at all). The G-Set needs no such detection because its merge is always correct for any pair of states — the concurrency question simply does not arise.
- **Gossip ([`07_gossip_swim.bl`](../07_gossip_swim.bl)) is how these deltas spread.** Its anti-entropy rounds literally take the union of state — a G-Set merge, "spike 02" by name — which is why a fact reaches every node in O(log N) rounds.
- **[`08_ot_vs_crdt.bl`](../08_ot_vs_crdt.bl)** makes the general case for CRDT over OT; this spike is the concrete, simplest instance of that argument.

So this is the row that anchors the CRDT half of the model: the one class where the *native shape of the data* — an append-only fact log — is the algorithm.

## What's real vs modelled

**Real.** The datom work is the real thing: real connections (`datom/connect`), real transactions (`datom/transact!` with tempids), and a real datalog query (`datom/q` over `datom/db`) — the facts asserted are genuine datom **tx-datoms**, projected to portable form. The semilattice property is proven on concrete sets, and convergence is asserted on the actual projected facts, including duplicate and re-merge paths. The id-collision hazard is demonstrated with a concrete counter-example.

**Modelled.** The two "nodes" are two `datom/connect` connections inside one process — there are **no sockets, no BEAM distribution, no message delivery under test**. "Gossip" is not a network simulation: it is the union expressions written out by hand (`(union fb fa)`, a doubled delivery, a re-merge). That is deliberate — it isolates the *algebra* (the property that makes any delivery order correct) from the transport, and the transport is not what is being claimed here. Ordering and duplication are exercised by construction, not by a randomized delivery scheduler. There is also no removal in this spike (a G-Set cannot), and no retraction-as-fact, even though real datom retractions (`op=false`) would keep the log a G-Set; that removal capability is the OR-Set spike's subject.

The claim this spike earns is narrow and solid: **union converges regardless of order, duplication, or re-application, and per-node id partitioning is what keeps union from conflating distinct events.**

## Run it

```
./blx run research/fleet_spike/02_gset_crdt.bl
```

Expected final line, verbatim:

```
PASS 02_gset_crdt  (datom log = G-Set; union converges; partition ids)
```

Cold start costs ~10–15s (JIT/daemon boot) — that latency is boot, not work. To run the whole fleet suite: `research/fleet_spike/run.sh`.

## Exercises

1. **Make A's and B's facts overlap in value, not just in id.** Change node B's events to emit `:request` with `seq` 3 and `:error` with `seq` 4 (values that *look* like A's but carry node `"B"`). Predict `(count total)` before running. Then ask the sharper question: what if you dropped `:ev/node` from the projection and keyed facts by `(seq, kind)` — which events would union now conflate, and where in Step 6 does that failure already show its face?

2. **Break idempotence on purpose, watch convergence die.** Replace `union` with a *multiset* merge (e.g. concatenate vectors, or use `clojure.set/union` of counts). Predict which of `commutative` / `associative` / `idempotent` still hold, and whether `converged` survives the doubled delivery `(union (union fa fb) fb)`. Explain in terms of the fold argument why the one law that fails is exactly the one that makes duplicates fatal.

3. **Model the real fix rather than the tag.** The spike partitions by tagging facts with `:ev/node`. Replace the tag with a genuinely node-scoped id (e.g. A mints ids `1,2,3` and B mints `1001,1002`), project facts to `(id)`. Predict whether Step 6's counter-example still collapses to 2 ids, and whether `converged` and the `(= 5 (count total))` assertion still hold. What did the tag approximate, and what did it hide?

4. **Add a removal, discover why 03 exists.** Try to delete A's `:error` event and keep the log converged. Predict what happens to `(count total)` under a pure `∪` merge, then read [`03_orset.bl`](../03_orset.bl) and identify the mechanism — fresh tags, tombstones, "add wins" — that the G-Set must add before removal can converge without coordination. Which of the three semilattice laws does the OR-Set's richer state preserve, and what extra state buys back removability?
