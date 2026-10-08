# 08 — Two ways to un-diverge: OT vs CRDT, and why a fleet picks CRDT

**Thesis.** Operational Transformation and CRDTs both make concurrent edits
converge on one shared value — but OT buys convergence with a *central authority
and hard-to-prove transform properties*, while a CRDT buys it with *immutable
ordered ids and a merge that is a join-semilattice*; a fleet, which has no
central authority for its AP data by design, must therefore run CRDT there and
save its single authority for the one class that needs it (desired state, Raft).

This is the suite's justification spike: it earns, by implementing both
mechanisms side by side on the same conflict, the conclusion stated in
`fleet_spike/README.md` §"Why CRDT and not OT".

---

## The problem

Start with a shared sequence, `"AC"`, and two replicas that edit it at the same
time — the classic minimal conflict:

- site 1 inserts `"B"` at index 1 → its buffer now reads `"ABC"` (B after A).
- site 2 inserts `"X"` at index 0 → its buffer now reads `"XAC"` (X before A).

Each site is *locally correct*. The trouble is the exchange. An edit is
represented as an index — `[:ins i c]` — and **an index is a claim about a
coordinate that concurrent edits silently move.**

Apply the two ops naively, in the other order on each site:

```
site 1:  "ABC"  +  [:ins 0 "X"]   →  "XABC"
site 2:  "XAC"  +  [:ins 1 "B"]   →  "XBAC"
```

The two replicas now hold different strings, forever. Neither is "corrupt" —
site 2's op was perfectly reasonable *against the state it was authored on*. But
site 2's index 1 no longer points where site 1 meant it to, because site 2's own
insert of X shifted every later coordinate right by one. The raw op carried a
stale index into a changed buffer. ✗ divergence.

This is not a corner case; it is the *normal* case whenever replicas edit
concurrently and you replicate operations by position. So the real question is:
how do you make two replicas reconverge? There are exactly two families of
answer, and they cost very different things.

---

## The idea

**OT — repair the coordinates after the fact.** Keep positions as indices, but
when a concurrent op arrives, *transform* its index against the ops you already
applied, so that its original *intent* survives. Site 2's B was meant to sit
right after A; if A has meanwhile moved to index 2, B's index must shift too.
Transformation is a repair pass over operation indices.

**CRDT — make position intrinsic.** Stop describing position by counting
characters. Give every inserted element an identity that is *globally ordered*
and *never changes* — here a small ordered key such as `[2]` — and let the
element's key say where it belongs. Then merging is pure set union and rendering
is sorting by key.

The intuition, one image each:

- OT is a **shared whiteboard with a cartographer in the room.** Every stroke is
  recorded as a *coordinate on the current map*; when the map changes, the
  cartographer rewrites outstanding coordinates so they still mean the same
  place. Take the cartographer away and coordinates drift.
- CRDT is a **map where every landmark carries permanent GPS.** Overlay two maps
  and each landmark lands where it belongs, no matter which overlay you do
  first.

Written as conditions:

```
OT:    converges  ⟸  one authority totally-orders ops  ∧  transforms obey TP1 ∧ TP2
CRDT:  converges  ⟸  merge is a join-semilattice (commutative ∧ associative ∧ idempotent)
```

The whole design decision lives in that asymmetry: **OT's convergence
precondition includes an authority; CRDT's does not.**

One more distinction worth pinning now, because everything else follows from it:
an **OT op is a command** (apply-once, order-sensitive — it `+`'s a `1`), while
**CRDT state is data** (merge-idempotent, order-free — it `∪`'s a set). Commands
need a serialiser; data does not.

---

## How it works

### OT's law: shift the index, and pray the transforms are right

Model an insert as `[:ins i c]`: put character `c` at index `i`. To transform an
op against a *concurrent* op, you only need to know where the other op inserted:

```
T([:ins i1 c1], [:ins i2 _]) =
    if i2 ≤ i1  →  [:ins (i1+1) c1]      ; a concurrent insert at/before me pushed me right
    otherwise   →  [:ins i1 c1]           ; it happened after me; leave me alone
```

Why the shift: if someone inserted to my left, everything from my position onward
moved one slot right, so to stay *after the same neighbour* I must land one slot
later.

Correctness for two sites rests on **TP1** (Transformation Property 1): for any
base state and concurrent ops `a`, `b`,

```
apply(apply(S, a), T(b, a))  =  apply(apply(S, b), T(a, b))
```

i.e. whichever order the two ops are delivered in, and whichever one each site
transformed against the other, the result is identical. The spike checks exactly
this instance — `op1`/`op2` both land on `"XABC"`.

But convergence in the two-site case is the *easy* case. As soon as a third
concurrent op is involved you also need **TP2** (intent preservation): the
transform must compose correctly so that no op's effect is lost or doubled in the
presence of an op that one site saw and the other didn't. TP1 ∧ TP2 are famously
hard to get right — the OT literature is full of algorithms that passed their
authors' examples and failed in the field. And note the whole scheme *assumes
someone imposes one total order on the ops* (a server, or a total-order
protocol): to transform `b` against `a` you must know that `a` came first. That
someone is a **central authority** — the load-bearing assumption this spike makes
visible.

### CRDT's law: union is a join-semilattice, so order is irrelevant

Represent each character as an immutable element with an ordered key:

```
{:pos <immutable ordered id>  :site <tiebreak>  :ch <char>}
```

- **Insert** = add an element whose `:pos` sits between its two neighbours.
- **Merge** = set union `∪` of two replicas' element sets.
- **Render** = sort by `(:pos, :site)` and concatenate `:ch`.

`∪` is a join-semilattice, which you can verify on any sets in one line each:

```
commutative   A ∪ B = B ∪ A
associative   (A ∪ B) ∪ C = A ∪ (B ∪ C)
idempotent    A ∪ A = A
```

∴ any delivery / merge order yields the *same set*, and rendering a set is a
deterministic function, so every replica renders identically. That is **Strong
Eventual Consistency** with no coordination at all.

Idempotence earns its keep separately: it is what makes retries and duplicate
delivery safe. A re-delivered op adds an element that is *already in the set* —
an identical map — so it vanishes into `∪`. At-least-once transport needs no
dedup bookkeeping when merge is idempotent.

Contrast the failure mode: an OT op applied twice inserts twice (a command
re-run); a CRDT element merged twice is a no-op (data re-joined). This is the
deep reason a fleet prefers CRDT for anything it must deliver over an unreliable
network.

---

## Walkthrough

The spike prints three labelled blocks — OT, CRDT, verdict — then the final
`PASS`/`FAIL` line. We follow the code in that order.

### 1. The transform function (OT's repair pass)

```clojure
(defn ot-transform [op against]
  (let [[_ i1 c1] op [_ i2 _] against]
    (if (<= i2 i1) [:ins (inc i1) c1] op)))         ; shift right if other inserted at//before
```

`op` is the op I authored; `against` is the concurrent op I just learned about.
If `against` inserted at or before my index (`i2 ≤ i1`), my index must move one
to the right. Notice what this function *demands*: it must **see the other op**,
which means something has to deliver both ops in a known relative order — the
coordinator again.

### 2. Applying an op is a plain splice

```clojure
(defn apply-op [s [_ i c]] (str (subs s 0 i) c (subs s i)))
```

Insert `c` at index `i`: take everything before, the char, everything after. No
transformation happens here — this is the raw operation, deliberately.

### 3. The scenario

```clojure
(def base "AC")
(def op1 [:ins 1 "B"])                              ; site 1: AC → ABC
(def op2 [:ins 0 "X"])                              ; site 2: AC → XAC
```

`base` is the shared starting buffer; the two ops are the concurrent edits.

### 4. Two sites, mirrored transforms, convergence

```clojure
(def s1-final (apply-op (apply-op base op1) (ot-transform op2 op1)))
(def s2-final (apply-op (apply-op base op2) (ot-transform op1 op2)))
```

Trace each site:

- **site 1:** own op first — `"AC"` + `[:ins 1 "B"]` → `"ABC"`. Then transform
  site 2's op: `T([:ins 0 "X"], [:ins 1 "B"])` asks `1 ≤ 0` → false, so it is
  left unchanged. Apply → `"XABC"`.
- **site 2:** own op first — `"AC"` + `[:ins 0 "X"]` → `"XAC"`. Then transform
  site 1's op: `T([:ins 1 "B"], [:ins 0 "X"])` asks `0 ≤ 1` → true, so it becomes
  `[:ins 2 "B"]`. Apply to `"XAC"` → `"XABC"`.

Both land on `"XABC"`. The printed block:

```clojure
(println "── OT: transform indices against concurrent ops ──")
(println (str "  site1 (op1 then T(op2)): " s1-final))
(println (str "  site2 (op2 then T(op1)): " s2-final))
(def ot-converged (= s1-final s2-final))
(println (str "  converged: " ot-converged "  — but only because a coordinator ordered op1<op2 identically for both"))
```

outputs:

```
── OT: transform indices against concurrent ops ──
  site1 (op1 then T(op2)): XABC
  site2 (op2 then T(op1)): XABC
  converged: true  — but only because a coordinator ordered op1<op2 identically for both
```

Read the caveat in that last line carefully — the spike is telling on itself.
The transforms only line up *because both sites applied the ops in the same
relative order* (`op1` before `op2`), which in a real system is a server's job.
Strip the ordering authority and the transform has nothing to transform against.

### 5. Elements with intrinsic ids (the CRDT)

```clojure
(defn elem [pos site ch] {:pos pos :site site :ch ch})
;; base "AC": A at pos [1], C at pos [3]
(def base-crdt #{(elem [1] :base "A") (elem [3] :base "C")})
;; site 1 inserts B between A(1) and C(3) → pos [2]
(def s1-crdt (clojure.set/union base-crdt #{(elem [2] :s1 "B")}))
;; site 2 inserts X before A(1) → pos [0]
(def s2-crdt (clojure.set/union base-crdt #{(elem [0] :s2 "X")}))
```

No index anywhere. Each element owns a key: A is `[1]`, C is `[3]`, and the new
inserts choose keys *between* their neighbours — B gets `[2]` (between A and C),
X gets `[0]` (before A). The keys leave gaps on purpose so a later insert can
always find a slot between two existing ones. A replica is just a **set of
elements**.

### 6. Render = sort by key

```clojure
(defn render [s]
  (apply str (map :ch (sort-by (fn [e] [(:pos e) (str (:site e))]) s))))
```

The whole "where does this character go?" question is answered by the key. The
`:site` string breaks ties so the order is total and deterministic even if two
keys collide. `render` is a pure function of the set — the same set always gives
the same string.

### 7. Merge = union; order does not matter

```clojure
(def crdt-merged (clojure.set/union s1-crdt s2-crdt))
(println "── CRDT: intrinsic position ids, merge = union ──")
(println (str "  site1 alone: " (render s1-crdt) "   site2 alone: " (render s2-crdt)))
(println (str "  merged (union, sorted by pos): " (render crdt-merged)))
;; union is commutative ⇒ order of delivery cannot change the result
(def crdt-converged (= (render (clojure.set/union s1-crdt s2-crdt))
                       (render (clojure.set/union s2-crdt s1-crdt))))
(println (str "  converged regardless of merge order: " crdt-converged))
```

Before merge, the replicas genuinely disagree (as they must — they've seen
different ops): site 1 alone renders `ABC`, site 2 alone renders `XAC`. Merge is
one `∪`, and sorting the result by key yields `X(0) A(1) B(2) C(3)` → `"XABC"` —
*both* inserts survive, in the right place, with no transform function invoked.
The convergence check is then almost tautological, and that is the point: it
compares `∪` in one order against `∪` in the other, because commutativity of the
merge *is* the convergence guarantee. Output:

```
── CRDT: intrinsic position ids, merge = union ──
  site1 alone: ABC   site2 alone: XAC
  merged (union, sorted by pos): XABC
  converged regardless of merge order: true
```

### 8. The verdict for a fleet

```clojure
(println "── why a fleet chooses CRDT ──")
(println "  OT   needs a central authority + TP1/TP2-correct transforms (hard to prove).")
(println "  CRDT needs only that merge be a semilattice (union) — no authority.")
(println "  A fleet's AP data (events, routes, health) has NO central authority by")
(println "  design, so CRDT fits; desired state DOES want one authority → Raft (06).")
```

The two mechanisms reached the *same string* (`"XABC"`) by opposite means — OT by
adding a coordinator and a proof obligation, CRDT by adding ids and a lattice.

### 9. The assertions and the PASS line

```clojure
(def ok (and ot-converged                  ; OT converges — WITH a coordinator ordering ops
             crdt-converged                ; CRDT converges — with NO coordinator
             (= "XABC" (render crdt-merged)) ; both inserts survive, correctly ordered
             ;; the point: CRDT needed no transform fn and no authority
             (= (render (clojure.set/union s1-crdt s2-crdt))
                (render (clojure.set/union s2-crdt s1-crdt)))))
(println "")
(println (str (if ok "PASS" "FAIL") " 08_ot_vs_crdt  (both converge; CRDT needs no central authority → fits a fleet)"))
```

Four things must hold — OT converged, CRDT converged, the merged content is
`"XABC"`, and the merge commutes — and then the spike prints its `PASS`.

---

## Where it fits the fleet

This is the **meta-spike**: it does not serve one data class, it justifies the
algorithm *choice* for all the AP classes at once. The fleet model
(`fleet_spike/README.md`) factors data by need and matches an algorithm to each
seam; this spike defends the CRDT half of that table.

| data class | example | algorithm | spike | CRDT? |
|---|---|---|---|---|
| **desired state** | which host runs `billing`; config | **Raft** | `06_raft.bl` | ✗ deliberately |
| **events** | metrics, audit, latency | **G-Set δ-CRDT** | `02_gset_crdt.bl` | ✓ |
| **routes / claims** | name → backend, add + remove | **OR-Set CRDT** | `03_orset.bl` | ✓ |
| **membership / health** | who is alive | **LWW-Register + gossip/SWIM** | `04_lww.bl`, `07_gossip_swim.bl` | ✓ |
| **placement** | which node owns a key | consistent hashing / HRW | `01_sharding.bl` | (needs no authority either) |
| **causality** | did X happen-before Y? | vector clocks | `05_vector_clocks.bl` | the primitive under CRDTs |

**Why CRDT, not OT, for the AP rows.** The fleet's design premise is that its
always-available data has **no central authority** — a coordinator is a single
point of failure and a partition casualty, the exact thing CAP forces you to give
up for an AP class. OT *requires* that central authority (the total-orderer we
flagged in the transform). Adopting OT would reintroduce, in every AP seam, the
one component the architecture exists to avoid. CRDT requires only an algebraic
merge, which needs nothing central.

Two supporting reasons, both visible in the code:

1. **We have no shared mutable buffer.** OT was invented for two people typing
   into one sentence, where preserving *edit intent* is the whole point. The
   fleet's AP data is sets, maps, and registers with natural joins — events are
   an append-only set (`02`), routes are add/remove sets (`03`), health is a
   last-writer-wins register (`04`). For those, "merge" is obvious and intent is
   not a thing to preserve.
2. **CRDT is native to datom.** A datom is `[e a v tx op]` — immutable,
   append-only, and a retraction is *itself a fact* (`op=false`), never an
   in-place mutation. So the datom log already *is* the simplest CRDT, a G-Set,
   and `merge(A,B) = A ∪ B` has all three lattice laws trivially. `02_gset_crdt.bl`
   proves this on **real datom tx-datoms**; the only hazard is id collision (two
   nodes both minting `e=3, tx=1000001`), fixed by **partitioning the id space
   per node** so `∪` is a clean disjoint merge.

**Why Raft, not CRDT, for desired state.** The one class where the fleet
*refuses* a CRDT is desired state: two nodes' conflicting "billing runs here"
must not silently merge into a convergent-but-wrong answer. `06_raft.bl`
implements exactly the mechanism that supplies the missing authority — leader
election, majority vote, commit-by-majority, and refusal to make progress in a
minority. Note the resonance: Raft's leader is the very "one orderer" that OT's
central transformer wanted, but the fleet pays for it *only* in the one class
that needs a single agreed truth. The CRDT/OT verdict and the Raft/CRDT boundary
are the same instinct at two different altitudes: **spend the authority where a
single truth is required; let everything else merge.**

**Why vector clocks matter here** (`05_vector_clocks.bl`): before a CRDT can
merge, it must distinguish "B is a newer version of A" from "A and B are
concurrent edits." Wall clocks cannot (skew); vector clocks can, using only
counters and message passing. That is the causal primitive underlying any
add-wins / LWW resolution.

---

## What's real vs modelled

**Real — genuinely implemented and asserted:**

- `ot-transform` is a real (simplified) index-shift transform, and `apply-op` a
  real buffer splice. The OT example genuinely diverges without the transform and
  genuinely converges with it.
- The CRDT elements really carry immutable ordered position ids; `render` really
  sorts them; `clojure.set/union` really is the merge; and the order-independence
  claim (`∪` one way versus the other) is really asserted, as is the revived
  content `"XABC"`.
- The join-semilattice laws are the actual guarantee — this is not a metaphor.

**Modelled — named but not under test:**

- **Nodes and message delivery are an in-process simulation.** There are no
  sockets; the transport is BEAM messaging in production and is not the thing
  under test here. This spike does not exercise reordering or partitions at all —
  "concurrent" is modelled by deriving both ops from the same `base` before
  merging (contrast `07_gossip_swim.bl`, which *does* partition the network).
- **OT's central authority is described, not built.** The spike plays the
  coordinator itself: it simply applies `op1` before `op2` for both sites, and
  never implements a server or a total-order protocol. It also does not *prove*
  TP1/TP2 — it demonstrates convergence on **one** scenario and relies on a
  transform that is correct for inserts but has no site-priority tiebreak (see
  Exercise 2, where it fails). This is a faithful model of OT's *cost structure*,
  not a production OT engine.
- **The CRDT here is a minimal sequence CRDT** (a fractional-index-like position
  plus a site tiebreak), not a full RGA/Yjs. Whole-number positions with gaps
  (`[0] [1] [2] [3]`) dodge the genuinely hard case — inserting *between* two
  adjacent ids — which production CRDTs solve with nested/dense ids or
  fractional reals. It also carries no removal/tombstones; that is `03_orset.bl`'s
  job.

The honest summary: the *mechanisms* (transform-based convergence, union-based
convergence) are really implemented and their defining properties really
asserted; the *network* is modelled in-process, exactly as the suite README
states for every spike.

---

## Run it

```
./blx run research/fleet_spike/08_ot_vs_crdt.bl
```

Cold start costs ~10–15s (JIT warmup) — that latency is boot, not work. The run
prints the OT block, the CRDT block, and the three-line verdict, ending with:

```
PASS 08_ot_vs_crdt  (both converge; CRDT needs no central authority → fits a fleet)
```

---

## Exercises

1. **Remove the repair and watch it break.** Delete the inner `ot-transform`
   calls so each site applies the other's raw op:
   `s1-final = apply-op (apply-op base op1) op2` and
   `s2-final = apply-op (apply-op base op2) op1`. Predict both strings before you
   run it — then explain why site 2's result disagrees with site 1's, and which
   site's character landed in the wrong place. (This is the naive case from
   `## The problem`, and it is what the transform exists to prevent.)

2. **Force a tie and find the gap.** Change both ops to insert at the *same*
   index, e.g. `op1 = [:ins 0 "X"]`, `op2 = [:ins 0 "Y"]`. Predict whether
   `ot-converged` stays true. (It does **not**: the toy transform shifts *both*
   ops right, giving `"XYAC"` on one site and `"YXAC"` on the other.) What extra
   information would the transform need to break this tie the same way on both
   sites — and where would it come from? Tie-break-with-a-deterministic-priority
   is the seed of a real OT tie rule, and the "where would it come from" is the
   central authority showing its face again.

3. **Collide the ids.** Give site 2's element the *same* key *and* the same site
   tag as an existing element, e.g. `(elem [1] :base "X")`. Predict whether the
   merge still converges, and whether `render` is deterministic if the
   `(:pos, :site)` sort key is no longer unique. Then make the `:site` tags
   genuinely unique (as in the spike) and re-predict. Relate the result to
   `02_gset_crdt.bl`'s id-partitioning fix — this is the same "who owns the id
   space" hazard, surfacing at the element level.

4. **Add a third concurrent op.** Introduce `op3 = [:ins 1 "Z"]` authored on the
   same base, and try to converge three sites using only the pairwise
   `ot-transform`. Predict where it fails, and identify whether you need TP1, TP2,
   or both. Then do the same with the CRDT: add a third replica set and merge all
   three with two `union` calls in different orders. Explain, in one sentence,
   why the CRDT needs no new code to handle the third site while OT does.
