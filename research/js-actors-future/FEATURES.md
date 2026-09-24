# BL→JS actors: feature ledger and dependency map

This is the human-facing index. Each linked `!tasks` item remains the durable
brief; [the executable README](../js-actors/README.md) names the current target
contract and its limits. The detailed research sheets in this folder retain
historical pre-implementation questions; this ledger is the current status.
**Local target behavior is not complete OTP/BEAM or full BL numeric parity.**

## Verified local target slices

| Item | Status and observed proof | Boundary |
|---|---|---|
| [FEAT-045 actor prototype](../../!tasks/features/FEAT-045-prototype-bl-written-actor-runtime-and-a.org) | Baseline committed: BL→ANF→BL-written JS emitter, BL actor scheduler/selective receive and suspended `try`; original 104 checks retained inside the current 457. | Not a production backend. |
| [FEAT-046 browser input](../../!tasks/features/FEAT-046-keep-bl-actors-alive-for-browser-host-ev.org) | BL sink/FIFO delivery and a persistent [browser actor](../js-actors/demo.html); timed and indefinite wait, manual reply and Stop verified. | Bounded string inbox, not ports or distribution. |
| [FEAT-047 conditional Number rule](../../!tasks/features/FEAT-047-prove-when-bl-arithmetic-may-use-javascr.org) | Opt-in `number_rule.bl` yes/no/unknown under **assumed** variable ranges; 34 tests / 94 assertions. | Its verdict is not consumed by the emitter and cannot authorize unchecked arithmetic from untrusted bounds. |
| [FEAT-048 logical BL frames](../../!tasks/features/FEAT-048-record-logical-beam-lisp-source-frames-a.org) | Positioned reader→ANF→resumable call metadata, bounded innermost-first frames and BL `file:line:col` output. `verify-trace.mjs`: 27 source checks, native-tail site, rethrow and finalizer replacement; [browser failure demo](../js-actors/trace-demo.html) visibly reports a BL source line. | Target-defined logical frames, with deliberate tail elision and explicit unknowns; **not** BEAM stacktrace parity. |
| [FEAT-049 lifecycle](../../!tasks/features/FEAT-049-design-portable-actor-identity-links-mon.org) | BL typed local pids/refs, atomic death cleanup, links, monitors, exit signals and trap_exit. `verify-lifecycle.mjs`: 17-step boundary invariants, 11 selected native BEAM signal reasons; [browser supervisor demo](../js-actors/super-demo.html) shows the child monitor `:down` once before its ledger update. | One runtime/Worker; no distributed identity or demonitor `:flush` guarantee. |
| [FEAT-050 names/server](../../!tasks/features/FEAT-050-design-portable-process-names-and-genser.org) | BL local name map, death retraction, ref-correlated call/cast/reply/timeout, and `proc/defserver` lowered from shared `proc.server/clause-plan`; `verify-names.mjs` compares 4 BEAM rules; the [browser supervisor demo](../js-actors/super-demo.html) routes a message through stable child name `:demo-worker` after restart and shows the BL reply. | Attribute-registry clause contributions, bus/tick and full GenServer semantics are still refused; a server dying during a call yields timeout, not `:noproc`. |
| [FEAT-051 supervision](../../!tasks/features/FEAT-051-design-bl-supervision-restart-and-intros.org) | Same public `proc.super/defsupervisor` uses shared `proc.super/supervisor-plan`; BL supervisor actor implements three strategies, three restart policies, bounded intensity/ledger, child names, shutdown (`:brutal_kill` included). `verify-supervision.mjs`: 79 checks, 10 selected OTP rules + rest-for-one trace. [Browser demo](../js-actors/super-demo.html) visibly crashed/restarted a child twice and served between restarts. | One-level declared server children; pools/dynamic children/nested trees and OTP reason shape absent. Supervised browser sinks are explicitly refused without an acknowledgement protocol. |
| [FEAT-052 owned table subset](../../!tasks/features/FEAT-052-design-portable-ets-ownership-and-table.org) | BL `:set` table identity, owner/heir transfer, three access modes, atomic update-counter and narrow select over opaque mutable host storage; `verify-tables.mjs` checks 121 table assertions, 25 BEAM rules; `verify-table-leaves.mjs` measures constant-size host operations against copy-on-write maps. | No full ETS type/match-spec/cursor set. Access modes are a **trusted BL protocol**, not a hostile-source sandbox: raw leaves and `host/state` remain callable from application BL. |

Source build: `BEAM_LISP_Z3=/usr/bin/z3 ./bin/bl run research/js-actors/compiler.bl`.
`node research/js-actors/verify.mjs` passes **457 BL checks** at default,
17-step and 41-step budgets. Browser-tool verification of `browser.html`
observed 457 checks and 711 Worker timer ticks; `super-demo.html` showed pid
incarnations 2→3→4, a live message between restarts and graceful Stop.
These are observed *subset* proofs, not a claim that every FEAT acceptance
question or every OTP behavior is settled.

## Numeric integration and exact fallback

1. **[FEAT-055 trusted Number gate](../../!tasks/features/FEAT-055-gate-anf-number-lowering-with-trusted-ra.org) — implemented narrow fast path; broader proof remains open.** Canonical ANF is built regardless of verdict. The emitter itself re-derives an exact safe-integer range from literal/let-bound literal binary arithmetic, checks all intermediate results and zero divisors, and emits raw `Number` only with a recorded witness (4 raw sites in the current bundle); other operations keep checked `H.arith`. Forged `:ann` facts and caller-declared ranges cannot grant a fast path. Trusted *variable* bounds from typed/system/codebase or checked boundary guards are **not implemented**; the FEAT-047 conditional rule is not wired into emission. Do not describe this as completed full FEAT-055.
2. **[FUP-124 exact numeric spike](../../!tasks/follow-ups/FUP-124-research-full-exact-numeric-semantics-fo.org) — research decision delivered; exact implementation remains FEAT-056.** [The reproducible 34-case BEAM/Node candidate](04-exact-numeric-spike.md) compares tagged BigInt integers and scaled decimals, documents the lossless typed codec, explains the necessary host BigInt primitive and records preliminary costs. The candidate codec has 7 exact roundtrips and rejects nonfinite values; the browser BigInt primitive was checked, while full BL division/rounding, generated-bundle cost, QuickJS and BL-written exact dispatch remain unverified.
3. **[FEAT-056 exact tagged numeric runtime](../../!tasks/features/FEAT-056-implement-exact-tagged-numeric-runtime-f.org) — unimplemented.** One BL dispatch over tagged BigInt/decimal/float values, a typed codec and full differential corpus must precede any numeric parity claim; the spike is not that implementation.

## Remaining boundary work

- [FEAT-053 ports and Web capabilities](../../!tasks/features/FEAT-053-design-bl-actor-ports-and-browser-i-o-ca.org): owner/close/cancel/backpressure/authentication contracts for external sources beyond the narrow string inbox. `vm/ports.bl` is not BEAM `open_port`.
- [FEAT-054 cross-Worker distribution](../../!tasks/features/FEAT-054-design-cross-worker-actor-identity-and-d.org): node/incarnation identity, typed codec, remote monitors, node-down/reconnect/security. A `postMessage` bridge alone is not distribution.

## Architectural cutover and dependencies

```text
canonical BL ANF ──> literal-evidence Number gate (broader FEAT-055 open)
                └──> exact numeric implementation FEAT-056 (FUP-124 research)
source spans ──> FEAT-048 logical frames
FEAT-049 atomic lifecycle ──> FEAT-050 names/server ──> FEAT-051 supervision
                         └──> FEAT-052 table ownership
                         └──> FEAT-053 ports; local protocols ──> FEAT-054 distribution
```

`proc` is the **one public process-pattern door**: shared pure declaration
plans in `priv/std/proc/{server,super}.bl` lower to native BEAM or target BL
actor code. Generic death, send, monitor, names, and mailbox selection live
*below* `proc`, in `research/js-actors/runtime.bl`. `proc.table` remains the
native heir/lifetime reference; the JS table subset is BL policy over opaque
host storage, not a copied implementation of BEAM ETS. The JS host never owns
scheduler, mailbox, link, registry, restart or table-owner policy.
