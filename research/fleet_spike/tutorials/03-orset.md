# 03 — The OR-Set

The OR-Set is a set you can both *add to* and *remove from* that still converges
across replicas with zero coordination — because every add carries a fresh unique
tag and a remove can only strike the tags it has actually seen, so a concurrent
add always survives.

## The problem

A route table is a set of `name → backend` claims, and services come *and go*. The
set has to move in both directions: a backend registers a name, and later that
backend is decommissioned and the name must leave the table. Every naive way to
make that set converge across replicas fails in a specific, instructive way.

**A G-Set can't shrink.** Spike 02's G-Set merges by `union` — elegant, because
union is trivially commutative/associative/idempotent. But `union` only ever adds.
A decommissioned backend, once its claim is in the set, stays in the set forever;
the router keeps sending traffic to a corpse. Delete is not expressible.

**A local delete doesn't survive the merge.** Suppose gateway A deletes `web`
locally while gateway B still holds it. If merging is `union`, B's copy re-adds it
— the delete evaporates. You cannot "just remove" a member and then union, because
union has no memory of the removal.

**A wall-clock timestamp per element loses the wrong side of the race.** You might
try: each element carries `(value, timestamp)`, last write wins. Now two gateways
act at once — A decommissions `web`, B re-registers `web` onto a healthy new
backend. Clocks are skewed, timestamps collide, and on a tie or a fast clock the
*remove* wins. The service 404s even though a live backend just announced itself.
That is a customer-visible outage caused purely by an arbitrary race outcome.

The failure we care about, concretely: **A removes `web` while B concurrently
re-adds it.** We need a rule for that race that is (a) the same on every replica,
(b) reachable without a coordinator, and (c) biased toward *keeping* the name
resolvable rather than dropping it.

## The idea

The move that unlocks removal is a *separation*:

> Keep the grow-only part as **history**, and derive the **current value** from
> it. Don't delete history — mark which parts of it have been struck out.

Every `add(x)` mints a **fresh unique tag** — an identity for *that add event*, not
for the element `x`. So the internal state records, per element, the set of tags
ever minted for it. A `remove(x)` doesn't touch the element; it strikes out
(tombstones) exactly the tags it can *see* for `x`. The element is present iff it
still owns at least one un-struck tag.

Why this survives the race:

```
remove(x) strikes A_remove(x)      ← the tags the remover OBSERVED
concurrent add mints τ             ← a tag the remover never saw
τ ∉ struck                         ← you can't strike a tag you can't name
∴ x still has a live tag           ← ADD WINS
```

The punchline is that "add wins" is **not a policy you chose** — it is the *only*
semantics expressible without coordination. Remove-wins would require the remover
to tombstone a tag minted *after* it acted, i.e. to name something it has never
observed. That takes a round-trip. Add-wins takes nothing.

And note the paradox that makes it a CRDT at all:

```
internal state:  adds grow, tombstone-set grows   →  monotonic ↑
observable value: elements appear AND disappear    →  non-monotonic ↕
```

The state is a grow-only semilattice; the *value* projected out of it can shrink.
That separation is how a CRDT models removal while keeping its merge monotone.

For routes this is the safe bias. A false *present* (the add-wins outcome) means a
name resolves to a backend that may be stale — the router fails over to a live
claim, or 404s only if *every* claim for the name is dead. A false *absent*
(remove-wins) means a live backend is dropped from a healthy service. Prefer the
former: **availability of the name beats pruning precision.** (Hold that thought —
there is exactly one class where it flips, in *Where it fits the fleet*.)

## How it works

The whole algorithm is four functions over one state shape.

```
state  S  :=  (A, R)
  A : elem → P(Tags)      "adds"      — per element, the tags ever minted   (grows ↑)
  R ⊆ Tags                "removed"   — the tags struck out                 (grows ↑)

value(S)  :=  { e ∈ dom(A) |  A(e) \ R  ≠ ∅ }
              an element is present iff it owns ≥1 tag that is not struck

merge(S₁, S₂)  :=  ( λe. A₁(e) ∪ A₂(e) ,  R₁ ∪ R₂ )
              per-element union of tags; union of struck tags
```

**The law.** `merge` is a join-semilattice — it has the three algebraic
properties that make order irrelevant:

```
idempotent   S ⊔ S   = S          (merging a fact with itself changes nothing)
commutative  S₁ ⊔ S₂ = S₂ ⊔ S₁    (delivery order doesn't matter)
associative  (S₁ ⊔ S₂) ⊔ S₃ = S₁ ⊔ (S₂ ⊔ S₃)   (batching doesn't matter)
```

Each law is immediate: `∪` on sets has all three, and `merge` is just `∪` applied
per-element to `A` and wholesale to `R`. **∴** two replicas that have received the
same set of updates hold identical state, therefore project identical
`value` — no matter the order, no matter duplicated deliveries, no matter who
talked to whom first. That is convergence, and it is a property of the algebra,
not of the network.

`merge` is also **monotone**: `S ⊑ S₁ ⊔ S₂`. Merging never destroys information;
it only takes the join. A replica that has seen everything holds the top of the
lattice.

**Why add-wins necessarily follows.** Let replica A process `remove(e)` — it
strikes `A_A(e)`, the tags *it* holds. Let replica B concurrently `add(e)` with a
fresh tag `τ ∉ A_A(e)` (freshness is the precondition). After `merge`:

```
R        ⊇ R_A ∪ R_B      and  τ ∉ R_A (A never saw it),  τ ∉ R_B (B removed nothing)
A(e)     ⊇ A_A(e) ∪ {τ}   ∴  τ ∈ A(e) \ R  ⟹  e ∈ value(merge)     ∎
```

For `e` to be *absent* after the merge, `τ` would have to be in `R` — but `τ` was
minted after A acted, so no replica could have written it into `R` without first
observing the add. **∴** the concurrent add survives, deterministically, on every
replica. Add-wins is forced by the representation.

**The precondition: tag uniqueness.** If A and B could both mint the *same* tag for
different add events, a remove of one would strike the other. This is the exact
hazard spike 02 names for the G-Set's id space, with the same fix: **partition the
tag space per node.** The spike writes tags as `[:a 1]` and `[:b 2]` — the node id
prefixes the counter, so two nodes can never collide. Freshness of `τ` is what the
whole lemma rests on.

## Walkthrough

### Step 1 — The representation

```clojure
(defn or-empty [] {:adds {} :rems #{}})
```

One map, two fields: `:adds` is `elem → #{tag …}`, `:rems` is the set of struck
tags. That is the entire state. Note `:adds` is keyed by *element* and holds a
*set of tags* — the element is a name in a map, and its tags are the thing that can
be individually struck.

### Step 2 — `or-add` mints a tag

```clojure
(defn or-add [s elem tag]
  (update-in s [:adds elem] (fn [tags] (clojure.set/union (or tags #{}) #{tag}))))
```

Adding `elem` with `tag` unions that tag into the element's tag set, creating the
set if the element is new. Crucially the *tag* is supplied by the caller — the tag
is the identity of this add event. Adding the same element twice with two different
tags leaves *two* live tags for it; striking one still leaves the other, which is
precisely the mechanism that makes the race resolve in add's favour.

### Step 3 — `or-remove` strikes only what it observed

```clojure
;; remove tombstones exactly the tags currently OBSERVED for elem
(defn or-remove [s elem]
  (let [observed (get (:adds s) elem #{})]
    (update s :rems (fn [r] (clojure.set/union r observed)))))
```

This is the heart of the algorithm, and the comment says it: the remove reads
`(:adds s)` — *this replica's* view — and adds those tags to `:rems`. It cannot
strike a tag it has not seen, because it has no way to name one. That single line
is where "add-wins" comes from; no policy is written anywhere else.

### Step 4 — `or-value` derives presence

```clojure
;; an element is present iff it has at least one tag that is not tombstoned
(defn or-value [s]
  (set (keep (fn [[elem tags]]
               (if (seq (clojure.set/difference tags (:rems s))) elem nil))
             (:adds s))))
```

Walk the map of adds; for each element, subtract the struck tags from its own tags
with `clojure.set/difference`; if anything is left (`seq` non-empty), the element is
present, else `keep` drops it. The *value* is the only place removal becomes
visible — the state still remembers every tag ever minted.

### Step 5 — `or-merge` is the semilattice

```clojure
;; merge: union the adds (per element) and union the tombstones — a semilattice
(defn or-merge [x y]
  {:adds (merge-with clojure.set/union (:adds x) (:adds y))
   :rems (clojure.set/union (:rems x) (:rems y))})
```

`merge-with union` applies union per element key; a plain `union` for the strike
set. Two `union`s, nothing else — and from them falls the whole convergence proof
from `## How it works`. There is no conflict-resolution code because there is no
conflict: the join *is* the resolution.

### Step 6 — Concurrent adds converge

```clojure
(def a0 (-> (or-empty) (or-add "web" [:a 1])))
(def b0 (-> (or-empty) (or-add "api" [:b 1])))
(def merged (or-merge a0 b0))
(println "── concurrent adds converge ──")
(println (str "  A added web, B added api → merged sees " (pr-str (or-value merged))))
```

Two gateways each start with their own single claim — A tags `web` as `[:a 1]`
(node `a`, counter `1`), B tags `api` as `[:b 1]`. (The tags are the per-node id
partition in miniature: `:a`/`:b` never collide.) After one merge both claims
survive:

```
── concurrent adds converge ──
  A added web, B added api → merged sees #{"web" "api"}
```

This is the easy case — additions are monotone, so `merge` = union and nothing can
be lost. It establishes the baseline before the interesting race.

### Step 7 — The add/remove race (the point of the spike)

```clojure
(def a1 (or-remove merged "web"))                  ; A tombstones [:a 1]
(def b1 (or-add merged "web" [:b 2]))              ; B adds web with a new tag
(def converged (or-merge a1 b1))
(println "── add/remove race (A removes web, B re-adds concurrently) ──")
(println (str "  A's view alone:      " (pr-str (or-value a1))))
(println (str "  B's view alone:      " (pr-str (or-value b1))))
(println (str "  after merge (add-wins): " (pr-str (or-value converged))))
```

Both replicas start from the same `merged` state, then diverge *concurrently* —
neither sees the other's action before acting, which is what makes it a race and
not a sequence.

- **A's move:** `or-remove` strikes `[:a 1]` — the only tag A has ever seen for
  `web`. A's own view loses `web`; it still holds `api`.
- **B's move:** B re-adds `web` under the *fresh* tag `[:b 2]` — a tag A cannot
  possibly have struck, because A has never seen it.
- **The merge:** `A(web) = #{[:a 1] [:b 2]}`, `R = #{[:a 1]}`. `[:a 1]` is struck;
  `[:b 2]` is live. So `web` is present.

```
── add/remove race (A removes web, B re-adds concurrently) ──
  A's view alone:      #{"api"}
  B's view alone:      #{"web" "api"}
  after merge (add-wins): #{"web" "api"}
```

A alone thinks `web` is gone; B alone thinks `web` is there; the merge keeps it.
Add won the race, on both replicas, with no negotiation. (`api` is present
throughout — B never removed it, and A's remove only named `web`.)

### Step 8 — A clean remove really removes

```clojure
(def clean (or-remove converged "api"))            ; nobody re-adds api
(println "── a clean remove ──")
(println (str "  after removing api (uncontested): " (pr-str (or-value clean))))
```

If nobody races it, a remove does exactly what you want: `api`'s only tag
`[:b 1]` goes into `:rems`, its tag set is fully covered, and the element drops out
of `value`:

```
── a clean remove ──
  after removing api (uncontested): #{"web"}
```

This is the pair to Step 7. The spike is not "the OR-Set ignores removes"; it is
"removal is precise — it removes everything you have actually seen, and *only* what
you have seen." A removal the remover has full knowledge of is honoured; a removal
racing an add it can't see is not. Same function, two outcomes, distinguished
purely by what the remover had observed.

### Step 9 — Commutativity, checked rather than asserted

```clojure
(def ab (or-merge a1 b1))
(def ba (or-merge b1 a1))
(def commute (= (or-value ab) (or-value ba)))
```

The two racing states are merged in both orders. Because `merge` is commutative,
`ab` and `ba` project the same value — order-independent convergence, measured on
the actual objects rather than argued on paper.

### Step 10 — The assertions

```clojure
(def ok (and (= #{"web" "api"} (or-value merged))     ; concurrent adds both survive
             (= #{"api"} (or-value a1))                ; A removed web, still sees api
             (= #{"web" "api"} (or-value b1))          ; B re-added web (never removed api)
             (= #{"web" "api"} (or-value converged))   ; ADD WINS after merge
             (= #{"web"} (or-value clean))             ; uncontested remove of api works
             commute))                                 ; merge is commutative
(println "")
(println (str (if ok "PASS" "FAIL") " 03_orset  (add-wins removable set converges without coordination)"))
```

Every claim from `## The idea` is a predicate: adds survive (`merged`), a replica's
local view after a remove is genuinely missing the element (`a1` = `#{"api"}`), the
race resolves to *add* on merge (`converged`), a clean remove is honoured (`clean`),
and the merge commutes. All six hold → the run prints `PASS`.

## Where it fits the fleet

From the fleet README's per-data-class map, this spike serves the fourth row:

| data class | example | needs | algorithm | spike |
|---|---|---|---|---|
| **routes / claims** | name → backend, add and remove | converge without coordination, support removal | **OR-Set CRDT** | `03_orset.bl` |

The whole point of the README's organising idea is that a fleet holds data with
*different* needs, and consistency is chosen per class. The routes/claims class
sits on the AP side of the CRDT/Raft boundary, and the boundary is drawn by asking
one question: **is *any* convergent answer fine, or only *the agreed* one?**

- **vs. desired state → Raft (`06_raft.bl`).** "Which host runs `billing`" must not
  silently converge to two answers; that class deliberately refuses a CRDT and pays
  for consensus. "Which backends claim the name `web`" is the other sort — a set,
  where a multi-valued answer (several live backends for a name) is *useful*, not
  wrong. So it gets a CRDT, and it stays available under partition.
- **vs. events → G-Set (`02_gset_crdt.bl`).** Events are append-only — they *should*
  never leave the set. Routes must. That single difference ("must support removal")
  is exactly why the G-Set's `union` is not enough and the OR-Set's tagged adds are
  needed. The two share the same semilattice skeleton; the OR-Set just adds the
  strike-set that lets the *value* shrink while the *state* keeps growing.
- **vs. membership/health → LWW-Register (`04_lww.bl`).** A health status is one
  value per node that changes over time; LWW picks a deterministic winner by
  `(timestamp, node-id)`. A route table is a *set of claims*, and a per-claim LWW
  would let a stale, skewed-clock remove silently clobber a live re-registration —
  the Step-7 failure. Per-element tags sidestep clocks entirely for the
  add/remove axis, and the add-wins bias keeps the name resolvable.
- **vs. causality → vector clocks (`05_vector_clocks.bl`).** Vector clocks are the
  primitive that tells "newer" from "concurrent". The OR-Set doesn't need them for
  this axis, because it doesn't ask *who was first* — it sidesteps the question by
  keeping both. Unique tags are the cheaper substitute here: freshness, not
  ordering, is what the correctness proof requires.

**Why add-wins is the right default for routes.** A route table's job is to make a
name resolvable. The two error modes are asymmetric: keeping a stale claim costs a
failed connection that fails over to another live claim; dropping a live claim
costs a hard 404 for a service that is up. Availability of the name dominates. And
an `add` is usually a deliberate "this backend is serving now" announcement, so the
racing add is a better bet than the racing remove. Add-wins, with no coordination,
gives the fleet the bias it wants *for free* — the semantics and the desirable
default coincide.

**The one place it flips.** For *security revocations* — revoking a compromised
credential, a lease, a capability — you want remove-wins, or better, consensus
(the README's "only *the agreed* answer is fine" class → Raft). An add-wins set
would let a racing re-claim resurrect a revoked credential. Same algorithm,
opposite requirement: the lesson is that the semantics must be matched to the data
class, and routes are not revocations. See `08_ot_vs_crdt.bl` for the design
argument underneath all of this.

## What's real vs modelled

**Real, exercised as-is:**

- The **OR-Set mechanism itself** — `or-add` (tag minting), `or-remove`
  (observed-only strikes), `or-value` (live-tag projection), and `or-merge` (the
  per-element join) — is implemented from scratch in bl, and the operations are
  the genuine article, not a stand-in for a library call.
- The **defining properties are genuinely asserted**, not narrated: add-wins after
  a concurrent race, honoured clean removal, and commutativity, all checked as
  equality predicates over `or-value` (Step 10). If the mechanism were wrong the
  run prints `FAIL`.
- The **algebra is faithful.** `or-merge` composes plain set unions, so the
  semilattice laws hold in the code exactly as in the proof on paper.

**Modelled or simplified — the honest boundary:**

- **There is no transport and no simulated message layer here.** Unlike spines
  that drive a peer with reordering and partitions, this spike is a *pure
  algebraic demonstration*: the "two gateways" are two state values, and "gossip"
  is a direct `(or-merge a1 b1)` call. No sockets, no in-process mailbox, no
  delivery reordering. The convergence claim is proved by the join-semilattice
  laws, which is exactly why the direct-call demonstration is legitimate — but do
  not read the two `def`s as two running nodes.
- **Tags are hand-written, not minted.** `[:a 1]` and `[:b 2]` are literal
  `[:node counter]` values chosen by the author. The spike never implements
  per-node tag allocation; it *relies on* freshness as a precondition. Real
  deployments mint tags from a per-node epoch/counter and must guarantee the
  partition, or tag collision turns add-wins into remove-wins (Exercise 1).
- **Removal takes no tag argument.** `or-remove` strikes *all* locally observed
  tags of an element. That is the standard OR-Set remove (a remove aims at
  everything the remover can see), but the more general formulation lets a caller
  pass a specific tag set. Only the observed-all form is exercised.
- **No tombstone compaction.** The `:rems` set grows forever; the state size is
  Θ(number of adds ever). Production OR-Sets (Riak's ORSWOT, delta-CRDT libraries)
  compact with a causal context / interval tree so tombstones can be discarded once
  every replica has seen them. Fine for a spike; not for years of route churn.
- **The value is set-semantic, keyed by whatever string you pass.** The spike's
  elements are names (`"web"`, `"api"`); a name with two backends would collapse to
  one element unless you make the element a `{name, backend}` claim (Exercise 4).

## Run it

```
./blx run research/fleet_spike/03_orset.bl
```

Expected output ends with:

```
PASS 03_orset  (add-wins removable set converges without coordination)
```

(The value sets printed during the walkthrough are unordered — they come from
Erlang sets/maps, so `#{"web" "api"}` may print in either order. The assertions are
written order-independently, which is why they hold regardless.) Cold start costs
~10–15s (JIT warmup); that latency is boot, not work.

## Exercises

1. **Kill tag freshness — watch add-wins collapse.** In Step 7 change B's re-add
   from `(or-add merged "web" [:b 2])` to `(or-add merged "web" [:a 1])` (reusing
   A's tag). Predict first, then run: A's remove already struck `[:a 1]`, so the
   merged state has `web`'s only tag in `:rems` → `converged` = `#{"api"}` and the
   assertion `(= #{"web" "api"} (or-value converged))` fails → **`FAIL`**. Lesson:
   freshness is load-bearing; a colliding tag turns the semantics remove-wins. This
   is the G-Set id-collision hazard of spike 02 re-appearing on the tag axis.

2. **Verify idempotence and associativity by hand.** Add
   `(def idem (= (or-value (or-merge ab ab)) (or-value ab)))` and a third racing
   state `c1` (e.g. `(or-add converged "db" [:c 1])`), then assert
   `(= (or-value (or-merge (or-merge a1 b1) c1)) (or-value (or-merge a1 (or-merge b1 c1))))`.
   Predict: both hold, still `PASS`. Extra deliveries and arbitrary batched merges
   change nothing — that is idempotence and associativity, the two laws Step 9
   doesn't exercise.

3. **A remove is a strike, not a ban.** After `clean`, do
   `(or-add clean "api" [:a 7])` and inspect `or-value`. Predict: `api` is back →
   `#{"web" "api"}`. The remove struck the tag it saw; a *new* tag mints fresh
   membership. Nothing prevents re-registration — which is correct for a route
   that came back online.

4. **Model two backends for one name.** Change the elements from bare names to
   route claims, e.g. add `{:name "web" :backend "b1"}` with `[:a 1]` and
   `{:name "web" :backend "b2"}` with `[:b 1]`. Predict: `or-value` returns both
   claims; removing one leaves the other, and the merged answer is a *multi-valued*
   route. This is the OR-Set giving you several live claims per name — the shape a
   router actually wants — and it shows that element granularity is your choice:
   the algorithm converges whatever you make an element.
