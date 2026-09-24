# JS actor target — OTP behaviour: research backlog and roadmap

This folder records the gap between the BL-written JavaScript actor target and
BEAM/OTP, with research sheets written before the local lifecycle, server,
supervisor and table slices landed. **Start with [FEATURES.md](FEATURES.md)**
for current FEAT/FUP status and [the executable README](../js-actors/README.md)
for behavior actually verified now. Sections titled “prototype today” in the
older research sheets are **dated baselines**, not current-state inventories.

The original gap included no links, monitors, registered names, exit signals,
supervision or ETS. Local BL implementations of subsets now exist, with 457
acceptance checks at three scheduler budgets and a visible browser supervisor
recovery demo. Ports, NIFs, distribution, full ETS/OTP contracts and exact
numeric parity remain absent. The sheets continue to separate native OTP
semantics, target subsets and deferred decisions; they do **not** claim OTP
equivalence.

---

## How to read this folder

### Status legend

| mark | meaning |
|---|---|
| ✅ | **Verified in the prototype today.** Confirmed by reading `research/js-actors/runtime.bl` / `host.mjs` and by the README's measured results. |
| ◐ | **Substrate exists, contract does not.** The mechanism the contract needs is present (e.g. critical sections, the runnable queue) but the OTP-level guarantee is not. |
| ✗ | **Absent on the JS target.** No code path at all. |
| ⚙ | **Repo gap on the BEAM side.** Missing or partial in `priv/std/proc/**` independently of the JS target — a shared dependency. |
| ○ | **Unresolved design option.** A decision the deep-design pass must make; listed so it is not silently made by whoever writes the first line. |

### Per-topic template

Every workstream doc answers the same questions in the same order, so a future
design agent can be handed one section:

1. **Scope / topic map** — what is in, what is explicitly out.
2. **BEAM/OTP contract** — the semantics that must be reproduced (source of truth).
3. **Prototype today** — measured status, with file:line grounding.
4. **Missing invariants** — the gap list, each as a testable statement.
5. **Repo BL side** — what `priv/std/proc/**`, `priv/boot/**`, `lib/beam_lisp/**`
   and `docs/**` already settle, and where they are themselves incomplete (⚙).
6. **Design constraints derived from the prototype** — invariants the existing
   implementation already imposes on any OTP layer.
7. **Dependencies / wave order** — what must land before this can be verified.
8. **Risk** — what goes wrong if the layer is built wrong.
9. **Test / differential proof gates** — the observable acceptance criteria.
10. **Unresolved design options** — the ○ list.

### State of the worktree (read before trusting §3 of any doc)

The previous `dbdead74` exception baseline had 104 checks. The current target
passes **457 BL checks** at default/17/41-step budgets in Node; the browser
Worker passed 457 with timer ticks. FEAT-048/049/050/051/052 have verified
local slices, including a BL-written supervisor and `:set` table owner/heir
policy. `super-demo.html` visibly showed a child restart twice, a message
between them and graceful Stop. `proc.server/clause-plan` and
`proc.super/supervisor-plan` now share declarations with native adapters.
This is not BEAM parity: consult [FEATURES.md](FEATURES.md) and the actor README
for precise unsupported operations, trusted-code boundary and remaining gaps.

### Numeric research alongside the actor roadmap

[The exact numeric spike](04-exact-numeric-spike.md) and its reproducible
`numeric-spike.mjs` compare 17 native BEAM observations with a tagged BigInt /
scaled-decimal JS candidate. It identifies a necessary host BigInt primitive;
[FEAT-056](../../!tasks/features/FEAT-056-implement-exact-tagged-numeric-runtime-f.org)
is the unimplemented exact-numeric cutover, separate from the conditional
safe-Number proof in FEAT-055. Do not infer full numeric compatibility from
the spike.

### The one design rule

> *Do not grow the JavaScript adapter into an actor implementation: receive and
> scheduler policy belong in BL.*
> — `research/js-actors/README.md`, last line

This extends to every layer in this folder. The host supplies only
**mechanisms BL cannot synthesize cheaply** — a monotonic clock, task queue,
`park`/`resume`, runtime identity allocation and opaque bounded mutable table
storage. Links, monitors, names, supervisor restarts, table
owners/permissions and the event inbox recipient are
**policy over BL state** and belong in `runtime.bl` (or a BL module compiled
next to it). A decision to push any of them into `host.mjs` is a decision to
abandon the target's central claim.

---

## Cross-cutting invariants

These hold across every workstream. They are listed once here and referenced by
number.

- **C1 — Death is one atomic scheduling transaction.** `runtime.bl::rt-terminate!`
  now removes a local actor, retracts names/sink/timers, settles owned tables,
  sends each monitor `:down`, and propagates local link exits under one critical
  section. Preserve that chokepoint for new capabilities; no `send` should
  observe a half-dead process. `rt-proc-wait!` / `rt-proc-resume!` use the same
  `host/critical-enter` / `host/critical-leave` discipline.
- **C2 — Signals are ordered with messages between a pair.** BEAM guarantees
  that if A sends B a message then A dies, B sees the message before the exit
  signal (and vice versa). Any emulated signal must be appended to the mailbox
  through the same critical section as `rt-send`, never a separate channel.
- **C3 — Protocol shape deviations are explicit.** Native BL bundles use
  `[:DOWN ...]`/`[:EXIT ...]`, while this target emits `[:down ...]`/`[:exit ...]`
  and `[:ets-transfer ...]` as BL vectors. The shared `proc.server/clause-plan`
  declaration is lowered at ONE target seam that maps native `:DOWN` patterns
  to target `:down`. These are not BEAM tuples; expand a portable protocol only
  with explicit data-shape decisions and differential tests.
- **C4 — A name is a value where a pid goes.** `runtime.bl::rt-resolve` now
  handles local pid/name resolution for send/call/cast/stop. Native
  `docs/the-five-bundles.md` §0 also allows a name for `monitor`; this target's
  current `rt-monitor` still takes a pid, so name-as-value is a documented
  subset rather than a universal API claim.
- **C5 — Verification is over the source graph, not the target.** `system/model`
  and `system/verify` read the reader's tree; they do not run the program. A
  future architecture can therefore verify a BL program once and emit it to
  either target — the gate is not duplicated per backend (`○`, see README §Open
  decisions).
- **C6 — No parallel implementations.** Repo principle 2. A monitor implemented
  once for the JS runtime and again in a BL bundle is the failure mode. The deep
  design for each area must name the single implementation and the cutover.
- **C7 — Failure is a value in one shape.** `research/supervision-contracts/`
  proposes one diagnostic shape for supervision events (`:bl_diag true`, `:kind`,
  `:where`, `:restarts`). The JS target's exit/monitor reasons are the raw input
  to that shape; they must not invent a second vocabulary.

---

## Document map

| doc | covers | primary repo grounding |
|---|---|---|
| **[`01-process-lifecycle.md`](01-process-lifecycle.md)** | process identity & flags, spawn, exit reasons, **links**, **monitors**, `trap_exit`, exit signals, death as a value, signal ordering | `priv/boot/core.bl::spawn-link`,`::spawn-monitor`; `priv/std/proc/fence.bl`; `priv/std/proc/server.bl` (`:down` slot); `docs/the-process-pattern-language.md` §3.1–3.2 |
| **[`02-registry-and-supervision.md`](02-registry-and-supervision.md)** | registered names / `whereis`, GenServer conventions (`call`/`cast`/timeout/ordering), child specs, restart strategies, **intensity / governor**, shutdown, escalation, tree introspection | `priv/std/proc/reg.bl`; `priv/std/proc/super.bl`; `priv/std/proc/server.bl`; `lib/beam_lisp/server.ex`; `lib/beam_lisp/supervisor.ex`; `docs/the-maximalist-supervisor.md`; `docs/the-five-bundles.md` §5 |
| **[`03-boundaries-ets-ports-distribution.md`](03-boundaries-ets-ports-distribution.md)** | **ETS** (ownership, heir, atomicity), **ports** (two meanings — BEAM ports vs. this repo's `vm/ports`; the browser host-event inbox has a verified BL demo, while general ports remain unbuilt), **distribution** (nodes, remote pid/ref, global names, codec) | `priv/std/proc/table.bl`; `priv/std/vm/ports.bl`; `priv/std/proc/reg.bl` (single-node scope); `priv/lib/datom/blob*.bl`; `docs/the-maximalist-supervisor.md` §3.3 |

Read `01` before `02`; read `03` last. Within each doc, §2 (contract) and §9
(gates) are the parts a design pass must satisfy; §10 is the list it must close.
(`03` covers three boundaries, so it repeats those 10 positions per topic and
then consolidates the wave order in its §5.)

---

## Wave order and dependencies

The historical DAG below guided the cutover. W0/W1/W2/W3 and the local ETS
part of W4 now have tested target subsets; the actor suite has **457 checks**
under default/17/41-step budgets. The boxes describe dependency order, **not**
a claim that complete OTP contracts landed. Ports and distribution remain
research; consult [FEATURES.md](FEATURES.md) for current status.

```
W0  shared vocabulary + trace harness        (C2, C3; needs no OTP layer)
     │
W1  lifecycle: exit reasons, exit signals, links, monitors, trap_exit
     │   ├─► W2a names / registry (auto-retract uses monitors)
     │   └─► W2b GenServer conventions on the JS target (call/cast/timeout)
     │              │
     │              └─► W3 supervision (child specs, strategies, intensity)
     │                        │
     │                        └─► W4 boundaries
     │                              ├─ ETS (ownership needs W1 death semantics)
     │                              ├─ ports / host-event boundary (needs W0 + scheduler; separate FEAT)
     │                              └─ distribution (needs all of the above + a node concept)
     └─► W2c tree/process introspection (children, events, ledger)
```

| wave | depends on | why |
|---|---|---|
| W0 vocabulary + trace | — | every later gate compares two traces; the shape must be fixed first |
| W1 lifecycle | W0 | links/monitors *are* the signal vocabulary |
| W2a registry | W1 | retract-on-death is a monitor |
| W2b gen_server | W0 | needs `call` correlation + timeout edges, not links |
| W3 supervision | W1, W2a, W2b | a supervisor restarts a *startable named child* using monitors |
| W4 ETS | W1 | ownership transfer is triggered by owner death |
| W0 browser inbox | W0 | FEAT-046's typed input queue, BL sink and live Worker demo are verified; this does not depend on links/monitors |
| W4 port protocol | W0, W1 | owner death, per-port identity, close/backpressure/capabilities remain future design — see `03` §3.3 |
| W4 distribution | W1–W3 | a remote pid, a remote monitor and a remote restart all need the local versions first |

**W1's local lifecycle is now built** in BL. The narrow W0 inbox and local ETS
owner/heir transfer are verified; port owner death and remote monitoring remain
unimplemented and cannot inherit those local proofs by analogy.

---

## Proof gates

Three classes, and every new gate **extends the existing harnesses** rather than
adding a parallel one (`research/js-actors/test.bl`, `verify.mjs`,
`browser.html`; repo principle 2).

### G-unit — a BL acceptance check

A check in `test.bl` with an exact observable: a mailbox contents, an exit
reason string, a `:DOWN` payload, a restart count. The current suite has 457
checks, including lifecycle, names, table and supervisor subsets. Remaining
native behaviors in each doc still need their own checks.

### G-adversarial — the same check under hostile scheduling

The prototype already runs the suite at actor budgets 17, 41 and 200
(`verify.mjs`). Every lifecycle check must pass at the smallest budget, because a
link firing or a `:DOWN` landing is exactly the kind of event that can fall
between budget slices. A check that passes only at 200 proves nothing about the
ordering invariant it claims.

### G-diff — differential against native BEAM

Run the **same BL source** on BEAM and on the JS target and compare a structured
**trace**, not wall-clock time. The prototype has one precedent for this: five
selected exception results were evaluated independently on native BEAM and
"agreed with their JS assertions" (README §Verified results). The proposal is to
make that a harness:

```
{:event :spawn   :pid 1}
{:event :send    :from 1 :to 2 :msg …}
{:event :recv    :pid 2 :matched true}
{:event :monitor :by 1 :of 2 :ref r1}
{:event :exit    :pid 2 :reason :badarith}
{:event :down    :to 1 :ref r1 :pid 2 :reason :badarith}
```

The comparator checks the **partial order** (per-pair message order; every
`:DOWN` after its `:monitor`; exactly one `:DOWN` per monitor), never timestamps.
This is what makes "the race is not equivalent" (README: "Exact timeout/message
race equivalence is not established") an explicit, bounded gap instead of an
unstated one.

**A passed selected-rule differential proves only those rules.** Full-contract
✅ requires a much broader same-source trace corpus than this prototype has;
[FEATURES.md](FEATURES.md) labels the shipped slices as local subsets.

---

## What the substrate already proves (and the OTP layer may rely on)

From `runtime.bl` and the README's verified results:

- Selective receive: message-major, source clause order per message, skipped
  messages retained with their order (`rt-receive`, `rt-scan-from`).
- A deadline is computed once and never extended by a message flood
  (`rt-deadline-of`, `rt-deadline-passed?`).
- `after 0` scans the current snapshot and times out without parking.
- Registration, recheck and parking are one transaction (`rt-proc-wait!` +
  `host/park-release`); a `send` either sees `:waiting` (and requeues) or is
  found by the post-registration rescan.
- The scheduler wakes expired timers on every cycle, runnable peers or not
  (`rt-sched-loop`).
- Bounded turns and stack-safe loops (frame depth < 1024 across 50 000
  iterations).
- An uncaught actor error is recorded and fails the batch
  (`rt-run-pid` → `host/record-error`).

These are the atoms W1 composes. The prototype is a stronger foundation than the
list of absences makes it look: what is missing is *signalling and naming*, not
scheduling.

---

## What must not be claimed

- **Not OTP equivalence.** No doc here asserts that a program's failure
  behaviour survives the move to this target. It does not, until W1–W3 land and
  pass G-diff.
- **Not an implementation plan.** Each doc's §7 is a dependency sketch, not a
  schedule; §10 lists decisions left open on purpose.
- **Not a second runtime.** The target stays one runtime per bundle until W4
  (distribution) exists; cross-Worker transport, a transferable BL codec and
  closure serialization are all absent (README).
- **Not a replacement for the BEAM bundles.** `proc/*` runs on BEAM *today* and
  the JS target cannot load it. W2–W3 decide whether the bundles are ported,
  shared as a subset, or kept target-specific (`○`).

---

## Cross-cutting open decisions

| # | decision | who it blocks |
|---|---|---|
| O-1 | **Pid identity**: keep integer handles, or make pids refs with node identity from day one so distribution (W4) is not a breaking rename? | W1, W4 |
| O-2 | **Where do signals live**: VM-emulated in BL over the scheduler (recommended, see C1), or new `host/` primitives? | W1 |
| O-3 | **One `defserver` or none**: build a BL `defserver` loop for the JS target, or accept raw `receive` only? | W2b, W3 |
| O-4 | **Bundle portability**: port `proc/*`, share a subset, or keep two? | W2, W3 |
| O-5 | **Trace format ownership**: does the trace live in `runtime.bl` (always on, guarded) or only in test builds? | W0 |
| O-6 | **Verification side**: does `system/verify` stay BEAM-side and gate the emitted program (C5), or is a target-side checker built? | W3 |

---

## Repo pointers (start here)

```
research/js-actors/README.md          the prototype's own limits — authoritative for §3 of every doc
research/js-actors/runtime.bl         rt-spawn · rt-send · rt-receive · rt-run-pid · rt-sched-loop · critical sections
research/js-actors/host.mjs           runTurn · critical sections · park/park-release · PURE + RT_HOST export sets
research/js-actors/compiler.bl        the closed target ABI and its rejection tests
research/js-actors/verify.mjs         the Node-only external verifier (budgets, boundary checks)
research/supervision-contracts/       the four contracts applied to supervision; one diagnostic shape (C7)
docs/the-process-pattern-language.md  §3.1–3.6 failure patterns · §6 build-status ledger (the repo's own truth)
docs/the-maximalist-supervisor.md     the design intent for supervision/registry/bus on BEAM · §5 honesty ledger
docs/the-five-bundles.md              §0 verb tiers · §5 supervisor · §7 build plan and its stated unbuilt list
priv/std/proc/                        the BEAM bundles to reuse or diverge from
priv/std/vm/ports.bl                  the *other* "ports" — TCP claims on disk, not BEAM ports
```

Verified as a narrow browser-input demo in the worktree; not yet a port protocol:
`!tasks/features/FEAT-046-keep-bl-actors-alive-for-browser-host-ev.org` — the
host-event inbox, a transport substrate a future port layer should reuse. Do not build a second one.

Provenance: `!tasks/features/FEAT-045-prototype-bl-written-actor-runtime-and-a.org`
(the prototype) and the session that asked for this folder
(`2026-09-22T19-29-12-622Z_1589f3526b6fce30`). The durable FEAT list for the work
these docs describe is maintained by the main session, not here.
