# One engine, two fixpoints

A recursive rule computes a **fixpoint** — you apply it until nothing changes.
There are two ways to get there, and a database that verifies programs needs
both.

## Least and greatest

A **least** fixpoint grows from nothing. Seed the base facts, add whatever the
rules force, stop when a round adds nothing. "Which nodes are reachable from
here?" starts at one node and grows. Transitive closure, connected components,
shortest paths are all this shape, and it is what datom's recursive rules have
always computed.

A **greatest** fixpoint shrinks from everything. Seed the whole set, remove
whatever a rule condemns, stop when a round removes nothing. "Which states are
provably safe?" starts by assuming all of them and drops any that is bad or
steps to a dropped one. Safe regions, bisimulation, and invariant discovery are
this shape.

They are duals: grow-from-empty versus shrink-from-full, same idea run in
opposite directions.

## Both live in the engine

The greatest fixpoint is the exact dual of the least, so it belongs in the same
place, with the same optimization. `derive-gfp` mirrors `derive-semi-naive`: it
seeds the full relation and removes condemned tuples, and it carries the same
**semi-naive delta** — a tuple can newly fall only if one of its dependencies
fell last round, so each round re-checks the frontier, not the whole relation.

```clojure
(materialise-gfp seed survives?)            ; the largest subset closed under survives?
(materialise-gfp seed survives? depends-on?) ; with the delta, for less work
```

`survives?` is the per-step decision: does this tuple stay, given the current
survivors? It must be monotone in the set — growing the survivors can only keep
more. The engine drives the shrink; the decision is the caller's, and can come
from any source: a pure relation for a safe region, a structural test for
bisimulation, a theorem prover for invariant discovery.

## Why it matters that it is native

When the greatest fixpoint lived outside the database, it missed everything the
database does for the least one: the delta optimizer, the relation result shape,
and — the real prize — incrementality. A fixpoint in the engine can be
**re-computed on a change** rather than from scratch, because the engine already
tracks what changed. Editing one transition need only recompute the part of the
safe region that edit could affect.

There is a soundness line on that: re-using the previous answer is valid only
when the change **shrinks** the fixpoint (a stricter property, more bad states);
a change that could grow it must re-seed from full. Inside the engine, that
distinction is the same one it already draws for its incremental least fixpoints.

## The two answers are complementary

Reachability (least) tells you where a system *can* go. The safe region
(greatest) tells you where it can *never go wrong*. Liveness — *does every path
eventually reach the goal?* — is a least fixpoint again, seeded with the goal
and grown by "all successors already reach it", so a starvation loop is caught
precisely because it never enters the set. Safety shrinks, liveness grows, and
both are the same engine.

## Where it lives

- `datom.query.rules/derive-gfp`, `materialise-gfp` — the greatest-fixpoint
  driver, dual of `derive-semi-naive`, with the semi-naive delta.
- `system.gfp` — the verification surface: `gfp`, `safe-region` (AG),
  `bisimulation`, and `af` (AF, a least fixpoint), all over the engine primitive.
