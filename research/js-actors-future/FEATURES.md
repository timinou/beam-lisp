# BL→JS actors: feature ledger and dependency map

This is the human-facing index. Each linked `!tasks` item is the **durable, executable brief**: motivation, source seams, observable acceptance, caveats and dependencies. The documents beside this file are detailed research for later architecture passes, not proof that OTP is implemented.

## Delivered in this worktree

| Item | Status | What can be observed now |
|---|---|---|
| [FEAT-045: actor prototype](../../!tasks/features/FEAT-045-prototype-bl-written-actor-runtime-and-a.org) | DONE, committed | Existing BL compiler→ANF→BL-written JS emitter, BL-written actor runtime/selective receive, 104 regression checks including suspended try/finally; Node and browser Worker. Numeric semantics and OTP remain subset-only. |
| [FEAT-046: persistent browser input](../../!tasks/features/FEAT-046-keep-bl-actors-alive-for-browser-host-ev.org) | DONE, verified in worktree | `research/js-actors/demo.bl` remains alive across real browser UI events. Open [`demo.html`](../js-actors/demo.html), watch three staged BL replies, type another message, and press Stop. Node tests cover startup queue, timer wake, indefinite wait, FIFO bound and invalid payload. No general port or cross-Worker actor semantics. |
| [FEAT-047: safe Number research rule](../../!tasks/features/FEAT-047-prove-when-bl-arithmetic-may-use-javascr.org) | DONE, opt-in proof | BL `number_rule.bl` uses typed literal tags, system SMT/model/decide, Veritas and codebase provenance to return yes/no/unknown under **assumed** integer input ranges. Focused tests: 29 tests / 80 assertions. N-ary reductions and branch-losing model extraction fail closed instead of producing false :yes. It is **not** wired into the JS emitter and does not prove the ranges supplied by a caller. |

## Numeric correctness

1. **[FEAT-055: proof-gated compiler cutover](../../!tasks/features/FEAT-055-gate-anf-number-lowering-with-trusted-ra.org) — proposed.** A research certificate is not enough to emit unchecked JS arithmetic: its variable-range assumptions must originate from trusted source/type evidence or runtime guards. Preserve integer/float/decimal category through ANF, attach proof witnesses to operations, and lower to raw `Number` only when every obligation is discharged. Unknown retains checked arithmetic; no silently rounded values. Tests must target malicious/unknown range declarations, joins, loops, foreign messages, overflow and BEAM differential results. **Depends on FEAT-047.**
2. **[FUP-124: exact numeric tower spike](../../!tasks/follow-ups/FUP-124-research-full-exact-numeric-semantics-fo.org) — research follow-up.** Determine the full BL-JS implementation for arbitrary integers, exact scaled decimals, floats, equality/hashing and printing. Compare tagged BigInt/Decimal representations, test scale-sensitive `1.50M` vs `1.5M`, mixed arithmetic, division errors and browser/QuickJS constraints using a lossless typed codec. Measure bundle/runtime cost and draft the implementation feature from evidence. **May run beside FEAT-055; its result defines the exact fallback.**

## Debuggability

3. **[FEAT-048: logical BL source frames](../../!tasks/features/FEAT-048-record-logical-beam-lisp-source-frames-a.org) — proposed.** The exception transport currently has a raw-trace-shaped tuple with no frames. Preserve real BL source/module/function/call-site metadata in resumable frames, including after park, dynamic call and finalizer rethrow. Specify tail-call representation, trace limits and missing-location markers; show a BL source location for a deliberate browser failure. Do not present JS `Error.stack` as a BEAM stacktrace. **Depends on existing try/suspension backend, not on OTP.**

## OTP-inspired actor behavior: design and implementation waves

Read [the roadmap](README.md) first. It separates current BL substrate, BEAM contracts and repo-side `proc/*` behavior. Every item below needs a **deeper architecture decision before implementation**, then BL state-machine tests and selected BEAM differential traces. They are not umbrella promises of full OTP compatibility.

4. **[FEAT-049: identity, links, monitors, exits](../../!tasks/features/FEAT-049-design-portable-actor-identity-links-mon.org) — critical path.** Decide typed pid/ref identity and one atomic process-death transaction: link notifications, monitor `DOWN`, trap_exit, exit reasons, cancellation of waits and message ordering. Test races and exactly-once delivery at adversarial scheduler budgets. Today a crash just records a batch error. [Lifecycle detail](01-process-lifecycle.md).
5. **[FEAT-050: names and GenServer protocol](../../!tasks/features/FEAT-050-design-portable-process-names-and-genser.org) — after lifecycle for names.** Design register/whereis with automatic death cleanup; separately, design ref-correlated call/cast/reply/timeout over the existing mailbox rather than add a second server API. A late reply must not accidentally answer a later call. Reuse `priv/std/proc/reg.bl` and `server.bl` where possible. [Protocol detail](02-registry-and-supervision.md).
6. **[FEAT-051: supervision](../../!tasks/features/FEAT-051-design-bl-supervision-restart-and-intros.org) — after lifecycle and server/name contracts.** Define child specs, restart policies/strategies, intensity/escalation, orderly shutdown and observable restart ledger. A browser demo should intentionally crash a BL child and display the BL supervisor's decisions. Distinguish repo-side unimplemented ledger promises from JS target gaps. [Supervision detail](02-registry-and-supervision.md).
7. **[FEAT-052: ETS boundary](../../!tasks/features/FEAT-052-design-portable-ets-ownership-and-table.org) — after owner-death semantics.** Decide table ownership/heirs, access, atomic update/lookup/select and representation before exposing ETS operations. The prototype's immutable BL map copies a JS `Map` per update: it is not an O(1) ETS table. Test owner death and measured scaling. [ETS detail](03-boundaries-ets-ports-distribution.md).
8. **[FEAT-053: ports and Web capabilities](../../!tasks/features/FEAT-053-design-bl-actor-ports-and-browser-i-o-ca.org) — reuse FEAT-046 transport; after owner-death semantics.** Extend the narrow string inbox into typed external sources (fetch/WebSocket/DOM), with per-source identity, owner, close/cancel, error envelopes, authorization and bounded backpressure. Do not conflate BEAM `open_port` with this repo's `vm/ports.bl` TCP-claim registry. Browser request/cancel/error behavior must be visible and BL-owned. [Boundary detail](03-boundaries-ets-ports-distribution.md).
9. **[FEAT-054: cross-Worker distribution](../../!tasks/features/FEAT-054-design-cross-worker-actor-identity-and-d.org) — after local lifecycle and protocol decisions.** Decide node/incarnation identity, remote pid/ref/monitor, codec/closure policy, node-down, reconnect, security and backpressure. Two Workers must exchange typed BL values with stale-node rejection, while loss and delivery guarantees are stated honestly. `postMessage` alone is not distribution. [Distribution detail](03-boundaries-ets-ports-distribution.md).

## Wave order and proof boundary

```text
Now: FEAT-045/046/047 ✓
Parallel next: FEAT-048 logical frames · FEAT-055 trusted Number cutover · FUP-124 exact numeric spike
Actor critical path: FEAT-049 lifecycle → FEAT-050 names/protocol → FEAT-051 supervision
Boundary branches after FEAT-049: FEAT-052 ETS · FEAT-053 ports
After local actor contracts: FEAT-054 distribution
```

**Do not infer full compatibility from this list.** A research document is not an implementation; an implementation without adverse-budget tests and a visible user proof is not complete. Each org item names its own observable gate.
