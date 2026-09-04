# 01 — The primitive, the patterns, and how they relate

*A guidebook chapter for readers new to beam-lisp. No BEAM or Erlang
background assumed.*

---

## The primitive — one thing

beam-lisp runs on the BEAM, the virtual machine that Erlang and Elixir run on.
The BEAM's whole concurrency model is three facts:

1. **A process** is a cheap, isolated unit of execution — like a thread, but it
   shares *nothing* with other processes and costs almost nothing. Millions can
   exist at once.
2. **Each process has a mailbox** — a private queue. The only way processes
   interact is by sending each other messages, which land in the mailbox.
3. **A process reads its mailbox by pattern-matching** — it says "I'm waiting
   for a message that looks like *this*," and can take messages out of order.

That is everything. No shared memory, no mutexes, no channels in the VM itself.
Every concurrency abstraction built on the BEAM — servers, supervisors,
registries, event buses, task pools — is built from those three facts plus one
more: **when a process dies, other processes can be told.** A *monitor*
delivers a `:DOWN` message to your mailbox when the watched process dies.

Our claim: **a concurrent program is a set of processes, where each process is
a machine with states, and messages move it between states.** Each process is a
*transition relation* — "in state S, if message M arrives, go to state S′ (and
maybe send some messages)." Draw it as a graph: states are nodes, messages are
arrows. Two arrows exist whether you draw them or not: the **crash arrow**
(any state → dead, written `⊥`) and the **stop arrow** (deliberate exit).

Why this matters: beam-lisp is a Lisp, so code is data and beam-lisp can read
its own source. `system/model` (in `priv/lib/system/model.bl`) reads a
process's source and extracts the state-and-arrow graph *without running
anything*. Once the graph is data, you can ask questions about it — "can this
process ever reach a state where the balance is negative?" — with the shipped
prover (`priv/lib/system/`). **The program you write and the thing you verify
are the same object.** That is the bet the whole design stands on.

## The patterns — the vocabulary of arrows

There are exactly **four things you can do with a transition relation**, and
the 23 patterns are the useful named ways of doing them. (A *pattern* here
means what it means in architecture: a named, reusable shape with known
guarantees — not a library function.) Full specs: `docs/the-process-pattern-language.md`.

### Category 1 — State: arrows *within* one process

How a single process is shaped on the inside.

| pattern | plain meaning |
|---|---|
| **Loop-Carried State** | The process remembers something (a balance, a counter) by passing it to the next version of itself. The only way to have memory on the BEAM. |
| **Ask** | Send a message and wait for the answer. A function call across processes. |
| **Tell** | Send a message, don't wait. Fire-and-forget. |
| **Correlated Reply** | When many Asks are in flight, tag each so you know which answer is which. |
| **Timeout Edge** | If no answer in N ms, take this other arrow instead. |
| **Selective Receive** | Skip everything in the mailbox except a message shaped like *this*. |
| **Parked Waiter** | I can't answer you yet — hold the request, answer later. |

### Category 2 — Composition: arrows *between* processes

How processes are wired into a system.

| pattern | plain meaning |
|---|---|
| **Pipeline** | A's output is B's input. |
| **Demand** | The consumer says "give me 8 more" — the producer may not run ahead. This is *backpressure*: the cure for fast producers drowning slow consumers. |
| **Metered Stage** | A pipeline stage that obeys Demand. |
| **Fan-Out** | One sender, many receivers (broadcast, or work distribution). |
| **Fan-In** | Many senders, one receiver. |
| **End-of-Stream** | A defined "that's all" message, so consumers can finish cleanly. |
| **Registry** | A process whose whole job is remembering name → pid, so you find processes by *what they are* instead of by their address. |

### Category 3 — Failure: what happens on the `⊥` arrow

The BEAM's famous "let it crash" — these patterns are why crashing is safe.

| pattern | plain meaning |
|---|---|
| **Monitor** | Tell me (via my mailbox) if that process dies. One-way. |
| **Link** | If that process dies, kill me too. Two-way — for processes that are meaningless without each other. |
| **Healing Edge** | When it dies, start a fresh one. The supervisor's core move. |
| **Governor** | Heal at most 3 times in 5 seconds; if it keeps dying, give up and let *my* supervisor heal *me*. Stops infinite crash loops. |
| **Bounded Isolation** | Run this risky thing in a sacrificial process so its death can't hurt me. |

### Category 4 — Observation: reading the graph *without adding arrows*

The layer almost no other runtime has. Because the graph is data, you can
inspect it *before* boot.

| pattern | plain meaning |
|---|---|
| **Heartbeat** | Prove you're alive every N ms. |
| **Snapshot** | Tell me your current state — dashboards (`tooling/vitals.bl` does this live). |
| **Invariant Gate** | Prove *from source* that state never violates a rule (balance ≥ 0) — checked before the program runs, enforced as a crash if violated at runtime. |
| **Simulation** | Prove process A's behavior is a safe replacement for B's — the basis of hot code upgrade. |

## The relationships, in one picture

```
                    the primitive
              process + mailbox + pattern-match
                          │
        ┌──────────┬──────┴─────┬────────────┐
     State     Composition   Failure    Observation
     (7)         (7)          (5)          (4)        ← 23 patterns
        │           │            │            │
        └─────┬─────┴──────┬─────┘            │
              ▼            ▼                  ▼
        the 5 BUNDLES  (server, fence, registry, bus, supervisor)
              │                               │
              └──────── system/verify ────────┘
                   (category 4 applied to bundles)
```

**A bundle is not a new primitive — it is a named kit of patterns:**

| bundle | = patterns |
|---|---|
| **server** | Loop-Carried State + Ask + Tell + Correlated Reply + Timeout Edge |
| **fence** | Monitor + Ask + Timeout Edge + Bounded Isolation |
| **registry** | Loop-Carried State (a relation) + Ask + Monitor (auto-retract) |
| **bus** | Fan-Out + Demand + End-of-Stream |
| **supervisor** | Monitor·Link + Healing Edge + Governor + Invariant Gate |

Two design rules keep the vocabulary closed and teachable:

1. **Every stdlib function names exactly one pattern.**
2. **Every verifier diagnostic names a pattern.**

## What we are *not* claiming

`machine` is not an entity — its job is done by raw `receive` loops, which
`system/model` reads directly (this is why the `defprocess` proposal was
withdrawn; see `docs/the-fundamental-form.md`'s supersession note). `system` is
not an entity either — it is the observation layer (category 4) applied to all
the others. `flow` (`priv/std/flow.bl`) is the composition library (category 2)
as pull-based stages. Seven candidate "fundamental things" reduce to: **one
primitive, 23 patterns, five bundles, two libraries.**

---

*Next: [02 — the verbs](02-the-verbs.bl.md): how you actually talk to a
process.*
