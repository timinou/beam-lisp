# 01 — Process lifecycle: identity, exit reasons, links, monitors, `trap_exit`

> **Current status: a local target subset is implemented.**
> `research/js-actors/runtime.bl::rt-terminate!` now owns atomic typed-pid/ref
> death, links/monitors, trap_exit and local signals. `verify-lifecycle.mjs`
> tests adverse budgets, boundary invariants and 11 selected BEAM exit rules.
> The "prototype today" and missing-feature inventories below are historical
> pre-implementation research; use [FEATURES.md](FEATURES.md) and the
> [actor README](../js-actors/README.md) for current limits. No full OTP parity.

This was the critical-path workstream: names, supervision and local table
ownership now build on that BL death transition. Ports and distribution still
need their own contracts and tests.

---

## 1. Scope

**In:** process identity; spawn variants; per-process flags (at least
`trap_exit`); exit reasons; the normal/abnormal distinction; `link`/`unlink`;
`monitor`/`demonitor`; exit signals; `exit/2`; death as an observable value;
signal ordering; liveness observation (`alive?`, `process_info`).

**Out:** naming/registration and `whereis` (`02`); restart policy (`02`); how a
table survives death (`03`); cross-node monitors (`03`); debugger/introspection
tooling beyond what a supervisor needs (`02`).

---

## 2. BEAM/OTP contract

The semantics the target must reproduce. These are stated as the BEAM defines
them; they are the source of truth for §4.

### 2.1 Identity and spawn

- A process is created by `spawn`/`spawn_link`/`spawn_monitor`/`spawn_opt`. The
  creator receives a pid immediately; the child runs concurrently.
- `spawn_monitor` is **atomic**: there is no window in which the child can die
  without the monitor having been established. (A non-atomic emulation loses the
  DOWN for a child that dies immediately — the classic bug.)
- `spawn_link` is `spawn` + `link` **atomically** with the same property.

### 2.2 Exit reasons

- A process terminates with a **reason**: `:normal`, `:shutdown`, `:killed`, an
  error class atom (`:badarith`, …), `{:shutdown, Term}`, or any term.
- The *reason* is the only thing other processes learn about the death. There is
  no stacktrace in the reason (that travels over the error-logger channel).
- `exit(Pid, :kill)` is **untrappable**: the target dies with reason `:killed`
  regardless of `trap_exit`.
- `exit(Pid, Reason)` sends an exit signal: a non-trapping target dies with
  `Reason`; a trapping target receives `{:EXIT, Pid, Reason}`. For
  `Reason = :normal` a non-trapping target is **not** affected.
- Termination is asynchronous: `exit(Pid, Reason)` returns before the target is
  actually dead, and `is_process_alive/1` can still answer `true` briefly.

### 2.3 The normal/abnormal rule (the one everyone gets wrong)

- A link propagates a death only when the reason is **not** `:normal`.
- With `trap_exit = true`, `{:EXIT, Pid, Reason}` is delivered for *every* reason
  including `:normal`.
- OTP's supervisor restart decisions additionally treat `:shutdown` and
  `{:shutdown, _}` as "not a failure". That set is OTP policy, not VM policy —
  it belongs in `02`, but the reasons it inspects come from here.

### 2.4 Links

- `link(Pid)` is **bidirectional** and idempotent; `unlink(Pid)` removes it.
- On death with reason `R`: every linked process with `trap_exit = false` and
  `R ≠ :normal` exits with the same `R`; every linked process with
  `trap_exit = true` receives `{:EXIT, Pid, R}`.
- A link to a dead pid delivers the exit signal immediately (and, on BEAM, the
  linking process is itself killed by `:noproc` unless trapping).
- `:killed` propagates: the peers of a killed process see `:killed`.

### 2.5 Monitors

- `monitor(process, Pid)` returns a **reference**. On death (any reason) the
  monitoring process receives `{:DOWN, Ref, :process, Pid, Reason}`
  **exactly once**.
- Monitoring an already-dead pid delivers the DOWN immediately — this race is
  part of the contract, not an edge case.
- `demonitor(Ref)` cancels. `demonitor(Ref, [:flush])` **also removes an already
  delivered DOWN from the mailbox** — the reason `fence.bl` calls
  `demonitor ref (list :flush)` on every exit path.
- Monitors are **per-observer**: two processes monitoring the same pid get
  independent refs and independent DOWNs. Monitors add no edge to the monitored
  process's graph.
- When a monitored process becomes unreachable (node down), the DOWN reason is
  `:noconnection` (`03`).

### 2.6 `trap_exit` and the signal/message ordering guarantee

- `process_flag(:trap_exit, true)` converts incoming exit signals into ordinary
  mailbox messages. It is a **flag**, not a per-message transform.
- **Signals between a pair of processes are ordered, and are ordered with
  respect to messages from the same sender.** If A sends B `:m` then dies, B
  sees `:m` before the `{:EXIT, …}`/`{:DOWN, …}`; if A dies then... (it cannot
  send). This is the invariant C2.
- A generic `gen_server` — and therefore a BL `defserver`, which is a real
  `gen_server` (`lib/beam_lisp/server.ex:115-120`, `compiler.bl:2941`) — traps
  exits in its init loop, so `{:EXIT, Pid, Reason}` arrives at `handle_info`.

---

## 3. Prototype today (measured)

Read from `research/js-actors/runtime.bl`, `host.mjs`, and the README's verified
results.

| capability | status | evidence |
|---|---|---|
| spawn with integer pid from `:next-pid` | ✅ | `rt-empty-state`, `rt-spawn` |
| `rt-self` | ✅ | `rt-self` → `host/self` |
| send to a mailbox; wake a parked receiver | ✅ | `rt-send`, `rt-requeue!` |
| send to a **dead/gone** pid | ✅ (silent drop + log) | `rt-send`: writes `"send: no such process N"`, returns nil |
| process death on uncaught error | ◐ | `rt-run-pid` `:error` branch: log, `host/record-error`, drop proc |
| process death on normal return | ◐ | `rt-run-pid` `:done` branch: **silently** drops the proc |
| exit **reason** retained after death | ✗ | the reason exists only as the error message string for `:error`; nothing reads it |
| links | ✗ | no `link` in `runtime.bl` or `host.mjs` |
| monitors / `:DOWN` | ✗ | no `monitor`, `demonitor`, `ref`, or `:DOWN` anywhere in `runtime.bl` |
| `trap_exit` | ✗ | no process flags at all |
| `exit/2` (kill another process) | ✗ | `:erlang/exit` raises locally only; README: "does not propagate links or monitor messages" |
| liveness observation | ✗ | no `alive?` / `process_info`; `rt-proc-of` is internal |
| refs | ✗ | `rt-hash-key`, `host/eq` exist; no `make_ref`-equivalent |
| a blocked process is distinguishable from a deadlock | ✗ | `rt-sched-loop` still reports an error without a registered input sink. FEAT-046 now treats an indefinitely waiting **registered browser sink** as valid and wakes it on a host event. This narrow exception is not a general signal/monitor liveness contract; `03` §3.3 documents the implemented boundary |

**The precise gap.** The prototype can already detect death (two branches in
`rt-run-pid`), and it already has the atomic primitive death needs (critical
sections around read-modify-write of the runtime state). What it has no notion
of is:

1. a reason attached to the death, and
2. anyone who should be told.

That is the entire workstream.

---

## 4. Missing invariants

Each is a testable statement; §9 turns each into a gate.

- **I1.1 — Reason before removal.** When a process dies, its exit reason is
  recorded in the runtime state *before* the process is removed from `:procs`,
  so any observer woken in the same transaction can read it.
- **I1.2 — Link propagation.** Every linked peer with `trap_exit = false` exits
  with the same reason when the reason is not `:normal`, in the same scheduling
  transaction (C1). `:normal` kills no non-trapping peer.
- **I1.3 — Link observation.** Every linked peer with `trap_exit = true`
  receives exactly one `[:EXIT pid reason]` for every reason including `:normal`,
  and does not die.
- **I1.4 — Monitor delivery.** Every monitoring process receives exactly one
  `[:DOWN ref :process pid reason]`.
- **I1.5 — Monitor of the dead.** A monitor established after the target has
  died still delivers a DOWN (this is the race `spawn_monitor` exists to remove).
- **I1.6 — `demonitor` with flush.** `demonitor(ref, [:flush])` removes an
  already-queued DOWN, and is a no-op (never an error) otherwise.
- **I1.7 — `:kill` is untrappable** and yields reason `:killed`, regardless of
  the target's `trap_exit`.
- **I1.8 — Signal/message ordering (C2).** Between a pair, signals and messages
  are FIFO in one order.
- **I1.9 — Death is atomic (C1).** No `send` can observe a process that is
  removed from `:procs` but whose signals are not yet delivered; no killed
  process can run another turn.
- **I1.10 — Observation.** A `:DOWN`/`:EXIT` is the *only* way to learn about a
  death besides an explicit query; a query (`alive?`) answered against the
  runtime state is consistent with it.

---

## 5. Repo BL side (what exists, and where it is incomplete)

### To reuse as vocabulary (C3)

| thing | where | note |
|---|---|---|
| `[:DOWN ref :process pid reason]` | `proc/server.bl`, `proc/reg.bl`, `proc/bus.bl`, `proc/fence.bl` | the repo's established DOWN shape — the JS target should emit exactly this |
| one merged `[:DOWN …]` handler | `proc/server.bl::down-clause` | two `:DOWN` clauses in a `defserver` cannot coexist (first match wins); the expander threads them |
| `demonitor ref (list :flush)` on every path | `proc/fence.bl::fence-fn`, `proc/bus.bl`, `proc/reg.bl` | the leak the repo already fixed by hand |
| `spawn-monitor` → `[pid ref]` | `priv/boot/core.bl::spawn-monitor` | note: BL's version also **conveys the caller's env**, which the JS runtime has no concept of |
| `exit/2` for killing | `proc/fence.bl` (`erlang/exit pid :kill`) | `:kill` semantics are the contract |

### Repo gaps (⚙) that W1 shares with the BEAM side

- **No declarative `trap_exit` clause.** `docs/the-process-pattern-language.md`
  §3.2 lists `defserver (trap-exit true)` as ○; today a `defserver` traps only
  because it *is* a `gen_server`, and `Process/flag :trap_exit true` is used
  directly where needed (`priv/std/bl/cli.bl:961`).
- **Unsettled `:EXIT` message shape.** BEAM's is a 3-tuple
  `{:EXIT, Pid, Reason}`; the repo's DOWN is a 4-element vector. Which shape the
  BL ecosystem standardises on is ○ (see §10) and must be decided before the
  target implements it, or two dialects ship.
- **No generic `link` verb in the tier-1 prelude list.** `docs/the-five-bundles.md`
  §0 names `monitor link kill` as tier 1; `link`/`unlink` as *verbs* are not
  demonstrated in `priv/std`.
- **The static guarantee is specified but not shipped.** "Every `monitor` call
  site is dominated by a `:DOWN` handler" (§3.1) is exactly the kind of check
  `system/verify` could run; it is unbuilt.

---

## 6. Design constraints derived from the prototype

These are not preferences; they follow from how `runtime.bl` is already built.

- **Death is detected in `rt-run-pid`.** Any induced death (`exit/2`) must route
  through the same terminal handling, or a killed process could still be
  requeued. The `:runnable` queue is a vector and `rt-run-head-pid` already skips
  a pid whose process is gone ("a stale runnable entry: skip to the next") — that
  path is the safety net, not the plan.
- **Signals must be enqueued inside a critical section.** The mailbox append in
  `rt-send` happens under `host/critical-enter`; the wake uses `rt-requeue!`,
  itself a critical section. Emulated signals must use the same discipline or C2
  is lost.
- **Relations live in the one mutable root.** `rt-empty-state` is
  `{:next-pid :procs :runnable}`. Links, monitors, refs and per-process flags
  belong there too (e.g. `:links`, `:monitors`, `:next-ref`) — the host keeps
  exactly one retained mutable root (`host/state`), and adding a second is a
  design change, not an implementation detail.
- **Refs need a source of uniqueness.** `:next-pid` is the only counter today;
  a `:next-ref` alongside it is the minimal addition. `host/eq` must compare it.
- **Distinguish "blocked forever" from "waiting for a signal."** `rt-sched-loop`
  currently treats a fully-blocked system as an error. A process waiting on a
  link/monitor is legitimately blocked; the scheduler's terminal condition needs
  a third category (see ○).

---

## 7. Dependencies / wave order

- **Depends on:** W0 (vocabulary + trace harness, so the same program can be
  compared on both targets).
- **Blocks:** W2a (registry retraction is a monitor), W3 (supervisors watch
  children with monitors/links), W4-ETS (ownership transfer triggers on owner
  death), W4-distribution (remote monitors are local monitors + a node).
- **Independent of:** W2b (gen_server conventions) — `call`/`cast` need
  correlation and timeout edges, not links.

---

## 8. Risk

| risk | consequence |
|---|---|
| The normal/abnormal rule implemented as "always propagate" | every `:normal` child exit kills its siblings; supervisors restart forever |
| Implemented as "never propagate `:normal`, and forget `trap_exit`" | a trapping process never sees the EXIT it asked to trap; `gen_server` terminate paths break |
| Signals delivered outside the scheduling transaction | a `send` interleaves between death and DOWN; C2 fails under the 17-step budget only (the prototype's adversary) |
| Monitors emulated by polling the `:procs` map | the "monitor a pid that died last turn" race is lost (I1.5); it will pass at budget 200 and fail at 17 |
| `:kill` implemented via the ordinary reason path | a trapping process survives `:kill`; the supervisor's last-resort kill is useless |
| Reason carried only as an error string | `02`'s restart decisions cannot distinguish `:normal`/`:shutdown`/`:badarith`; string matching becomes the API |
| `link`/`monitor` resolved by name at *death* time | a process renamed/restarted between link and death breaks the link; C4 says resolve at call time |

---

## 9. Test / differential proof gates

Every check extends the existing harnesses (`test.bl`, `verify.mjs`), never a
parallel one (C6). G-unit statements below are the *proposed* check names.

### G-unit (+ G-adversarial at budgets 17/41/200)

| # | check | invariant |
|---|---|---|
| 1 | a process raising an error records reason `:badarith` before removal | I1.1 |
| 2 | two linked processes; one crashes → peer's reason equals the crash reason | I1.2 |
| 3 | a linked peer exiting `:normal` does **not** kill its non-trapping link | I1.2 |
| 4 | a trapping linked peer receives `[:EXIT pid :normal]` and survives | I1.3 |
| 5 | `spawn_monitor` then immediate crash → exactly one DOWN, never zero | I1.5, I1.4 |
| 6 | `monitor` of an already-dead pid → immediate DOWN | I1.5 |
| 7 | `demonitor(ref, [:flush])` after the target died removes the queued DOWN | I1.6 |
| 8 | `exit(pid, :kill)` on a trapping process → it dies with `:killed` | I1.7 |
| 9 | A sends `:m` to B then A crashes; B's mailbox order is `:m` then DOWN | I1.8 |
| 10 | kill a pid that is sitting in the runnable queue → it never runs again | I1.9 |
| 11 | killing a process inside a critical section does not split the transaction | I1.9 |

### G-diff (trace comparison against native BEAM)

Run on both targets and compare the partial order of:

```
{:event :spawn   :pid P}
{:event :link    :a P1 :b P2}
{:event :monitor :by P1 :of P2 :ref R}
{:event :send    :from P1 :to P2 :msg M}
{:event :exit    :pid P2 :reason :badarith}
{:event :exit    :pid P1 :reason :badarith}      ; propagated link
{:event :down    :to P1 :ref R :pid P2 :reason :badarith}
{:event :exrecv  :pid P3 :pid2 P2 :reason :normal} ; trapped EXIT
```

Comparator rules: per-pair FIFO of `:send`/`:exit`/`:down`; `:down` after its
`:monitor`; exactly one `:down` per `:monitor`; `:exit` ordering relative to
`:send` from the same pid. No timestamps. **A correct-at-200-only run does not
count as a pass.**

---

## 10. Unresolved design options (○)

1. **Pid identity (O-1).** Integer handles as today, or `{node, serial, creation}`
   from day one? Distribution (`03`) makes the second cheaper *later* but heavier
   now. A creation/serial pair also answers "is this the same incarnation?" which
   monitors need.
2. **Where signals live (O-2).** BL-emulated over the scheduler (recommended by
   C1 — the runtime is cooperative and single-threaded, so an emulated signal can
   be exactly as atomic as a VM signal) **or** new `host/` primitives. The
   recommendation is not free: it requires death to be a single critical section.
3. **`:EXIT` message shape.** `[:EXIT pid reason]` (repo vector style, matches
   `[:DOWN ref :process pid reason]`) versus BEAM's `{:EXIT, Pid, Reason}` tuple.
   Whichever is chosen must be chosen **in BL**, shared, and written into the
   trace format.
4. **Reason vocabulary.** Do we model the supervisor's "not a failure" set
   (`:normal`, `:shutdown`, `{:shutdown, t}`) in the VM layer or in `02`? Model
   the reasons here; model the set there.
5. **Per-process flags surface.** A `defserver`-style clause, a `spawn_opt`-style
   arity, or a `rt-set-flag!` verb? `trap_exit` is the only one W1 needs; leave
   room for `priority` without building it.
6. **`link`/`monitor` surface.** Tier-1 prelude verbs (`docs/the-five-bundles.md`
   §0 already lists them) — so `monitor` returns a ref and `link` returns what?
   BEAM returns `true`; the repo has no precedent.
7. **Blocked-forever vs waiting-for-signal.** Does `rt-sched-loop` gain a third
   terminal category, and does "all processes blocked on links" error like the
   current no-deadline case? A browser service (`03`) wants *not* to error.
8. **Host-originated death.** A Worker torn down, a tab closed, a `postMessage`
   channel closed — should the host be able to kill a process (making it an
   ordinary exit signal), or is that out of scope until `03`?
9. **Trace instrumentation cost (O-5).** Always-on guarded trace, or
   test-build-only? Every gate in §9 needs it; production does not.
