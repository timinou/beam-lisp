# Structural performance review: source-free migration and lazy engine

## Current behavior: how the repairs help

| Mechanism | What to learn |
|---|---|
| Demand loading | Declaring an alias records a dependency; using it initializes the provider. Bare/effect-only and refer-all requires stay eager. |
| Incremental keys | Body edits rebuild the provider; interface edits also rebuild consumers. Macro dependencies and compiler generations have stronger rules. |
| Safe publication | One complete source inventory includes literate files; a scoped repair never prunes unrelated output. A cold shim boots the registry before asking readiness. |
| Memo admission | One atomic occupied counter covers saved bytes and reservations. Concurrent publishers share one ceiling. |
| Replay-safe consumption | Producers claim before effects; a halted reduce keeps its prefix. Post-production budget refusal cannot replay that attempt. |
| Small native reads | Peek returns a tag/version; a later full read validates the version. Immutable cursor positions share one indexed root. |
| Safe lowering | Own-module identity and immutable plain-function dispatch remove proven work. Reloadable Core calls and namespace bindings keep their semantics. |
| Honest analysis | Every clause/guard is examined. Unsupported arities/effects stay unknown; shrinking stays inside generator domains; local helper-loop context is propagated. |

Final fresh `version` samples: **9.454097 / 7.465494 / 8.072850 s**,
median **8.072850 s**. The incremental fixture rebuilt **0** unchanged units,
**1** provider after a body edit, and **2** units after an interface edit.
Numbers are observations on a contended host, not a universal speedup ratio.

Read [self-hosting](../../docs/self-hosting.md) and
[lazy realization](../../docs/runtime/lazy-realization.bl.org) for the simple
contracts; [final measurements](performance-final-measurements.json) and
[continuation repairs](performance-continuation-repairs.md) retain the proof.
The review below is the historical diagnosis; its original measurements are
preserved rather than relabelled as current behavior. Global suite acceptance
remains separate from these focused and cold-package gates.

## Scope and evidence

Reviewed the migration and selective lazy-engine integration, including their current checkout behavior. Measurements were taken at HEAD `52f0a50d`; production sources were not edited and a full rebuild was deliberately not performed. This is a review and diagnosis, not a claim that the identified problems are fixed.

The warm harness MCP was unavailable. Instead, the repository's native `codebase`, `typed`, `veritas`, `system.analyze`, and `system.core` modules were exercised in fresh VMs. Every substantive runtime invocation used a bounded systemd user scope. Measurements are observations under a shared host's load, not portable benchmark claims. Call counts identify mechanisms; they are not CPU-time percentages.

Detailed companion reviews:
- [Startup/cache source review](performance-startup-review.md)
- [Lazy/native source review](performance-lazy-review.md), including an explicitly retracted false hypothesis and corrected byte estimates.

Reproducible probes:
- [Startup phase profiler](performance-startup-profile.sh)
- [Independent compiler-stamp audit](performance-image-audit.sh)
- [All four native logic surfaces and basic workload timings](performance-review-probes.bl)
- [Runtime retention, budget, dependency, and call-count probes](performance-runtime-probes.bl)
- [Native dependency graph and analyzer-limit counterexamples](performance-logic-deficiencies.bl)

Run the shell probes from the repository root with `sh`; run the BL probes with `bin/bl run`. Use `systemd-run --user --scope --collect -p MemoryMax=4G -p MemorySwapMax=1G` around a command. The all-surface probe was run with 6G/1G and four dirty-I/O schedulers. Budget probes restore the application setting; each runs in its own VM.

## Executive conclusion

The largest measured slowdown is not the lazy workload. It is repeated interpretation of a stale library image during ostensibly warm CLI startup. The image validator checks the boot tier, not the compiler-generation coherence of the whole executable image. The library loader then falls back to source without persisting a repaired artifact. The CLI's broad static dependency closure magnifies that deficiency.

The lazy engine has separate structural costs: whole-result fold memoization, a publication path that bypasses the advertised cache budget, whole-state copies for tag-only decisions, and extensive generic dispatch/construction/lookup work within a small element loop. The native fast lanes do not remove those BL-level costs.

A zero-source inventory and a successful `version` invocation do not establish a fast, coherent image. The previous verification accepted a warm startup measured in minutes; that should have been treated as a performance regression to diagnose, not merely as a successful boot. The previous agent did accurately disclose that the full current-main release/full suite remained unverified; this review does not erase that caveat or attribute every historical failure to one cause.

## Measured startup

Three unchanged `bin/bl version` runs, with no reported tier rebuild:

| Run | Wall seconds | Child CPU seconds | Exit |
|---|---:|---:|---:|
| 1 | 124.793 | 127.999 | 0 |
| 2 | 173.873 | 160.086 | 0 |
| 3 | 164.673 | 153.939 | 0 |

CPU is the sum of child user/system CPU over the CLI's processes. These values do not support diagnosing the dominant delay as an idle filesystem/dirty-I/O wait. Host contention can change the numbers, but cannot explain away the repeated expensive execution path.

A separate seam-instrumented real launcher boot measured:

| Phase | Seconds |
|---|---:|
| Start application | 9.003 |
| Load `vm.native` | 3.247 |
| Native `build-all!` invocation | 0.0034 |
| Load `bl.cli` | **174.419** |
| Invoke `run-argv` for positional `version` | 8.495 |
| Entire `Launcher.boot` | 195.922 |

The parallel startup review independently observed `bl.cli` loading in 144.0/161.5 seconds, 144 AOT-load calls, 120 closure-hash checks, 135 reader calls and 3,118 form evaluations. Its closure-hash calls consumed 16.89 seconds in aggregate. These are separate runs, not values to add to the orchestrator's phase table.

## Ranked findings

### 1. P0: boot-only health validation permits a repeatedly interpreted mixed-generation image

Anchors: `priv/host/launcher.bl:400-420`, `priv/host/aot.bl:1238-1256`, `priv/host/loader.bl:273-345`.

Observed compiler-key audit:
- Current compiler key: `2693fef944b7ba2e9b0a728b57081930481beef598fcea7e3ef6e4c53b222e5c`.
- 10 namespace BEAMs carry that key.
- **273 namespace BEAMs carry `330d4b72994a561d3e75b1f20aaa0a36f955860138f4641abd5ac1dae0a3b6c9`** instead.
- Another 21 carry `ee85c8a3bd6518245e5a0878c41dd434bcd92e3eb27a69b50bd2629eeb48b59d`; the current build key is `65481968f684504333f3d4edb8b1ef3165c32bbbfa517ec8df91f5dee7b4efc0`.
- `Ns.Core`/`Ns.Rt` match the current compiler. `Ns.Bl.Cli`, `Ns.Vm.Native`, and `Ns.Typed` do not.
- 522 additional namespace-prefixed modules have no compiler-key attribute; many are Body/Init implementation modules. Their absence is not by itself a missing-provenance defect: the public namespace wrapper is the provenance-bearing surface.

The launcher judges only `Tiers.boot_namespaces`. Each subsequently requested library namespace rejects its old compiler stamp, returns `:no_module`, and is evaluated from source in the serialized loader. That source fallback marks the namespace loaded in this VM, but does not compile/store a replacement BEAM or cache entry. The next VM pays again.

Independent negative proof: `BEAM_LISP_AOT_STRICT=1 bin/bl version` exits 1 on `vm.native`. Its compiled/current **source hashes are identical** (`5b1506b78470` prefix), proving that source-byte drift is not required for the failure; the compiler generation is stale.

Repair: represent image health across boot, driver, and requested library generations, or compile/write back stale libraries once. Warn once per VM on compiler-generation fallback. Reconcile scoped-build deletion semantics first (finding 2), then regenerate a complete coherent image. Do not silently accept boot-tier health as whole-image health. Add an unchanged-image gate asserting zero source form evaluations on the repeated invocation.

### 2. P1: the partial self-heal build is passed to a driver with full-snapshot deletion semantics

Anchors: `priv/host/launcher.bl:254-307`; `priv/build/build.bl:665-733`, especially `keep = set(sources)` and deletion of every recorded source not in `keep`.

The launcher supplies a boot-tier subset. `build/run` interprets its supplied sources as the complete authoritative universe, drops all other recorded source facts, and deletes their owned BEAMs. The startup reviewer observed a current build log containing only the partial boot-tier source set. The deletion rule is source-proven; this review did not deliberately run a destructive reproduction against the live image.

This is an ownership/interface deficiency, not a slow filesystem operation: the API cannot distinguish “build this scope” from “replace the complete source inventory.” A repair that merely widens the launcher's automatic rebuild without first clarifying that contract risks losing build state or unrelated artifacts.

Repair: make scope versus authoritative inventory explicit. Prune only within an owned tier/scope, or require a complete inventory for deletion. Test that a boot-only rebuild preserves library log facts/BEAMs and that a full authoritative build still deletes truly removed sources.

### 3. P1: a metadata command eagerly reaches daemon/auth/datom/UI dependencies

Anchors: `priv/std/bl/cli.bl:17-18`; `priv/std/vm/client.bl:17-18`; `priv/std/bl/cli.bl:1049-1078`.

The native codebase/source-graph query found **122 namespaces** in the static `bl.cli` require closure. Its direct requires are only `bl.util`, `bl.env`, `bl.trace`, and `vm.client`, but the latter eagerly requires `vm.session`, bringing the server-side daemon composition into a client/CLI load. The closure includes auth, datom/query engines, loom/UI, system/oracle, and daemon manager/net/session modules.

Positional `version` also takes the ordinary `with-project` branch; `--version` already has a metadata-only branch. The profiler measured 8.495 seconds inside dispatch after the 174-second CLI load. That number cannot be apportioned to individual project effects without a finer trace, but the branch distinction is explicit in source.

Repair: split thin transport/probe functions from daemon startup or resolve the daemon composition only in `start-foreground`. Reuse the existing lazy verb-loading affordance; do not invent a parallel CLI/version implementation. Route observational commands through an appropriate lightweight path while retaining documented project semantics where needed. Add a dependency-graph gate that metadata commands do not reach unrelated daemon/UI/auth composition.

### 4. P1: cache-key rejection performs expensive source-closure hashing before a cheap decisive comparison

Anchor: `priv/host/aot.bl:1238-1256`.

On the library branch, `ns_closure_hash` runs before comparing the beam's compiler key. Every one of the already-known incompatible library artifacts thus pays for source discovery/parsing/closure hashing. The source reviewer measured 120 such calls totaling 16.89 seconds. The compiler key is already available and memoized.

Repair: compare generation first. If incompatible, report the actual compiler keys or take the repair path without hashing the entire source closure first. For compatible generation, preserve live source drift detection and its dependency correctness. The strict error currently reports equal source hashes and recommends deleted Mix commands (`mix compile.beam_lisp --force` / `mix clean`); replace that diagnostic with the actual reason and the live `bl build` recovery path.

### 5. P1 correctness/resource: fold publication bypasses cache admission and materializes the whole result

Anchors: `priv/boot/rt.bl:3929-3963`; `priv/host/lazy_seq.bl:236` and `:361`; `priv/host/lazy_memo.bl:386-436`.

The fold recipe accumulates every produced element into a reverse list, reverses it, walks/measures it, then copies the completed value into native memo storage. It avoids a memo cell per element but is not a bounded-storage fold. The ordinary force path calls `admit!`; `publish_folded` does not.

Observed in a fresh VM with the setting restored afterwards:
- With `lazy_cache_budget_bytes = 0`, `(count (map inc (range 40)))` returns **40**.
- Under the same setting, `first` on the equivalent producer throws `{:lazy_cache_budget_exceeded, 0}`.
- `veritas/for-all` over lengths `1,31,32,33` refutes the actual refusal property with **witness 1**, using finite enumeration. Budget changes are isolated inside the tested helper so the logic engine itself retains normal allocation admission. It also returns `shrunk 0`, outside that generator's domain; the original witness is the valid counterexample.
- A rooted 16,000-element mapped sequence's actual completed memo measures **256,024 bytes** (`16n + 24` for small integers on this 64-bit VM), independently matching the synthetic completed-list estimate.
- Its second count incurred two dirty read operations and returned in 2.624 ms in the held-root run; whole-state reads remain visible despite only needing to choose a path/count.

Reservation is also necessary beyond the zero-budget case: a pre-claim occupancy check alone cannot enforce a byte ceiling when a later publication is arbitrarily large or concurrent publishers start below the threshold.

Repair: budget/reserve publication bytes, including fold publication; preserve failures and release reservations correctly. Publish bounded chunks if using a streaming traversal. Do **not** remove memoization/buffering blindly: side-effecting producers must still execute once and repeated consumers must see the same values. A held memoized head necessarily retains realized values; a separately explicit non-memoizing or purity-proven consuming fold has different semantics.

### 6. P1/P2: generic dispatch, tuple construction, live var lookup, and module discovery remain inside element loops

Anchors: `priv/boot/rt.bl` kind/invoke/reduce paths; `priv/host/env.bl:83-89`, `:546-555`, `:719-739`; `priv/host/lazy_seq.bl` chain/materialization loops. See companion lazy review for exact per-loop compiler anchors.

For one 16,000-element lazy map-indexed/reduce operation, `cprof` observed:
- 776,795 calls to `kind-kind` in the Rt body, plus the same number through its namespace wrapper.
- 131,424 Rt-body `invoke` calls.
- 33,561 `Env.fetch!` calls and 33,565 `Env.own-module` calls.
- 229,118 `tuple_to_list`, 228,543 `setelement`, and 228,074 `make_tuple` BIF calls.
- 62,509 memo dependency-walk calls.

`Env.own-module` discovers the module through a fresh fun literal plus `fun_info` on every epoch lookup. That preserves retargeting correctness, but is runtime work substituting for an absent compile-time module-identity affordance.

Unprofiled all-surface probe timings for equivalent final integer answers:

| n | Lazy map-indexed/reduce | Eager map-indexed/reduce | Raw Erlang list fold |
|---:|---:|---:|---:|
| 1,000 | 7.435 ms | 10.702 ms | 0.014 ms |
| 4,000 | 48.441 ms | 27.093 ms | 0.033 ms |
| 16,000 | 123.323 ms | 83.432 ms | 0.170 ms |

The raw fold lacks memoization, dynamic callable semantics, and general collection support, so this is a diagnostic lower bound, not an expected drop-in speedup. The instrumented run took 376.371 ms and is not comparable to those unprofiled times. Nonetheless the call ledger exposes much more than one reducer dispatch per element.

A separate three-repeat callback decomposition measured Core arithmetic/reduction at **140.877–159.889 ms**, direct BIF arithmetic/reduction on the same lazy pipeline at **98.087–180.050 ms**, and raw list folds at **0.263–0.359 ms**, all returning 255,984,000. Replacing the arithmetic callback alone did not reliably erase the broad lazy/dispatch overhead. These ranges overlap under changing host load; no isolated numeric-dispatch speedup is claimed.

Repair: use type/kind evidence to select a raw collection/reducer kernel once; keep generic semantics at entry/boundary crossings. Lower tuple literals and module identity directly in pinned-host emission. Use direct recursive/tail-call lowering where sound rather than self-application scaffolds. Hoist only stable or epoch-guarded callable resolution: hot reload, rebinding, and per-env vars must remain correct.

### 7. P2: native state/graph machinery has additional serial and copy amplification

Anchors: `native/lazy_memo/src/lib.rs:140`, `:620-681`, `:730-752`, `:848-872`; `priv/host/lazy_memo.bl:271-315`, `:420-436`; cursor/collector anchors in the companion review.

Source-backed mechanisms, not individually timed improvements:
- Reading a memo exports the whole term even for a tag/version-only decision. Add a separate constant-size peek; do not narrow the public full-state diagnostic API. A peek's tag/version is not a durable snapshot: subsequent exports and CAS decisions must validate the expected version or retry if the state changed.
- A fast publication attempt reroutes when new dependency edges exist; the wrapper still tries it first. Known nonempty dependency lists can be routed directly to the required dirty path.
- Dependency extraction, `flat_size`, and native copy are multiple passes over a completed value.
- Global graph mutex guards span term copying, and edge membership checks use repeated linear searches. This can serialize unrelated publishers.
- Cursor walking allocates/registers another resource per 32-element chunk; budget admission constructs the full stats map per attempt; collector census serializes cell state to ETF.

Repair in measured increments: peek and a dedicated retained-byte counter first, then direct lane routing, then graph-lock scope/edge data structures and cursor allocation. Revalidate CAS/version, cycle collector, notifications, and concurrent force ownership when changing lock scope. After reacquiring the graph lock, rerun cycle reachability against the fresh global graph atomically with insertion: local version/edge checks cannot detect another cell's newly published reverse edge. Do not replace correctness mechanisms with guessed fast paths.

### 8. P2: the native logic analyses have coverage limits that cannot justify a clean performance bill

Anchors: `priv/lib/system/analyze.bl:99-134`; `priv/std/typed.bl:747-791`; `priv/std/codebase.bl:249-333`.

Executed counterexample:

```clojure
(defn overloaded ([x] x) ([x y] (File/read! x)))
```

`system.analyze` returns an empty call set, empty footprint, and `terminates true`. It selected the first clause and missed the second clause's I/O. Its doc describes a spike scope; the implementation uses `first parsed`. This is not adequate as a whole-host assurance after a multi-arity ABI migration.

`typed/check-source` reports zero warnings but an all-types return/evidence set for the unannotated example. In the real host checks it also returned zero warnings; the system summaries were commonly all-types and `:opaque-world :W`. These are unknowns, not proofs of absence of effects or specialization opportunities.

Codebase indexing found the real calls and definitions. Its loop-depth facts are syntactic, however: helper-mediated and foreign `Enum` iteration require interprocedural loop/cost propagation. Zero loop depth on a helper's file-read site does not prove that it is not invoked once per source/row.

An additional Veritas coverage limitation was observed: finite `one-of 1 31 32 33` produced a valid violating `:witness 1`, but reported `:shrunk 0` outside the supplied domain. `priv/lib/veritas.bl:546-547` only branches on tuple shape before applying generic shrinking; it does not preserve the generator's bounds/domain. Preserve and use the original witness for this finding; make shrinking generator-aware before treating the shrunk value as a valid minimal in-domain counterexample.

Repair: union all clauses or index summaries by function-and-arity and propagate their union at callers. Carry explicit unknown/coverage status. Supply reliable host/NIF state/type/effect signatures and loop-aware interprocedural cost facts. Use these to justify specialization/hoisting, not merely to suppress warnings.

## Native logic evidence and rejected hypotheses

- `codebase/index-source`: actual migrated hosts yielded 66/29/2/68 definition facts and 502/234/38/298 call facts for AOTCache/Launcher/SeqCursor/LazyMemo respectively; I/O sites and call positions were recorded.
- `typed/check-source`: ran on those four hosts; zero warnings, but no claim of whole-program proof. Evidence and unknown precision were recorded.
- `system.analyze`: ran on all four hosts, propagating local call/return/effect summaries; multi-arity negative coverage probe reproduced its limitation.
- `veritas/for-all`: also refuted the actual zero-budget fold-refusal property with finite-domain witness 1; generic shrink left the domain, explicitly recorded above. It proved output parity for map-indexed across finite chunk-boundary values `0,1,31,32,33,63,64,65` using exhaustive enumeration, not SMT. This does not prove arbitrary-input producer correctness or speed.
- `system.core/prove-box`: proved the explicit modeled occupancy invariant `0 <= c <= 32` for emit/flush transitions using SMT. This is a model proof, **not** verification of the implementation's lowering.
- Rejected: improper cons cells losing lazy dependency edges. Erlang `is_list([1|foo])` is true. A real cons with a lazy-node tail reports dependency count 1. The companion review retains the retraction rather than hiding it.
- Rejected: native cursor chunking necessarily re-copies the entire remaining tail. The source review checked Rustler's same-`OwnedEnv` behavior; no quadratic tail-copy defect was established.
- Not established: every old suite timeout or datom correctness failure has this cause; collector cost alone explains minutes; an unmeasured proposed optimization yields a stated speedup.

## Repair order and acceptance

1. Clarify full-inventory versus scoped-build pruning, then repair/check the complete checkout image. Preserve the source-free/pinned ABI cutover; do not resurrect Elixir source or an RT alias.
2. Compare generation before closure hashing; diagnose stale libraries and current compiler keys, with live recovery instructions.
3. Trim CLI/client dependency closure and unnecessary project initialization for metadata paths.
4. Enforce budget at fold publication and add constant-size state peeks; keep realize-once semantics.
5. Decompose generic collection/callable/tuple/module-identity overhead using stable native kernels and sound type/effect evidence.
6. Optimize NIF graph/cursor/collector details only after measuring their independent costs and re-proving concurrency invariants.
7. Harden native analysis coverage and performance gates.

Required proof after repairs: a coherent, freshly built current-main image; repeat startup with no source fallback/form evaluation; scoped-build preservation tests; strict-mode boot; chunk-boundary and side-effect/failure replay parity; zero/near-budget and concurrent publication tests; separate startup/workload timing with reductions, native counter deltas, and rooted retention measurements. Avoid hard latency assertions on a contended host: structural counters and algorithmic scaling are the portable gates. Keep full-suite correctness classification separate from this performance diagnosis.
