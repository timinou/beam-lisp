# 01 — Placement: consistent hashing and rendezvous (HRW)

*Thesis:* When the set of nodes changes — a machine joins, or one dies — you want to move the **fewest** keys possible, and `hash mod N` moves nearly all of them, while consistent hashing and rendezvous (HRW) each move only the changed node's share.

## The problem

Every fleet has to answer one question constantly, for every service name and every data key:

> *which node owns this?*

The first thing anyone reaches for is `hash mod N`:

```
owner(k) = h(k) mod N          ; N = number of nodes
```

It is one line, it is deterministic, and it spreads keys evenly. It is also a trap — because the owner formula **depends on N**, and N is exactly the thing that changes in a fleet.

The moment a node leaves, `h(k) mod 5` becomes `h(k) mod 4`, and the remainder is different for almost every key:

```
N: 5 → 4
h(k) mod 5  =  h(k) mod 4   only when  h(k) mod lcm(5,4)=20  ∈  {0,1,2,3}
∴ 4/20 = 20% of keys keep their owner;  80% remap
```

80% of the keyspace does not just re-shuffle — it **remaps to a different owner**, and each remap is real work: a cache miss, a connection re-routed, a partition that must be re-replicated, a lookup that now answers a different node. In a fleet that loses a node during a deploy, `hash mod N` turns a localized failure into a total reshuffle of the keyspace — the classic cascade, where the rebalancing load itself finishes off the survivors.

`hash mod N` fails the only requirement placement actually has:

> **on membership change, move the minimum.**

The minimum, on losing one of five nodes, is ~20% — the failed node's own share, and nothing else. The keys owned by the four survivors had to stay put; they had no reason to move. `hash mod N` moves them anyway, because the divisor leaked N into the answer.

## The idea

Both real algorithms fix this the same way: **bind a key to a node through the data itself, never through N.** A membership change should only disturb the keys whose owner actually changed.

Two mechanisms, one goal.

**1. Consistent hashing — the ring.** Put both nodes and keys on *one circular number line*:

- hash each node to a point on a 2³² ring;
- hash each key to a point;
- the key's owner is the **first node clockwise** from it (its successor).

```
        a•            e•
   k₁ →  •───────→            
              b•                             ring = positions mod 2³²
     d•           c•      owner(k₁) = first node at or after position(k₁)
```

Now a node's ownership is an *arc* of the ring. Remove a node ✗ delete its points ✗ only keys falling in its arcs re-elect — every key outside those arcs keeps its successor. Churn drops from 80% to the failed node's arc (~20%). ✓

One point per node is not enough: a single random point gives wildly uneven arcs (one node can accidentally own 40% of the ring). Fix = **virtual nodes**: each node occupies V points (the spike uses V=64) so its arc is the sum of V small arcs → far more even, with no central coordination.

**2. Rendezvous / HRW — no ring at all.** For each node, score the pair `(node, key)`; the highest score wins:

```
owner(k) = argmax over n∈S of  w(n,k),      w(n,k) = hash(n ‖ k)
```

From the data, per key, independently — there is no ring to maintain and no shared state to agree on. On removal of node `e`, a key whose owner was *not* `e` still has its maximal node present, so its argmax is **unchanged**. Only the keys `e` owned re-elect. HRW is balanced *for free* (each key picks its own max; symmetry makes every node's expected share `1/N`), so it needs no virtual nodes.

Both beat `hash mod N` by the same law, which is the spine of this whole spike:

> **a membership change moves exactly the data whose owner changed — and only that.**

That is optimal, because those keys *had* to move (their node is gone). Nothing else should.

## How it works

### The law, stated once for each scheme

**HRW — churn is provably minimal.**

```
owner(k, S) = argmax_{n∈S} w(n,k)
claim:  owner(k, S∖{e}) = owner(k, S)   unless  owner(k, S) = e
proof:  let m = argmax_{n∈S} w(n,k).
        if e ≠ m, then m ∈ S∖{e} and m still has the maximum
        ⇒ argmax over the smaller set is still m.  ✓
∴ churn(S → S∖{e}) = |{ k : owner(k,S) = e }| = share(e, S)
```

Not an approximation — an exact identity. Removing node `e` moves *precisely* `e`'s keys, no others. In the spike you can check this by eye: the printed HRW churn percentage should equal node `e`'s share in the printed HRW distribution.

**The ring — the same law, arc by arc.**

```
pos(n_i) = h(n_i ‖ i)   for i ∈ 0..V-1          (virtual nodes)
owner(k) = successor_ring(h(k))                  (first point ≥ h(k), wrapping)
remove e  ⇒  delete e's V points
a key's successor changes only if one of e's points was the successor
∴ only keys in e's arcs move — same minimal-churn law
```

A key's successor is unchanged unless the *specific point* that was its successor belonged to `e`. Adding a node is symmetric in reverse: the newcomer inserts its V points and steals only the arcs it now covers.

### Why the ring needs virtual nodes and HRW does not

Balance is a statement about *share sizes*:

- **HRW:** for a given key, the winner is the max of N hashes. By symmetry each node's expected share is exactly `1/N`; across K keys the realized shares concentrate near `1/N` (law of large numbers). Nothing to tune.
- **Ring:** the share of a node is a *sum of arc lengths*. With one point per node, arc length is a single random draw — high variance, brutal imbalance. With V points it is a sum of V draws, and relative deviation shrinks like `1/√V`. V=64 is the spike's chosen smoothing constant.

So the ring buys balance with memory (`N·V` ring entries and a sorted lookup structure); HRW buys it with an O(N) scan per lookup and zero shared state.

### The precondition nobody mentions: the hash is part of the protocol

Placement is a **pure function** of `(membership, key)`. Correctness therefore rests entirely on every node computing the *same* hash:

```
∀ nodes  n₁, n₂ :  h(n₁) = h(n₂)     — else they disagree on who owns what
```

`erlang/phash2` (Erlang documents it as portable — same value on every node and across releases) is used precisely for this. A per-node random hash would make the fleet route one key to two different owners. This is also *why placement needs no consensus and no CRDT*: once the membership view is the same everywhere, everyone computes the same placement **deterministically**. The hard part — agreeing on membership — lives in another spike (07); placement just consumes it.

### The three schemes side by side

| | owner of key | churn on losing 1 of 5 | balance | shared state |
|---|---|---|---|---|
| `hash mod N` | `h(k) mod N` | ~80% ✗ | even ✓ | none, but wrong |
| consistent hash (ring) | successor on ring | ~1/N ≈ 20% ✓ | good with V vnodes | the ring (N·V points) |
| rendezvous (HRW) | `argmax hash(n,k)` | exactly node's share ≈ 20% ✓ | good, free ✓ | none |

## Walkthrough

### Step 0 — the hash

```clojure
(defn h [s] (erlang/phash2 s 4294967296))          ; a stable 32-bit hash
```

`erlang/phash2/2` maps any term to an integer in `[0, Range)`. `Range = 4294967296 = 2³²` defines the ring's circumference. Crucially it is *portable*: the same string hashes identically on every node and across OTP releases, which is the precondition above. Every placement decision in the spike flows through this one function.

### Step 1 — the naive baseline

```clojure
(defn mod-place [nodes key] (nth nodes (rem (h key) (count nodes))))
```

Index = `hash(key) mod (count nodes)`, then pick that element.

`(count nodes)` is the poison: the divisor is derived from the list length, so removing an element changes it and every remainder shifts. This is the algorithm we will measure against.

### Step 2 — the ring

```clojure
(def V 64)
(defn ring [nodes]
  (sort-by first
    (mapcat (fn [n] (map (fn [v] [(h (str n "#" v)) n]) (range V))) nodes)))
```

Build the ring once per membership view. Inner `map` gives node `n` its V virtual points: for each `v ∈ 0..63` a pair `[h("a#0") "a"], [h("a#1") "a"], …`. `mapcat` flattens all nodes' points into one list; `sort-by first` orders them by position. Result: a sorted list of `[pos node]` — the ring, ready for successor lookups.

```clojure
(defn ring-place [r key]
  (let [p (h key)
        after (some (fn [[pos n]] (if (>= pos p) n nil)) r)]
    (or after (second (first r)))))
```

Hash the key to `p`. Walk the sorted ring with `some`, returning the node of the **first** point whose `pos ≥ p` — the successor. `some` yields that node (or `nil` if the walk runs off the end). `(or after (second (first r)))` handles the ring's wrap: if `p` is past the last point, the successor is the first point — `(second (first r))` is the node of the smallest-position entry.

### Step 3 — rendezvous / HRW

```clojure
(defn hrw-place [nodes key]
  (second (reduce (fn [best n]
                    (let [w (h (str n "|" key))]
                      (if (> w (first best)) [w n] best)))
                  [-1 nil] nodes)))
```

A single `reduce` computing the max. The accumulator is a `[weight node]` pair seeded at `[-1 nil]`. For each node, score `w = h(node ‖ key)`; if it beats the running best, become the new best. Return `(second …)` — the winning node. No ring, no vnodes, no sorting: the owner is decided fresh from the key each time. This is why HRW is *stateless*.

### Step 4 — measuring churn

```clojure
(def keys- (map (fn [i] (str "svc-" i)) (range 1000)))
(def nodes5 ["a" "b" "c" "d" "e"])
(def nodes4 ["a" "b" "c" "d"])                      ; "e" failed
```

1000 key names, and two membership views: five healthy nodes, and the same fleet with node `"e"` removed (the simulated failure).

```clojure
(defn churn [place-fn n5 n4]
  (let [before (map (fn [k] (place-fn n5 k)) keys-)
        after  (map (fn [k] (place-fn n4 k)) keys-)
        moved  (count (filter (fn [[b a]] (not= b a)) (map (fn [a b] [a b]) before after)))]
    (/ (* 100 moved) (count keys-))))
```

Place every key under both views, `before` and `after`. `(map (fn [a b] [a b]) before after)` zips the two owner-lists into pairs `[before-owner after-owner]` (the parameter names `a b` are just local); `filter` keeps the pairs where the two owners differ and `count` gives the moved keys. Divide by 1000 and multiply by 100 → a percentage. `churn` is generic over the placement function, so it times both `mod-place` and `hrw-place`:

```clojure
(def mod-churn  (churn mod-place nodes5 nodes4))
(def hrw-churn  (churn hrw-place nodes5 nodes4))
```

The ring cannot go through `churn` because it needs the *pre-built rings*, not raw node lists, so it is inlined with the identical before/after logic:

```clojure
(def ring-churn
  (let [r5 (ring nodes5) r4 (ring nodes4)
        before (map (fn [k] (ring-place r5 k)) keys-)
        after  (map (fn [k] (ring-place r4 k)) keys-)
        moved  (count (filter (fn [[b a]] (not= b a)) (map (fn [a b] [a b]) before after)))]
    (/ (* 100 moved) (count keys-))))
```

Note it builds one ring per membership view (`r5`, `r4`) — the ring state is a function of membership, rebuilt whenever membership changes.

### Step 5 — the churn report

```clojure
(println "── churn when 1 of 5 nodes fails (1000 keys) ──")
(println (str "  hash mod N:        " mod-churn "% of keys move  (near-total reshuffle)"))
(println (str "  consistent hash:   " ring-churn "% move  (~ the failed node's share)"))
(println (str "  rendezvous (HRW):  " hrw-churn "% move  (only the failed node's keys)"))
```

The measurement made visible. Roughly:

- **`hash mod N` ≈ 80%** — the arithmetic from *The problem*, confirmed empirically.
- **ring ≈ 22%**, **HRW ≈ 25%** — both near the ideal 20% (the failed node's share), the small gap being simply *how much* of the keyspace node `e` happened to own under each scheme. Neither is "always better": both move only the loser's keys.

### Step 6 — balance

```clojure
(defn distribution [place-fn nodes]
  (-> (group-by (fn [k] (place-fn nodes k)) keys-) (update-vals count)))
(def hrw-dist (distribution hrw-place nodes5))
(println "── balance (HRW, 1000 keys over 5 nodes; ideal ~200 each) ──")
(println (str "  " (pr-str hrw-dist)))
(def spread (- (reduce max (vals hrw-dist)) (reduce min (vals hrw-dist))))
```

Group the 1000 keys by their HRW owner, then count each group (`update-vals count`) → a map `node → key count`. With 5 nodes the ideal is 1000/5 = 200 each. `spread` is `max − min` of those counts — a single number for "how uneven is the load", asserted to stay under 120 below, i.e. every node within ~±60 keys of 200. HRW gets this for free; the ring would need V large enough to match it.

### Step 7 — the assertions

```clojure
(def ok (and (> mod-churn 50)              ; naive: catastrophic reshuffle
             (< ring-churn 35)             ; consistent hashing: ~ one node's share
             (<= hrw-churn 30)             ; HRW: exactly the failed node's keys (its share, ~25%)
             (< spread 120)))              ; HRW load is reasonably balanced
(println "")
(println (str (if ok "PASS" "FAIL") " 01_sharding  (consistent hashing + HRW minimise churn)"))
```

Four claims, each an inequality that *would fail* if the property broke:

- `mod-churn > 50` — the naive scheme really is terrible (we are not strawmanning).
- `ring-churn < 35` — the ring really moves only ~one node's share, not the keyspace.
- `hrw-churn ≤ 30` — HRW really confines churn to the failed node's keys.
- `spread < 120` — HRW really is balanced.

All four hold → `PASS`. The thresholds are deliberately loose (35 vs ~22) so ordinary sampling wobble never flips a genuine pass to a false fail.

## Where it fits the fleet

This spike serves the **placement** data class: *which node owns a service or a key.*

```
| data class | needs | algorithm |
| placement  | balanced, minimal churn on membership change | consistent hashing / HRW |
```

Placement gets **neither consensus nor a CRDT** — and that is the point of the suite's per-data-class model. Look at what placement actually is:

- It has **no conflicting writes to merge.** Two nodes never "write" ownership; ownership is *derived*. So a CRDT would be solving a problem that does not exist here.
- It has **no single agreed truth to elect.** *Any* deterministic assignment is fine, as long as everyone computes the same one. So Raft's agreement machinery would be wasted.

What it has is a **pure function**: `placement = f(membership, key)`. Placement therefore sits *downstream* of membership — `07_gossip_swim.bl` disseminates who is alive, and this spike turns that alive-set into ownership. Because `f` is deterministic and stateless, it needs no protocol of its own; the moment everyone agrees on the membership view, they automatically agree on placement. (Contrast the row above it in the README: **desired state → `06_raft.bl`**, because there the *specific* answer matters and conflict-free convergence would converge to the wrong thing.)

Cross-references:

- **`07_gossip_swim.bl`** — supplies the membership/health view that `f` consumes. Sharding without a converged membership view routes to nodes nobody agrees exist.
- **`06_raft.bl`** — the neighbouring class. Desired state (`which host runs billing`) is exactly the kind of truth placement must *not* be asked to carry: placement is derived and conflict-free, fate-sharing config is not.
- **`03_orset.bl`** — when placement must be *edited* by humans (manual pins, drains) rather than computed, add/remove semantics (OR-Set) take over; the auto-computed ring is what you fall back to for the unpinned keys.

Ring vs HRW, operationally: HRW wins on simplicity — stateless, no ring to keep in sync, trivial to weight and to reason about; the cost is an O(N) hash scan per lookup. The ring wins when N is large or lookups must be O(log N), at the price of maintaining `N·V` ring points everywhere.

## What's real vs modelled

**Real.** The two algorithms are actually implemented in bl and actually asserted. The hash is a real portable 32-bit hash (`erlang/phash2`). Churn is *measured*, not asserted from theory: the spike re-places all 1000 keys under the 5-node and 4-node views and counts the differences. The balance histogram is a real group-by over those 1000 placements. The property under test — *minimal churn + balance* — is the defining property of the algorithms, and it would fail loudly if the mechanism were wrong.

**Modelled.**

- **Node failure is removing a string from a list.** There is no network, no sockets, no message loss. The transport in production is BEAM messaging; it is not what is under test here.
- **No data actually moves.** The spike counts *which keys would move*; it does not copy partitions or drop connections. Real rebalancing cost is proportional to this count — which is why the count is the right thing to measure.
- **Membership is a constant, not a view change.** That everyone agrees on the alive-set is assumed, not implemented — that is `07_gossip_swim.bl` / `06_raft.bl`. This spike tests only the function *after* membership is agreed.
- **Only node removal is exercised** (`nodes5 → nodes4`). Addition is mathematically symmetric and left as an exercise.
- **Single owner per key, no replication.** Production placement keeps R replicas — owner plus the next R−1 distinct successors — which the spike omits.
- **No weights, no load-awareness.** Both schemes make every node equal; heterogeneous fleets and hot-key rebalancing are out of scope.
- **One in-process sample.** Churn and balance wobble slightly run to run, because they depend on the fixed hash of a fixed 1000-key set.

**Not the production answer.** For placement there is no single blessed library the way `06_raft.bl` names Ra; you would use these algorithms directly (or a system built on them). The spike exists so you can see the mechanism, not trust a black box.

## Run it

```
./blx run research/fleet_spike/01_sharding.bl
```

Expected tail (numbers approximate; they wobble a little run to run):

```
── churn when 1 of 5 nodes fails (1000 keys) ──
  hash mod N:        80.x% of keys move  (near-total reshuffle)
  consistent hash:   2x.x% move  (~ the failed node's share)
  rendezvous (HRW):  2x.x% move  (only the failed node's keys)
── balance (HRW, 1000 keys over 5 nodes; ideal ~200 each) ──
  {"a" 2xx, "b" 1xx, "c" 2xx, "d" 1xx, "e" 2xx}

PASS 01_sharding  (consistent hashing + HRW minimise churn)
```

The final line is printed verbatim as:

```
PASS 01_sharding  (consistent hashing + HRW minimise churn)
```

Cold start (BEAM boot + compile of the spike) takes roughly **10–15 s** the first time; subsequent runs reuse a warm machine and are far quicker.

## Exercises

1. **Kill the virtual nodes.** Change `(def V 64)` to `(def V 1)`. Predict what happens to `ring-churn` and to the ring's balance before you run it. *Hint:* one point per node means each node's share is a single random draw — arcs become wildly uneven, so the removed node may own far more (or less) than ~20% of the ring, and ring balance can collapse. HRW is untouched. This is exactly *why* virtual nodes exist.

2. **Give the keyspace more samples.** Raise `(range 1000)` to `(range 100000)`. Predict how HRW's balance and churn change. *Hint:* by the law of large numbers the realized share of each node concentrates closer to `1/5`, so `hrw-churn` inches toward 20% and `spread` shrinks **as a fraction** of the ideal (though its absolute count grows like `√K`).

3. **Fail a different node.** Change `nodes4` to `["b" "c" "d" "e"]` (node `"a"` leaves). Predict the three churn numbers. *Hint:* ring and HRW churn both become *`"a"`'s* share, not a fixed 20% — whichever node leaves, that node's share is what moves. `hash mod N` stays ~80%, because it never cared which node left.

4. **Swap in a bad hash.** Replace `h` with `(defn h [s] (count s))` (string length). Predict the ring's and HRW's balance and spread. *Hint:* every `"svc-N"` of the same length collides onto one hash point, so keys pile onto a few nodes, `spread` explodes past 120, and the balance assertion fails — a direct demonstration that the *hash quality* is load-bearing, not incidental.

*Bonus:* **Add a node instead of removing one.** Build `nodes6 = ["a" "b" "c" "d" "e" "f"]` and measure churn `nodes5 → nodes6`. Predict ≈ `1/6` for ring/HRW (only keys now electing `"f"` move) versus ≈ `5/6` for `hash mod N`. Joins and leaves are the same law in opposite directions.
