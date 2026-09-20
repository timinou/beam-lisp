# Fleet tutorials — the algorithms of many nodes, explained

Eight step-by-step explainers, one per algorithm spike in
`research/fleet_spike/`. Each teaches the algorithm to a curious reader: the
problem it solves, the core idea, the invariant that makes it correct, a walk of
the actual bl code, where it fits the per-data-class fleet model, an honest
real-vs-modelled boundary, and exercises. Read [`../README.md`](../README.md)
first for the organizing idea; then read these in order for the full argument.

## The organizing idea (from `../README.md`)

> Consistency is chosen **per data class**. There is no one distributed
> algorithm for a fleet, because a fleet holds data with different needs, and
> every consistency choice is a CAP trade. Match an algorithm to each seam.

| data class | needs | algorithm | tutorial |
|---|---|---|---|
| **placement** | balanced, minimal churn | consistent hashing + rendezvous (HRW) | [01](01-sharding.md) |
| **events** | append-only, never conflict | G-Set δ-CRDT | [02](02-gset-crdt.md) |
| **routes / claims** | add + remove, coordination-free | OR-Set CRDT | [03](03-orset.md) |
| **membership / health** | one value, converge fast | LWW-Register | [04](04-lww.md) |
| **causality** | detect concurrency, no global clock | vector clocks | [05](05-vector-clocks.md) |
| **desired state** | ONE truth, no split-brain | Raft (consensus) | [06](06-raft.md) |
| **dissemination + failure** | spread + detect death robustly | gossip + SWIM | [07](07-gossip-swim.md) |
| the design choice itself | — | OT vs CRDT, justified | [08](08-ot-vs-crdt.md) |
| **all of them, composed** | a full fleet day | the capstone integration | [09](09-fleet-lifecycle.md) |

## The three threads that tie them together

1. **Semilattices converge for free.** 02, 03, 04, 08 — a merge that is
   commutative, associative, and idempotent converges from *any* delivery order,
   so replicas need no coordination. That algebraic fact is the whole reason
   CRDTs work, and why the AP data classes use them.

2. **Consensus is the deliberate exception.** 06 — desired state is the one class
   that *refuses* a CRDT, because conflict-free convergence would converge to a
   *wrong* answer ("which host runs billing"). Raft trades availability for
   agreement: a minority **stalls** rather than forking reality. The safety core
   is arithmetic — two majorities always overlap, so ≤1 leader per term.

3. **Causality is the primitive underneath.** 05 — before you can merge you must
   know *whether* two updates are concurrent. Vector clocks answer that with
   counters and messages, no synchronized time — the detector that tells the
   CRDTs when a merge is even needed.

## How to run any spike

```
./blx run research/fleet_spike/06_raft.bl     # one spike, prints PASS/FAIL
research/fleet_spike/run.sh                    # the whole suite
```

Cold `blx` starts cost ~10-15s each (JIT warmup), so the sweep takes a couple of
minutes — that latency is boot, not work.

## A word on fidelity

Every tutorial has a "what's real vs modelled" section. In short: each spike
**really implements** its algorithm in bl and **really asserts** its defining
property (minimal churn, order-independent convergence, split-brain refusal,
causal detection), but runs as an **in-process simulation** of nodes and
message delivery — no real sockets, because the transport is BEAM messaging in
production and is not the thing under test. Two specifics worth repeating:

- **02 runs on real `datom`** tx-datoms — the "datom log is a G-Set" claim is
  demonstrated on the actual database, not a toy.
- **06's production impl is Ra** (rabbitmq/ra, Jepsen-tested). The spike
  implements Raft's *safety core* (terms, majority vote, commit-by-majority,
  split-brain refusal) as pure state functions so the mechanism is visible; you
  would not hand-roll Raft in production, you would use Ra.
