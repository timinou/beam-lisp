# fleet_spike — the algorithms of many nodes, one machine

A fleet is where the "one lisp machine" design meets physics: multiple nodes, a
network that can split, clocks that can't agree. This suite implements — from
scratch, in bl, each one runnable and self-asserting — the distributed
algorithms a bl VPS fleet needs, and explains each one step by step for the
curious mind. The companion tutorials in [`tutorials/`](tutorials/README.md)
walk every line.

```
research/fleet_spike/run.sh          # run all algorithm spikes, print PASS/FAIL
./blx run research/fleet_spike/06_raft.bl
```

## The one idea that organizes everything: consistency is chosen per data class

There is no single "distributed algorithm" for a fleet, because a fleet holds
data with *different needs*, and every consistency choice is a CAP trade. The
maximalist move is not to pick one hammer — it is to **factor the system by what
each kind of data actually requires, and match an algorithm to each seam.**

The BEAM gives us the *transport* (location-transparent messaging) and the
process model. It does **not** give us consistency under partition — no runtime
can, because a network split is physics, not an API. (The proof by authority:
RabbitMQ, the most battle-tested stateful BEAM system there is, spent a decade
on Mnesia's "let distributed-Erlang handle it" and got chronically burned by
split-brain — then moved to Khepri, built on **Ra (Raft)**. Distributed Erlang
for transport; Raft for consistency.)

So we separate:

| data class | example | needs | algorithm | spike |
|---|---|---|---|---|
| **desired state** | which host runs `billing`, routes, config | ONE truth, no split-brain; low write rate | **Raft** (consensus) | `06_raft.bl` |
| **events** | metrics, audit, latency samples | append-only, high volume, must never conflict | **G-Set δ-CRDT** (grow-only) | `02_gset_crdt.bl` |
| **routes / claims** | name → backend, add and remove | converge without coordination, support removal | **OR-Set CRDT** | `03_orset.bl` |
| **membership / health** | who is alive, node status | fast dissemination, partition-tolerant | **LWW-Register + gossip/SWIM** | `04_lww.bl`, `07_gossip_swim.bl` |
| **placement** | which node owns a service / key | balanced, minimal churn on membership change | **consistent hashing / rendezvous (HRW)** | `01_sharding.bl` |
| **causality** | did event X happen-before Y? | detect concurrency without a global clock | **vector clocks** | `05_vector_clocks.bl` |
| **blobs** | checkpoints, artifacts | immutable, idempotent | **content-addressing** (no CRDT needed) | (spike 06 backups) |

The sharpest point is the boundary between rows 1 and 2–4:

> **Desired state is the one class where we deliberately REFUSE a CRDT.** You do
> not want two nodes' conflicting "billing runs here" to silently merge into a
> convergent-but-wrong answer. That class gets Raft precisely because
> conflict-free convergence would converge to the wrong thing. CRDT for the
> classes where *any* convergent answer is fine; Raft for the class where only
> *the agreed* answer is fine.

## Why CRDT and not OT

Both OT (Operational Transformation) and CRDT let replicas diverge and
reconverge, so it is a fair question which one a fleet should use. The answer is
CRDT, decisively — and `08_ot_vs_crdt.bl` demonstrates *why* with both
mechanisms side by side:

- **OT** exists to preserve *edit intent* on a **shared mutable buffer** (two
  people typing in one sentence). It needs a **central authority** to transform
  each operation against concurrent ones, and its correctness rests on
  transform-property proofs (TP1/TP2) that are famously hard. We have no shared
  mutable buffer, and a central transformer is the exact thing we are trying to
  avoid for the AP classes — so OT is both unnecessary and self-defeating here.
- **CRDT** exists to **converge replicas without coordination**. Its correctness
  is algebraic: show the merge is a join-semilattice (commutative, associative,
  idempotent) and convergence is guaranteed from any delivery order.

And CRDT is not merely acceptable — it is **native to datom**:

```
a datom is [e a v tx op]   — immutable, append-only
a retraction is itself a fact (op=false), never an in-place mutation
∴ the datom log is a G-Set (grow-only set), the simplest CRDT there is
  merge(A,B) = A ∪ B   — commutative, associative, idempotent ✓
```

The only thing that breaks the union is **id collision** (two nodes both minting
`e=3, tx=1000001`), which is the classic CRDT id-allocation problem with the
classic fix: **partition the id space per node** (each node prefixes its ids), so
two logs are disjoint and `∪` is a clean δ-CRDT merge. Retraction-as-fact keeps
the whole thing **monotonic** — exactly the precondition CRDTs require.
`02_gset_crdt.bl` proves this on real `datom` tx-datoms.

## datom's log *is* a Raft log

The other half of the elegance: a Raft state machine is a deterministic fold
over a replicated command log, and **datom is already a deterministic fold over
a log of transactions**:

```
transact!   → :tx-datoms [[e a v tx op] …]   the command
basis-t     → monotonic tx id                 the log index
since       → datoms after t                  the log tail / catch-up
load-facts! → apply pre-analyzed facts        the state-machine apply
```

So the fleet's desired-state layer is not "a database bolted onto Raft" — it is
"Ra replicates the tx-log datom already produces, and `load-facts!` is the state
machine." That is Datomic's architecture (a single transactor → storage →
peers) with Ra supplying the HA the open-source datom lacks. `06_raft.bl`
implements the Raft core (election, log replication, commit-by-majority,
split-brain refusal) from scratch so the mechanism is visible; in production the
impl is **Ra** (rabbitmq/ra — multi-Raft, Jepsen-tested).

## The spikes

| # | spike | algorithm | data class it serves |
|---|---|---|---|
| 01 | `01_sharding.bl` | consistent hashing + rendezvous (HRW) | placement |
| 02 | `02_gset_crdt.bl` | G-Set δ-CRDT (on real datom tx-datoms) | events |
| 03 | `03_orset.bl` | OR-Set (add-wins, with tombstone-free removal) | routes / claims |
| 04 | `04_lww.bl` | LWW-Register | membership / health status |
| 05 | `05_vector_clocks.bl` | vector clocks | causality detection |
| 06 | `06_raft.bl` | Raft (election + replication + single-writer + split-brain) | desired state |
| 07 | `07_gossip_swim.bl` | anti-entropy gossip + SWIM failure detection | dissemination |
| 08 | `08_ot_vs_crdt.bl` | OT vs CRDT, side by side | the design choice, justified |
| 09 | `09_fleet_lifecycle.bl` | **the capstone** — a whole 2-node fleet day (join→place→replicate→**gate**→migrate→partition→heal): HRW placement, log-shipping, OR-Set/G-Set flow, a z3 migration gate that refuses an incomplete plan then admits the proven one, quorum refusing a partitioned fork, and LWW heal — every algorithm integrated on real datom | all of them, composed |

## A note on fidelity

These are **algorithm spikes**: each implements the real mechanism in bl and
asserts its defining property (convergence, linearizability under majority,
minimal churn, causal detection), driven by an in-process simulation of nodes
and message delivery — including reordering and partitions. They do **not** open
real sockets between machines; the transport is BEAM messaging in production and
is not the thing under test here. Where a production library is the right answer
(Ra for Raft), the spike says so and implements the mechanism anyway, so the
curious mind sees how it works rather than trusting a black box. Every tutorial
has an honest "what's real vs modelled" section.
