# Optimizer integration prototypes

## Scope and status

This work implements the three integration experiments in `optimizer-coverage-roadmap.md`: ordinary-source lexical recognition, observable traversal semantics, and open-world binding/body changes. It does not implement general lazy fusion, public arithmetic specialization, transducer fusion or formula elimination. No namespace files were deleted.

The optimizer implementation remains exclusively in `priv/host/optimize.bl` (`BeamLisp.Optimize`), with the existing thin facade and common lowerer entry. New recognition is explicitly experimental: `{:lexical? true}` enables it; the default remains false. This option permits internally checked matching, not externally asserted proof facts.

Runtime normalization is an explicit fifth argument to the existing `rt/k-reduce`: `:baseline` or `:normalized`. Ordinary three/four-argument calls remain baseline. This is a control experiment, not a second reducer. The actual guard-hoisting variants are generated into isolated RT images from the one canonical source by `optimizer-mode-stage.bl`; they do not change the published walker.

## Lexical/private-list recognition

The central pass records eligible closed integer callback definitions in lexical facts and propagates their identity through local aliases. It never resolves an alias against a later binding of the same name. Callbacks must remain single-clause, unguarded, distinct plain parameters, and total within the supported integer `+`, `-`, `*`, literal, variable and local-let grammar. Captured scalars, unknown helpers, globals, wildcard parameters, effects, division and unsupported domains remain conservative refusals.

An immediate shape is additionally recognized:

```clojure
(let [mapper (fn [x] (* x 2))
      reducer (fn [x a] (+ a x))
      mapped (lists/map mapper (lists/seq 0 64))]
  (lists/foldl reducer 0 mapped))
```

The let body must be the sole direct fold consumer. The reducer cannot be the mapped binding; the initial accumulator must be a closed integer expression that cannot depend on the intermediate or introduce errors/effects. The source and callbacks must meet the existing strict-map/fold proof. This is a narrow structural private-use proof, not arbitrary alias/escape analysis or lazy ownership.

Review found an important boundedness issue in the first implementation: repeated uses could repeatedly materialize one callback body. The corrected prototype bounds callback grammar analysis to64 expression nodes and gives every descriptor one cumulative inlining allowance, initialized to `:max-nodes`. Accepted rewrites deduct callback expansion cost; exhaustion reports `:callback-inline-budget` and retains the current node. `:stats :inlined-nodes` exposes that cost. The existing visitor budget remains separate; neither budget claims constant-time whole-descriptor validation or downstream compilation.

Independent boundedness re-review: `agent://242-ReviewCallbackBounds`, correction accepted, confidence0.95. Earlier audit and runtime ingress review: `agent://241-AuditLexicalPrototype` and its RuntimeAudit child.

## What the measurements demonstrate

The normal-source lexical harness compiles disabled, current and lexical variants through the ordinary descriptor/lowerer API.135 timing samples cover three cases, three sizes1000/16000/64000, three variants, five alternating-order repeats. Every answer is checked. Input construction is included.

At16000, current versus lexical median microseconds / VM reductions:

| Case | Current | Lexical prototype |
|---|---:|---:|
| Callback alias only |327 /55255|276 /55708|
| Private mapped list |931 /118615|269 /55550|
| Callback aliases + private list |989 /118615|172 /53189|

Fusion removes the `lists:map/2` instruction in both private-list cases. The alias-only case does not demonstrate reduced VM work. No allocation or total-memory claim is made.

Generated BEAM sizes: private-list1164→920bytes; alias-plus-private-list1308→1380bytes; alias-only1040→1140bytes. Rematerialized callbacks can retain original unused closure definitions, so this prototype is not unconditional code-size improvement. Compile/proof times are single setup observations, not calibrated comparisons; the first disabled proof call includes cold facade loading. Keep the gate off pending broader source matching and code-growth decisions.

## Traversal experiments

`reduce-callback` returns an actual native arity2 function unchanged, or a raw arity2 wrapper that delegates to the original call-shape dispatcher. Construction invokes no user callback, preserving invalid-callable behavior on empty input. The compatibility envelope prepares the underlying user callback as well; live `core/reduced?` reads after each callback and at exhaustion are not cached.

Three emitted-step variants were examined:

1. **Control:** existing step guard remains; wrapping is not guard hoisting.
2. **Helper hoist:** entry preparation plus `erlang/apply f (reduce-two acc x)`. Bytecode removes the guard but adds a `reduce-two` call and generic `erlang:apply/2`; it is not an improvement merely because the guard disappeared.
3. **Packed hoist:** entry preparation plus native application to the literal packed argument list. Bytecode has `call_fun/2` with neither an explicit arity guard nor list allocation in `step/3`.

The stage generator checks exact source anchors and the two literal arity2 recipe consumers before writing. Drift fails closed. It records canonical/generated SHA256 and refuses staging directories under the source tree. Callback preparation covers k-fold, compat's underlying callback and direct cursor entry. The recipe count/materialization consumers remain literal arity2 functions.

Initial runtime measurements contain4800 checked rows: four images ×20 callable/collection/policy cases ×three sizes ×five ABBA repeats ×four ordered samples. Lists, vectors, lazy sources and maps are represented; native, an immutable tagged adder, and the actual public `+` value are distinct cases. Strict input construction occurs before the measured window; lazy realization remains inside it. Different images run in separate VMs, so wall-time ratios across images are not controlled speedup claims.

At16000/list/kernel, VM-reduction medians from the initial run:

- Previous native160161; control baseline161169; packed hoist160459: no demonstrated native-work reduction.
- Tagged adder: control baseline306311; normalized705587.5; packed hoist706432.
- Public `+`: control baseline1009952.5; normalized1410459; packed hoist1409513.

Bytecode/source examination exposed avoidable argument-helper scaffolding in the generic wrapper. The wrapper now uses the same packed-list construction as the original step rather than `reduce-two`. Initial numbers remain retained as negative controls, not final results for that correction. The corrected wrapper passed the strict103test/3141assertion gate and the packed image's80test/2904assertion gate. A further2400 checked timing rows measure both corrected images. At16000/list/kernel, control baseline versus normalized reductions: native160080→161303; tagged adder305217→323002; public `+`1008768.5→1025296.5. The packed image has roughly160565 native,323372.5 tagged-adder and1025805.5 public-plus reductions. Removing the avoidable helper eliminates most of the earlier regression, but the generic wrapper still adds approximately one reduction per element and native work is essentially unchanged. Therefore neither normalization nor hoisting is promoted; ordinary calls remain baseline. Timings across images are contended/separate-VM observations, not controlled speedup claims.

## Observable and open-world gates

Canonical lexical/control gate:103 tests /3141 assertions /0 failures /0 errors. Independent helper-hoist and packed-hoist gates each passed80 tests /2904 assertions. These overlap; they are not a unique repository total.

The recorded2128 canonical outcomes match the helper-hoisted outcomes after normalizing only cross-VM reference IDs and generated Eval function identities, preserving reference occurrence identity and function index/arity/entry. Within each VM, comparisons use unnormalized outcomes. A packed-image within-VM mode comparison is not by itself an independent hoist proof because its two mode arguments use the same path. Final cross-image corpora exposed environmental input differences: the run crossed midnight, and maps with atom keys iterate differently across separately initialized VMs. The foreign-date fixture is now fixed. We do not normalize changed semantic values or claim blanket final cross-VM equality. An additional SAME-VM step oracle compares the original checked-native/generic-dispatch operation with the prepared callback on the same callable and arguments, including raw error observations and effect traces. It contributes512 assertions; each image passes12mode tests/2897assertions. Together with the independently audited unchanged storage walks and ingress proof, this checks the transformation without assuming unordered collections have a cross-VM traversal guarantee.

Adversaries cover native/tagged/variadic/keyword/map/set/opaque/wrong-arity callables; empty/init/no-init inherited behavior; supported collection representations; improper tails; callback ordering; initial/nested Reduced; chunk boundaries, early halt and replay; live predicate rebinding before/mid/terminal; exact exception observations; cursor and both trusted recipe ingress paths.

Normal-source open-world tests reuse an already compiled caller while replacing a helper body with the same module/name/arity, change global callback values before and during traversal, and verify unknown helpers are not fused. They also verify unavailable-service/author-proof options do not authorize unknown facts. The optimizer has no solver invocation. In the frozen checkout the solver binary was initially absent:101non-solver tests passed while the two OFFLINE SMT tests correctly failed to start their service (its unrelated missing-solver message also has a pre-existing protocol error). An explicit retained solver pin from release44983364, reporting Z3 version4.16.0, regated those two tests/4assertions successfully. No production optimizer dependency on that pin was added.

## Deployment and publication

Only staged images are accepted at this point. The published seed has not been replaced and no new self-extracting package is delivered.

The first full candidate build reported310 compiled sources but copied state still named the previous image's absolute source paths. The builder's authoritative post-build removal pass then removed the newly built modules owned by those old paths. Source and binary-state inspection proved the path ownership collision. Copied state must be excluded, not published or fabricated.

A clean-state generation later timed out at compiler compilation. Concurrent work advanced `main` during this experiment. The deployment check therefore freezes baseline commit9f76122a, overlays only the two owned prototype implementation files and fixtures, and uses a separate clean-state image. The compiler-only diagnostic progressed through ANF validation, native compilation and closure hashing and completed; no deadlock was inferred from a timeout. The official seed writer identified six remaining stale boot namespaces; those were re-emitted through the existing compiler (Multi is `priv/std/multi.bl`), without fabricating metadata. Final authority:97modules /67hosts /12boot namespaces, compiler key `0ac0d05ce88b7e129966b33a211e388ad163015360dde157a9557655d89b584e`, build key `d5276a7ed2394c5f08d8c712b7de1f9feb42c032dc9c61967c53753363a6a4ab`, errors[], ok true. A fresh strict installation has ZERO prior-generation staging exemptions and prints optimize-1, arithmetic3, strict fold992 and that compiler key. The strict focused suite passes103tests/3141assertions. This frozen-baseline candidate must not overwrite newer concurrent repository generations; it remains an isolated accepted prototype floor, not a claim that all ordinary library sources or the current concurrent main were rebuilt.

## Reproduction and evidence

- `test/bl/optimizer_lexical_prototype_test.bl`: recognition, refusals, order, shadowing, hygiene and bounds.
- `test/bl/optimizer_mode_prototype_test.bl`: callables/representations/live predicates and optional machine-readable outcomes (`BL_MODE_SNAPSHOTS=1`).
- `test/bl/optimizer_open_world_prototype_test.bl`: body/binding changes and unknown-authority controls.
- `optimizer-lexical-measure.bl`: ordinary-source compile/code/timing evidence.
- `optimizer-mode-measure.bl`: per-call controls and previous-floor four-arity compatibility (`BL_MODE_IMAGE=previous-floor`).
- `optimizer-mode-stage.bl`: isolated whole-RT variants; `BL_MODE_PACKED=1` selects packed application.
- `optimizer-mode-audit.bl`: step disassembly and checked cursor/count/materialization ingress.
- `optimizer-prototypes-results.json`: retained computed results; raw logs are immutable/hash-indexed through the existing evidence archiver.

Use the existing `optimizer-stage.sh` phases against an isolated ebin. Do not copy foreign `compile.beam_lisp`/`build.log` ownership state into a new image. Do not substitute old-package evidence for this generation's acceptance. The full repository suite, arbitrary lazy/resource fusion, and total-memory behavior are not claimed verified.

## Production cut pointer (appended; the sections above are unchanged historical evidence)

Status: the useful subset of this prototype is being promoted into the default optimizer (PLAN-160): default bounded callback facts and private strict `lists:map`/`lists:foldl` fusion including aliases, the `{:lexical? true}` option retired, standalone alias rematerialization refused, runtime normalization and hoisting not promoted. Implementation is in progress and **verification on the current generation is pending**. The frozen-baseline floor (`9f76122a` plus overlay) described above does not become acceptance for current `main`, and no seed or package is claimed. Deferred work, evidence and revisit conditions: `research/optimizer-integration/README.md`; current design: `docs/compiler/optimizer.bl.md`.
