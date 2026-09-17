# PLAN-121 — after-state measurements

Measured 2026-09-17 on the pure-beam-lisp VM manager (priv/std/vm/*), via
`bl run` against a live manager. These are the AFTER numbers only (per the ask
— no before/after comparison). Reproduce with the program in this dir's
`measure.bl` (mirror of the run).

## G1 CONCURRENCY — no serial worker

| metric | value | meaning |
|---|---|---|
| slow command in VM-A | 319 ms | a deliberately 300ms command |
| fast command in VM-B (started +10ms) | 40 ms | finished while A still running |
| 200 concurrent commands across 10 VMs | 32 ms total, 200/200 completed | the BEAM scheduled them; no FIFO |

B (40ms) finishing while A (319ms) is mid-flight is the proof: there is no
single serial worker. Under the old Executor, B would have queued behind A and
reported ~319ms+.

## G2 ENV-SCOPED HALT

| metric | value |
|---|---|
| members halted in VM-A by its own `(vm/halt 0)` | 3 |
| VM-A owned set after | 0 |
| VM-B owned set before / after A's halt | 2 / 2 (unchanged) |
| node alive | true |

A command ending its own VM tore down exactly VM-A's 3 members and left VM-B's
2 untouched. The node survived. (A capped VM additionally cannot even COMPILE
`System/halt` — see the guarantees suite; that is what makes the node
un-killable by project code.)

## G3 NO LEAK ON CRASH

| metric | value |
|---|---|
| owned set after 1000 spawn+kill cycles (100×10) | 0 |
| BEAM process count delta across the 1000 cycles | 0 |

Every killed member self-retracted via the monitor; the process table returned
to its starting size. No orphan rows, no orphan processes.

## G5 PROCESS-LOCAL ENV — the keystone the FIFO masked

| metric | value |
|---|---|
| 50 concurrent commands each binding a DIFFERENT env, each reading its own | 50/50 correct |

Two concurrent commands with different env no longer race: the env view is a
process-dictionary overlay, per-process by construction. The daemon never
mutates the node-global OS env table.

## Formal + behavioural net

- `bl test test/bl/vm/` → env (6) + guarantees (23) + invariants (14) = 43 assertions, all green.
- Z3 PROVES: owned-set capacity invariant (0 ≤ n ≤ cap, exact, all traces) and the
  halt-empties-set coupling (□(live ∨ n=0)); REFUTES the leaky variants, naming the
  offending transition.
- Property: id-of injective on distinct roots (no worktree collision).

## Honest scope

These measure the SUBSTRATE (priv/std/vm/*) directly, driven by `bl run`. What
is NOT yet wired at this measurement: the Elixir transport seam
(server.ex:332) still calls the old Executor; repointing it at the manager,
booting the manager from Server.init, and deleting the serial worker are the
remaining cutover stages (S-RUNNER…S-DELETE in PLAN-121). The guarantees above
are proven of the manager as invoked in-process; wiring makes them the daemon's
observable behaviour.
