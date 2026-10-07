# Main → structural preparation: readiness and remaining test debt

## Authorization and snapshots

The user requested: explain all readiness improvements, commit the previously uncommitted main work, merge main onto `perf/structural-merge-ready`, and explain remaining full-suite reds and their repair plan. This is not authorization to merge preparation back into main or deploy it.

Main snapshot **`0f518fdfe808012dc5f2103a347a0990e97be857`** commits the pending document worker changes, durable task records and new regression assertions. Main was clean after this commit. Preparation starts from `d2c22705`; its forward merge preserves all twelve intervening upstream commits plus this snapshot. Source merges cleanly, including corpus validity and durable fixtures; generated bootstrap artifacts conflict and require regeneration from the combined source. A source review found no high-confidence new corpus authority blocker (`agent://35-ReviewMergedCorpus`); runtime/backend interleavings require tests, not this review alone.

## What the readiness work changes

### Existing syntax and authoritative fallbacks

Applications retain ordinary `first/filter`, `datom/q/from/pull-many/watch`, `auth/guard/scope/scope-all`, `defrelation`, and `realm/open/close/require/env.bl` syntax. There is no projection/query DSL, author-supplied purity/completeness certificate, parallel optimizer/loader/cache registry or application-managed invalidation protocol. Unknown executable semantics, provider identity, capabilities or dependency authority retain the reference path.

### Env memo invalidation

Bulk deletion publishes the lookup epoch after successful deletion; otherwise a live memo can keep a removed binding. Cold epoch-ref creation is serialized with a double-check. Per-env materialization publishes in the requested env, even if its initializer temporarily attaches another env. Present/missing bindings, parent/child scope and initializer attachment tests cover these boundaries. This repairs authority; it does not claim a new wrapper is profitable. The research lookup wrapper was slower and was rejected.

### Conservative first/filter consumption

The existing optimizer admits only a bounded, materialized scalar source and a closed, total one-argument predicate, with proof fuel and emission budget. It captures the original callee and preserves argument evaluation order, evaluates each argument once, guards the actual runtime callable identity, and falls back through that captured callable without re-reading/replaying it. Existing reduce/reduced machinery handles early termination and false/nil matches. Unknown effects, lazy/resource/cycle cases and live rebinding are not guessed safe.

BUG-116 hardening makes arithmetic admission inspect the executable BIF **and** its canonical numeric-tower pair, not a friendly comparison label. A descriptor labelled `:gt` but executing division can raise later in the reference filter's forced chunk; early fusion must not hide that error. Permanent distinct-image regressions exercise direct and captured calls, partial/unknown operators, noncanonical pairs and metadata that cannot grant authority. The old image fails sixteen assertions; the repaired file passes174.

The last previously recorded fixture reduced runtime work from1,105,369 to90,721 reductions over200 calls (~12.18×), while BEAM bytes grew976→1,208 and caller compilation work47,225→72,885 reductions. These are narrow fixture costs, not app/browser/JavaScript speed claims. Compiler-worker/native compilation is excluded from the caller cost. Refresh measurements must remain tied to their own receipt.

### Corpus snapshot/view authority

Corpus discriminators include restricted filter and temporal modes. Complete-column artifacts carry their view; a durable pointer must be complete, match the persisted view, and not come from a future basis. Legacy/missing evidence rebuilds. Restricted reads do not reuse or publish into complete-column slots/artifacts and cannot pollute complete-view attr-basis publication. Packed and resident paths have historical/future, restricted-slot, valid-time and legacy negatives. Zero-row reuse after an unrelated write already existed; this work hardens validity, not generalized query optimization.

### Realm lifetime and retirement

Soft retirement retains busy old-only body identities that `code/all_loaded` cannot enumerate. Allocation numbering resets only when known retained bodies are actually purged. BUG-117 wraps inventory read/scan/retirement/publication/erase/reset in one same-key transaction using the existing retirement resource and the caller PID. A deterministic held-lock test observes both actual lock entries through an isolated OTP trace session, then proves survival, retention, non-reuse while busy, and safe later reuse after release. The old unlocked image fails this control; repaired lifetime tests pass32. No hard purge, background collector, public test hook or promise of post-close fun validity is added. Speculative companion prefixes were removed; actual emitted module names are tested.

### Fixture, bootstrap and native provenance

A valid binary keyword callback was incorrectly folded over an infinite producer as an invalid-callable error probe. The fixture now separates finite keyword parity from invalid callbacks; runtime semantics remain unchanged,451 assertions pass. Default JS deadlines were distinguished from correctness failures: unchanged main reproduced the default timeout; supported longer deadlines subsequently passed differential, cold CLI, compiled core and macro gates.

Every combined floor is produced through the existing authoritative seed builder, rather than selecting one branch's generated bytes as a final resolution. Fresh native JSON is built from the matching Rust source, preserving arbitrary-precision number support. Seed freshness checks and executable docs are explicit gates. Previous delivery accumulated32 selected files/3,805 passing assertions across split receipts; this is not a green whole-suite run or certification of this newly merged snapshot until refreshed.

### Pending main work now committed

The parent worker request forwards canonical explicit budget caps. The child preserves them, derives config/environment limits for older parents, and applies them at the same extraction boundary. Native maps/structs cross the JSON wire recursively with offsets intact and `__struct__` removed, instead of becoming inspected strings; atoms become names, and nil/bool/scalar/sequence behavior is retained. Added38 permanent assertions cover these changes without requiring the native document carrier. The capped main run has149 passing assertions; only the old duplicate-input fixture produces1failure+1error (artifact603). This is a failed file, not a waived green gate. The native extraction engine is absent and its capability probe is explicitly skipped.

### New upstream work retained, not attributed to this structural implementation

The forward merge also preserves upstream logical-vector traversal and its coherent floor; bounded read/query/style cache policy and admission; durable future-basis rejection, first-cold-read mark hydration and concurrent attr invalidations; request-local CSS collection without eager unrequested screen rendering; copied-checkout image-link repair; and source-keyed consumer/platform native refresh. These are other upstream commits. Their tests are included in the compatibility gate. Corpus still has a soft keep-key budget, not a newly claimed universal hard memory bound.

## Deferred mechanisms

Actual per-segment target-env AOT-loader promotion, automatic query/policy/live certificates, maintained authorized ranking with total provider/native work, existing Env/kernel profitability improvements, and conditional cross-realm sharing remain FUP-155/158/159/160/161. Research adapters are not installed as production APIs. Authority, expiry/revocation, shadows/macros/providers, initialization recovery and module/atom retention must be proved before promotion.

## Known suite reds and solution plan

Old broad receipts570/576 were failed and capped; selected baseline574 reproduced seven file families, with JSON/catch-kind passing alone but failing in the ordered prefix. They do not establish an exhaustive current-suite inventory. Source locations in a stack trace can be baked-in debug annotations: a sibling-checkout filename alone does **not** prove a stale loaded image. Use actual `code/which`, image links, seed/source stamps and current runtime outputs for provenance.

| Family / existing test | Observed failure | Repair and proof gate |
|---|---|---|
| ANF canonical corpus — `anf_direct_emit_test.bl` |81 old snapshot disagreements, including def-ast nested list lengths | Compile to a scratch corpus; inspect every structural difference against intended compiler changes and vector regression tests. Fix semantic regressions first; re-freeze only reviewed intended changes. Never auto-bless everything. |
| AOT drift — `aot_drift_test.bl` | Project fixture's own code-path beam is rejected as replacing a library namespace;3 failed assertions | `tier_owns?` currently treats any loadable initialized shim as tier-owned. Restrict the beam-only ownership branch to actual tier origin using existing ownership facilities; preserve genuine library shadow refusal. Gate fresh VM auto-heal and realm ownership, including project-AOT-beam versus packaged-tier cases. |
| Callable contract — `callable_test.bl` |17 old assertion failures: plain map arity, ref description, vector index-kind message, compiler/runtime parity | `is_atom(nil)` wrongly treats a plain map with no `__struct__` as a foreign struct. Distinguish actual struct membership, classify language ref-cells consistently, and separate invalid vector index kinds from arity errors. Preserve arbitrary foreign structs as uncallable. Run literal/runtime/packed/kernel matrices after one coherent boot rebuild. |
| Datom term ordering — `datom/terms_test.bl` |50/3,481 tuple↔opaque pair comparisons disagree | Codec byte tags and runtime family order differ. Establish intended public order with explicit tuple/ref/pid/fn/port cases; reconcile both without an unversioned persistent-key change. If current language order stays authoritative, version codec/reindex affected stores before tag cutover. If the documented order mandates a runtime correction instead, cover all public sort/compare consumers. Do not silently retag persisted keys or casually change global compare to make this test pass. |
| VM/session CLI — `bl_vm_test.bl` | Manager open call times out in selected runs; passed in ordered baseline | Capture manager status/monitors and actual duration on a cold image. Generated client calls use a5s default; synchronous realm startup is a candidate cause, not yet proven. Use an operation-owned configurable startup timeout or async manager reservation if proven; preserve CLI usage/exit contracts and avoid sleeps or blanket timeout inflation. |
| Xberg duplicate inputs — `document/xberg_test.bl` | Both reads fail and per-test log does not exist; reproduced on current main | Existing shell fixtures assume `$1` is the JSON request but production appends `--cold` before it. Read the last request argument (as the new passing recorder does), retain distinct per-input paths and duplicate-detection assertions, and ensure log/temp/env cleanup. Native carrier availability remains a separate gate. |
| Drop pack — `drop_pack_test.bl` | Release assembly refuses missing pinned `priv/z3/bin/z3`, then cascades into missing tree | Provision the pinned solver or use a declared prebuilt release fixture; fail setup once before downstream pack operations. Preserve default full-release solver requirements. Alternative optional-solver pack-only fixtures must be explicit and retain a separate full-release gate. Differences between valid gzip deflate streams are not themselves failures. |
| JSON nonfinite float — `bl/json_test.bl` | `math/pow(10.0,400.0)` arithmetic-exception assertion differs by suite order; isolated file passed | Minimize the failing preceding prefix and compare host `:math` resolution, language namespace shadow, captured callable, actual returned/error values and image authority. Repair the leaking namespace/host state at its owner; do not remove precision/overflow guards or guess a native-FP bug. |
| Exception-kind compiler image — `catch_exception_kind_test.bl` | Compiler path containment assertion (and ordered relative-path freshness assertion) fail; isolated file passed | Inspect actual `BL_EBIN`, `code/which` and canonical paths in both runs; minimize the order prefix and restore owner state. Separate image-provenance setup from throw/error/exit semantics. No forced purge of unrelated live compiler or weakened freshness assertion. |
| Index manifest — `bl/code/index_manifest_test.bl` | Ordered baseline file stat equality differs only in access time | Reading a file may update atime. Check intended no-op write proof via content/mtime/stable metadata, not read-induced access time; add an intentional-atime-change regression. Preserve proof that unchanged manifests are not rewritten. |
| Durable corpus temp lease — `datom/corpus_durable_test.bl` | Old shared `/tmp/x` fixture could collide with another process | Current main/preparation uses `open-fresh`. Retest cold and durable paths; no deletion of another process's lease or global tmp cleanup. |
| Emit/load failures at old capped tail — `emit_test.bl` | `core/reduced?` and `reload/commit-target-key` load failures appear around timeout/shutdown | First retest a fresh coherent floor. Separate genuine pre-termination failures from cleanup output and inspect image/link/env state. Do not count SIGTERM teardown output as independent product defects or claim a cause from annotations alone. |

### Execution order

1. Refresh and verify this merged source/floor/native image; retest representative old red files and newly incorporated source contracts.
2. Fix shared contract foundations (loader ownership and callable classification), batch boot edits, regenerate once and gate runtime/compile-time parity.
3. Settle the term-order contract and persistent-format migration deliberately. Fix isolated fixture/setup debts (worker argv, atime, release prerequisites and daemon startup instrumentation).
4. Minimize the JSON/compiler-image order failures on the now-coherent image and fix owner cleanup. Review canonical snapshot changes only after semantics stabilize.
5. Finish with an ordered full sweep using supported long JS/macro deadlines, serialized VMs and explicit memory/swap/runtime limits. Require a complete receipt; capped or incoherent output is not suite-green.

FUP-164 remains the durable owner of full-suite restoration. The user asked for this plan, not for silently waiving reds or shipping a suite-wide repair during the forward merge.

## Forward-merge compatibility receipt

The combined floor was rebuilt through the authoritative producer:97 beams, codegen5c7787003bb4 / driveraeb30e54b7e8. Initial auto tier rebuild succeeded, but `seed` defaulted to the legacy `_build/dev` ebin and its publication command failed (artifact609); the explicit actual `--ebin build` rerun succeeded (artifact612),49.073s/230.5M/0swap. No branch's generated input is selected as the final floor. Conflicts are resolved from regenerated output.

Fresh floor check79namespaces succeeds. Current merged21-file compatibility gate passes **8553 assertions,0fail,0incoherent** (artifact://1598ead9f02e4261/main/bash/613.txt),2m57.596s/470.6M/26.9Mswap. Tests cover vector compiler source, bounded cache/ring, attr concurrency/marks/validity, cold/durable/resident/selective corpora, cost, request CSS/live, style cache, native roots, optimizer174/lifetime32/kernel451 and native-vector JSON/JSON/catch-kind. Current fixture:1,097,120→90,717 reductions/200,976→1,212bytes,46,820→72,902 caller compilation reductions. No current app/UI speed claim.
