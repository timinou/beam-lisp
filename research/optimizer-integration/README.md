# Optimizer integration: spike record and revisit ledger

Status: **experimental research record.** What shipped by default is a small set of checked laws (see `docs/compiler/optimizer.bl.md`). Everything else below was prototyped, measured or analysed and deliberately left out of the default. This file says why, and what evidence would change that. It makes no performance promise for any program or domain not measured here.

## 1. Orientation

- Implementation home: `priv/host/optimize.bl` (`BeamLisp.Optimize`), thin facade `priv/boot/optimize.bl`, one shared hook in `lower/module->core`. Do not add a competing rule engine or an application-level pass.
- Compiler guide (current design): `docs/compiler/optimizer.bl.md`.
- Roadmap and dependency order: `!tasks/artifacts/optimizer-coverage-roadmap.md`.
- Historical delivery (immutable evidence): `!tasks/artifacts/optimizer-prototypes-delivery.md`, `!tasks/artifacts/optimizer-prototypes-results.json`, earlier `!tasks/artifacts/optimizer-delivery.md`, `optimizer-measure-results.json`.
- Design proposal the work started from: `!tasks/artifacts/sequence-prototype/generalization.md`; kernel experiment: `!tasks/artifacts/sequence-prototype/` (`README.md`, `results.json`, `test.log`, `benchmark.log`); overhead diagnosis: `!tasks/artifacts/sequence-overhead-diagnosis.md`, `sequence-overhead-summary.json`.
- Raw logs (hash-indexed): `!tasks/artifacts/performance-evidence/optimizer-prototypes/` (`index.json`).
- Harnesses and tests, all reproducible from the repository:
  - `!tasks/artifacts/optimizer-lexical-measure.bl` – current normal-source compile/code/timing, disabled vs production. The historical three-mode harness and its 135 samples are retained at commit `22fd15ee` and in the immutable prototype evidence; current runs are a distinct generation.
  - `!tasks/artifacts/optimizer-mode-measure.bl`, `optimizer-mode-stage.bl` (isolated whole-RT variants; `BL_MODE_PACKED=1`), `optimizer-mode-audit.bl` (step disassembly, ingress).
  - `test/bl/optimizer_lexical_prototype_test.bl`, `optimizer_mode_prototype_test.bl` (`BL_MODE_SNAPSHOTS=1` for machine-readable outcomes), `optimizer_open_world_prototype_test.bl`.
  - `!tasks/artifacts/optimizer-stage.sh`, `optimizer-cold.sh` for staged images and cold acceptance.

A finding is only as current as the generation it ran against. The prototype ran against a frozen checkout (`9f76122a` plus overlay) while `main` moved on. A strict or cold proof of that frozen generation does **not** prove the current `main`. The production cut has independent acceptance on snapshot `f4e26caf`:317sources built without errors,105focused tests/3680assertions, executable guide,150checked samples, an official97module seed and strict cold105/3680with zero staging exemptions. See `!tasks/artifacts/optimizer-promotion-delivery.md` and the immutable `performance-evidence/optimizer-promotion` checkpoint. The `ns-defs-beam` integration has a separate combined-generation gate:317sources built, an official97module/67host floor,203tests/4216assertions in a strict fresh VM, and checkout-root44tests/560assertions; all zero failures/errors and zero staging exemptions. See `!tasks/artifacts/optimizer-ns-defs-merge-delivery.md`. Neither pre-merge acceptance nor the old branch seed substitutes for that evidence; no new package is claimed.

## 2. Separating three questions

Every deferral below fails one of these, and mixing them is how bad optimizations get approved.

1. **Facts** – what is known about the program. Only from executable ANF plus lexical scope. Source annotations, diagnostic tags, coarse flow and read footprints are not certificates. The solver is offline only: it may validate laws and reject negative controls, and has no production dependency. Missing, timed-out or unknown means baseline.
2. **Safety** – does the rewrite preserve results, errors, effect count and order, demand (what a lazy source is forced to produce), and resource/quota behavior that programs can observe. Unknown → baseline.
3. **Profitability** – does the emitted code do less work, and is compile time, output size and deployment cost acceptable. A rewrite can be safe and still not worth shipping.

Identity note: *arithmetic* (what `+` computes on integers) and *name* (the symbol `+`) are different from the **value** passed to `reduce`. The production public `+` value is a tagged variadic callable, not a native binary adder; the symbol can be shadowed or rebound. Facts must name the exact value, not the spelling.

## 3. What the default contains and why

| Piece | Evidence | Verdict |
|---|---|---|
| Native invocation, numeric domains, literal integer fold | ordinary-source samples at 16000: guarded native loop 1263→1054 µs, 144380→80279 VM reductions; integer fold 536→582 µs, 54229→55530 (no gain observed) (roadmap, "Evidence") | native call kept; integer-fold specialization is retained but is not a speed claim |
| Strict map/fold including callback aliases and a private mapped list | lexical harness, 16000: private list 931→269 µs, 118615→55550 reductions; aliases+private list 989→172 µs, 118615→53189 (delivery doc). Fusion removes the `lists:map/2` instruction. Strict fusion reduced execution work by more than 2× in the private prototype | **default**, bounded: 64-node callback grammar, cumulative inline allowance seeded by `:max-nodes`, visitor budget |
| Standalone callback-alias rematerialization (no intermediate removed) | alias only: 327→276 µs but 55255→55708 reductions, i.e. no work saved; BEAM 1040→1140 bytes; unused closure definitions stay | **refused** as unprofitable |
| Runtime normalization / guard hoisting | see §4 | **not promoted** |
| `{:lexical? true}` option | existed so the experiment could be gated | **retired**: the capability is default and bounded; there is no flag. `:enabled? false` remains the reference emission |

The 135 lexical timing samples are three cases × sizes 1000/16000/64000 × three variants × five alternating-order repeats; every answer is checked; input construction is included. Timings are contended-host observations. No allocation or total-memory claim exists for them.

## 4. Negative results and why baseline remains the default

Runtime normalization is an explicit fifth argument to `rt/k-reduce` (`:baseline` or `:normalized`); three/four-argument calls are baseline. Hoisted variants exist only as isolated generated images (`optimizer-mode-stage.bl`) and never as the published walker. Callback normalization chooses callable representation once per traversal. Separately, trace comparisons normalize only cross-VM reference/function identities; they do not mask changed semantic values or assume map traversal order agrees between VMs.

Initial run (4800 checked rows), 16000/list/kernel VM reductions: native 160161 baseline vs 160459 packed hoist (no reduction); tagged adder 306311 baseline vs 705587.5 normalized; public `+` 1009952.5 vs 1410459. The generic wrapper added a `reduce-two` helper and `erlang:apply/2`.

After removing that helper (2400 further rows, corrected wrapper), baseline → normalized: native 160080→161303; tagged adder 305217→323002; public `+` 1008768.5→1025296.5. Packed image ≈160565 / 323372.5 / 1025805.5. The wrapper still adds roughly one reduction per element and native work is unchanged. **Why baseline:** the only per-element saving available is a guard the VM already evaluates cheaply; wrapping adds a call frame that costs more than it saves. Packed hoist removes the guard and list allocation in `step/3` bytecode (`call_fun/2`) but showed no native-work reduction. Cross-image wall times come from separate contended VMs and are not controlled speedups.

Also negative: the first lexical implementation could materialize a callback body per use (unbounded growth); that is why the cumulative allowance exists. A named wrapper that only moves a check, or hoisting that adds a helper plus generic `apply`, is not an improvement.

Safety evidence for normalization remains useful if it is ever revived: 2128 canonical outcomes matched helper-hoisted outcomes after normalizing only cross-VM reference IDs and generated Eval function identities; a SAME-VM oracle adds 512 assertions. Gates: strict 103 tests / 3141 assertions; helper and packed hoist 80 tests / 2904 assertions each; these overlap and are not a repository total.

## 5. Revisit ledger

Common rules for every row:

- *Failure if shipped now* = what would break or regress today.
- *Gate* = tests that must exist and pass before the default changes; each also needs on/off parity (`:enabled? false`) for results, errors and effects, and a negative control for every counterexample listed.
- Measure, as relevant: compile time, output node/BEAM size, evidence storage, matched VM reductions, allocation (only if claimed), and deployment (below).
- *Deployment gate* where the change alters the compiler or runtime: coherent source-free seed, fresh-installation strict check with no prior-generation exemptions, rebuilt package audit and outside-tree smoke. Old package or frozen-generation evidence never substitutes.
- Unsafe or unknown cases report a refusal, never an approximation.

### 5.1 Alias-only cloning and dead closure cleanup

- **Rationale for deferral:** profitability. Measured: no VM-work reduction, BEAM size grew.
- **Failure now:** code growth with no work saved; leftover original closures.
- **Dependencies:** a dead-closure elimination that proves the original binding unreferenced and its construction effect-free (closure creation is pure but must be checked after rewriting); or evidence that a downstream pass consumes the cloned form.
- **Counterexamples:** alias used by both a rewritten and an unrewritten call; shadowing; alias captured by another closure.
- **Promotion evidence:** a measured ordinary-source workload where alias specialization removes real execution work, with bounded callback expansion and an explicit acceptable compile/output-size tradeoff. Smaller BEAM alone is not an execution-speed proof, and small bounded growth need not forbid a useful win.
- **Home:** `Optimize` fact/rewrite plus dead-binding cleanup, same file. **Tests:** extend `optimizer_lexical_prototype_test.bl`; measure with `optimizer-lexical-measure.bl`.

### 5.2 Immutable captures

- **Rationale:** callbacks with captured scalars (`(fn [x] (* x k))`) are common; facts need the capture's domain and immutability.
- **Failure now:** wrong-domain capture (float, decimal, map) would take the integer path and silently change results; a rebound global would be read at a different time.
- **Dependencies:** lexical binding identity, proof of the actual integer value/domain captured at closure construction, resolved in its definition environment; later shadowing must not reinterpret that capture. Preserve original binding evaluation and distinguish a captured immutable integer from a captured mutable reference or a live global read; retain the 64-node bound.
- **Counterexamples:** captured value shadowed; a `var`/atom reference; a capture derived from a call that can raise.
- **Promotion evidence:** ordinary-source cases where captures prevent fusion, with measured win and parity on shadowing/overflow-to-bignum.
- **Home:** `Optimize/fact`, `int-callback`. **Tests:** lexical prototype tests plus capture negative controls.

### 5.3 General use / escape analysis

- **Rationale:** current private-use proof is structural: the let body is the sole direct consumer. More general proof needs use counts and dominance across nested scopes.
- **Failure now:** treating a list as private when it is returned, stored, closed over, or consumed twice would drop a visible intermediate or its order of evaluation.
- **Dependencies:** binder-aware use counting, evaluation-order preservation (the backend evaluates packed cons arguments tail before head; do not assume a standard order), recursion-knot refusal.
- **Counterexamples:** use inside a closure that is never called; shadowed name; use in an accumulator; use under `recur`.
- **Promotion evidence:** shapes in real code that the structural rule misses, measured. 
- **Home:** `Optimize`. **Tests:** escape/aliasing matrix incl. wildcard binding ABI and generated-name collisions.

### 5.4 Strict map chains and filter/fold

- **Rationale:** interleaving stages is only equivalent when stages are total, stable and effect-free over the accepted inputs, since baseline runs whole stages in sequence.
- **Failure now:** a filter or chain with a partial mapper changes which error is raised first, or whether it is raised at all; reducer orientation could flip.
- **Dependencies:** per-stage domain facts (e.g. total integer comparisons), sequential fold order, a law per composition.
- **Counterexamples:** mapper raising on a late element after a filter would have rejected it; noncommutative reducer; empty and all/none filters; bignum, zero, negative.
- **Promotion evidence:** a real call site with measured benefit; a law and a counterexample negative control per composition (offline solver may check the law).
- **Home:** `Optimize/fuse-fold`. **Tests:** new fusion tests beside `optimizer_lexical_prototype_test.bl`.

### 5.5 Public `+` value, helper flow, body invalidation, guarded suffix

- **Rationale:** `(reduce + 0 coll)` is a common source form, but the public `+` is a tagged variadic callable. Native arity does not identify the operation; the name may be rebound.
- **Failure now:** specializing on the name or on arity would mis-handle floats, decimals, mixed values, a rebound `+`, and error text.
- **Dependencies:** exact captured callable and body identity; numeric-domain equivalence for the binary case; dependency invalidation so a helper body-only edit (same module/name/arity) invalidates facts; helper parameter flow needs function/arity identities with explicit widening to unknown (coarse 0-CFA alone is insufficient); for entry-proven facts that can change mid-traversal, a **guarded suffix continuation** that falls back from the current state. **Never replay a prefix** that already had effects. Entry epoch checks do not justify dropping later live reads.
- **Counterexamples:** rebinding before and during traversal; body replacement; first element float; bignum; one/zero element.
- **Promotion evidence:** open-world tests (`optimizer_open_world_prototype_test.bl`) extended to the public value, plus measured win over the 1.0M-reduction baseline above.
- **Home:** `Optimize` plus `rt`/`core` providers. **Deployment gate applies.**

### 5.6 Runtime normalization and hoists

- **Rationale:** §4. Only the fifth-argument explicit control exists in source; hoists exist only in generated isolated images.
- **Failure now:** extra reduction per element for tagged and public callables; native unchanged.
- **Dependencies:** a wrapper that adds no frame (inline the mode into the shared loop mechanics) or a once-per-traversal check shown to beat the existing per-element check; preservation of live `core/reduced?` fetches after callbacks and at exhaustion, initial/empty behavior, one sentinel peel, improper-tail errors, no eager rejection of an invalid callable on empty input.
- **Counterexamples:** the wrapper envelope being native while the user callback is not; predicate rebinding before/mid/terminal.
- **Promotion evidence:** matched VM-work improvement for the exact admitted callable domain, baseline fallback without regression for other domains, and the same-VM step oracle plus all ingress/empty/error/live-predicate gates passing. Include chunk sizes 31/32/33/63/64/65; do not infer a large-input win from a tiny loop or vice versa.
- **Home:** `rt` `step`, `k-fold`, `k-reduce` only; hoisting stays in isolated generated images unless that evidence appears. **Tests:** `optimizer_mode_prototype_test.bl`, `reduce_kernel_cutover_test.bl`; audit with `optimizer-mode-audit.bl`.

### 5.7 Indexed consumers, early halt, transducers, builders

- **Rationale:** `map-indexed`/`keep-indexed`/`for` use the chunked lazy engine, not `lists:map`. Index-before-filter differs from index-after-filter. Transducers need the 0/1/2-arity init/complete/step protocol, early Reduced completion, stateful ordering, output representation, transient/persistent boundaries and metadata. `reduce-kv` is a separate contract.
- **Failure now:** wrong index after a filter, extra demand after halt, suppressed chunk lookahead errors, a missing completion call, lost metadata.
- **Dependencies:** an explicit halt model; closed finite sources and scalar consumers first; shared builder mechanics for `into`, `sequence`, `mapv`, `filterv` (result storage still allocates).
- **Counterexamples:** sparse filters; finite consumer over infinite input; stateful `take`/`filter`; empty and transient-threshold inputs.
- **Promotion evidence:** force/chunk-publication traces equal baseline, not just sums, plus measured gain.
- **Home:** core engine and `Optimize` laws. **Tests:** extend the lazy/xform suites.

### 5.8 Shared lazy values, replay, quota, native authority

- **Rationale:** highest risk. Single syntactic use does not prove a lazy value is private (aliases, saved sources, shared memo cells, concurrent consumers). Native admission/quota refusals are observable. `system.linear` checks emission size, not ownership.
- **Failure now:** fusing would skip a refusal or charge a program can observe, break replay of a published prefix, or change retry after producer failure.
- **Dependencies:** ownership/use/demand facts separating construction, realization, replay, failure/retry, immutable cursor roots (`BeamLisp.LazySeq`, `LazyMemo`, `SeqCursor`); a decided resource policy (preserve logical charges, or a documented supported policy). A solver proof of arithmetic does not decide that policy. Native admission authority is not bypassed.
- **Counterexamples:** two consumers; escape through return/container/closure; partial realization; chunk boundaries; quota refusal; concurrent realization; collector roots.
- **Promotion evidence:** all of the above pass as refusals or as parity; a measured need that strict code cannot meet.
- **Home:** lazy hosts and `Optimize`. **Deployment gate applies.**

### 5.9 Closed forms, scalar replacement, query/native offload

- **Rationale:** each needs obligations beyond fusion: arithmetic and termination for formulas (the earlier formula prototype covers its closed DSL only); construction/access/metadata/error contracts for scalar replacement of tuples, vectors, maps, closures; null/duplicate/order/effect/scheduling/domain laws for query pushdown, batching and native offload.
- **Failure now:** a formula that changes overflow or error behavior; a scalar-replaced value whose identity or metadata is observed; offload that reorders effects.
- **Dependencies:** a profile showing the remaining cost is in these shapes; per-domain law and counterexample.
- **Promotion evidence:** real-workload profile first; no inference from current eligibility verdicts. I/O, algorithms or scheduling may dominate.
- **Home:** separate design per domain, `Optimize` for the law; datom/query libraries as beneficiaries. **Deployment gate applies.**

### 5.10 Namespace-table overlays and definition-dependent facts

- **Integrated seam:** `ns-defs-beam` supplies a shared BEAM literal for AOT declarations, with a small environment reference and whole-map snapshots for source/live edits. Env, Link and AOT must be deployed coherently. Definition storage is cheaper; it is not new optimizer proof authority.
- **Observed integration counterexample:** a cold value initializer defining another function in its own namespace lost the original declarations and left a dangling reference when table linking ran after value replay. The retained cold replay regression failed3assertions plus an undefined-function error. Publishing declarations before value initializers and keeping the resulting live overlay fixes it; initializer order and ready publication remain unchanged. Independent source review249 accepted the repair; combined-generation acceptance is recorded separately.
- **Deferred:** sparse per-definition overlays, point lookup and immutable generation-addressed table backing. A whole-map snapshot currently makes inherited removals and explicit empty overrides unambiguous. A small delta against a mutable module reference could silently follow a later body replacement or resurrect a deleted definition; an immutable backing also needs bounded module/atom/literal lifetime and safe reclamation.
- **Revisit trigger:** profile an editor/reload workload showing map-overlay copies or repeated whole-table lookup dominating after the shared-literal improvement. Compare point lookup and batched reads before adding another storage representation.
- **Promotion gates:** parent/child/sibling inheritance, empty overrides, tombstones, old-generation reads, initializer self-mutation/failure, macros and callers lookup, namespace destruction, reload/purge and memory reclamation. Show reduced lookup/update work with bounded retained memory and metadata-identical answers. If definition tables feed specialization, add body/epoch validity and cache-invalidation gates; signatures and module atoms alone are insufficient.
- **Homes:** Env table lookup/update and lifetime, Link publication, AOT table/init emission, source graph/AOTCache validity; authorization remains Optimize. Retained tests: `ns_defs_beam_test.bl`, `env_callers_of_test.bl`, `env_isolation_test.bl`, namespace/AOT/reload suites and open-world optimizer adversaries.

## 6. Review plan

Milestones, in order, each with its own gate; nothing here is blocked or forgotten.

1. **Current generation verification — accepted.** Strict combined203/4216 and checkout-root44/560 pass with the accepted floor. A newly published distributable additionally requires regenerated package audit and outside-tree smoke. Current-source acceptance does not imply package publication.
2. **Coverage scan — recorded, profiling next.** Six namespace bodies/884definitions yield666unknown-or-mismatched native-arity and86live-provider/lazy-demand refusals; these are static categories, not call frequency or proven opportunities. Profile actual hot callers, then prioritize callable-shape/helper validity and provider lookup alongside §5.2/§5.3. Script: `optimizer-coverage-scan.bl`; evidence and limitations: combined delivery report.
3. **§5.3 and §5.2** together (use/escape and captures) if the scan shows they block common fusions.
4. **§5.4** then **§5.5**; §5.5 only with the dependency-invalidation tests.
5. **§5.6** only if a design avoids the extra frame; otherwise leave closed.
6. **§5.7**, then **§5.8**, **§5.9** each needing a stated policy or profile before work starts.

Revisit sooner if: a measured workload shows a refused shape dominating; a runtime change lands that makes a gate cheap (e.g. cursor ownership); the seed/package process changes.

## 7. Boundaries that stay fixed

- Broaden eligibility inside the one optimizer; do not add passes to applications.
- Lazy ownership is not a linear code-size check.
- Normalize only VM-internal identities; no blanket cross-VM equality (atom-key map iteration and generated references differ across VMs; the run crossed midnight once and a foreign-date fixture was fixed).
- No runtime/native/namespace deletion or seed/package replacement is implied by this record.
