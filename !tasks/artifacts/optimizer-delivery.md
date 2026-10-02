# Automatic optimizer delivery

## One home and one compiler entry

The implementation is `priv/host/optimize.bl`, pinned as `BeamLisp.Optimize`. `priv/boot/optimize.bl` is a thin ergonomic namespace facade. Facts, checked conditions, rewrite rules, hygiene, traversal budgets and evidence/refusal reporting live in the pinned implementation; the old emitter rewrite implementation has been removed.

`lower/module->core` calls `BeamLisp.Optimize/module`, so host emission, namespace AOT, live definitions and interactive evaluation share the pass. The public namespace API is `optimize/module`, `optimize/node`, `optimize/run`, `optimize/explain`, `optimize/rules` and `optimize/version`. The compiler-facing module API avoids report storage; explain uses the same implementation with reports enabled. Input/output descriptors are validated. Author annotations do not authorize rewrites.

Pinned placement is necessary for self-hosting: a namespace optimizer cannot require itself to be initialized while it compiles its own initializer. Its exact host is generated from Beam Lisp and recorded in the authoritative seed inventory and codegen-source digest. No repository-authored Elixir/Erlang implementation was added.

## Shipped rules

1. Literal own-module identity, consolidated from the emitter.
2. Proven fixed native arity, from actual closure representation, lexical aliases or a dominating native function guard, lowers RT.invoke to native application. Complex arguments are explicitly sequenced in the existing packed-cons backend's observed tail-before-head order; their positional order is unchanged. Atomic operands need no extra bindings.
3. Established integer/float/number domains remove unnecessary numeric-tower dispatch.
4. Literal closed total integer fold callbacks are specialized under an integer accumulator/list invariant, without callback-body cloning.
5. Immediate strict `lists/map` plus sequential `lists/foldl` fusion for closed total integer callbacks, known integer input and initial accumulator. Fresh bindings prevent capture and evaluate the mapper once per element.

Shared call-site reading in system.ir keeps summaries/flow/effect analyses consistent across invoke, apply and remote forms. Unknown apply effects remain opaque. There is no competing optimizer in those analysis modules.

This is not blanket fusion of public Core/lazy pipelines. Live providers, unknown/captured callback dependencies, effects, partial arithmetic, unsupported domains and observable lazy sharing/demand remain baseline with explanatory refusals. No global var is frozen. No mandatory solver runs at compilation/startup: structural/domain checks instantiate owned laws, while independent SMT tests check the map/fold induction step and reject argument reversal. These tests do not claim a proof of every BEAM/resource behavior.

## Public reducer cutover

Core uses the existing RT representation walk. Its additive `:compat` boundary preserves unsupported improper-tail errors after the prefix, foreign-struct behavior and the LIVE core/reduced? lookup after each callback and at exhaustion. Internal accumulator envelopes distinguish user Reduced data from an internal halt, avoiding double peeling and preserving midfold predicate rebinding. Root LazySeq keeps its original intrinsic path before empty?, avoiding an extra head read. The default three-argument kernel retains its prior contract.

The live-predicate adapter introduces tuple/callback work. Its whole-public-reducer performance is not claimed to match the experimental immutable-adder kernel. Keeping observable semantics is the priority over silently eliminating those reads.

## Verification

- Final focused staging gate: **76 tests / 418 assertions, 0 failures, 0 errors**, including inherited pinned emission regressions and actual effect-order comparisons. Authoritative recorded completion: bg_1596974e0d1b3531. The normal published CLI separately passed the API and inherited emitter/provenance gates.
- Final full native source build: **310 sources built, 0 errors**. Log `/tmp/bl-optimizer-final-build-158e8a77.log`; build state has the current source hashes and compiler identity.
- Official normalized candidate: **97 modules / 67 hosts / 99 seed files**, compiler key `2ea0cf667d6810b16000409b6f92c4ad9d24ef14e03add60c6becd1e4719c0c2`, build key `97377a8e3e31325c2fb16ce14a2f293a6ad1436f133119d3213bfa4ca226a3c6`.
- Strict fresh candidate install has no previous-generation staging authority. Cold outputs: optimizer version optimize-1, arithmetic3, fused strict pipeline992, matching current compiler key.
- Atomic publication retained the prior floor/build entries in `.local/foundation-publication-1790957693548117891`; local build state was not overwritten.
- Normal CLI smoke: `["optimize-1" 3 6 992]`. Runnable API guide `docs/compiler/optimizer.bl.md` completed normally.
- Independent fresh-VM acceptance: reproducible emission7 checks; callable kernel40; lazy fold316; reference interpreter45; namespace demand52; seed727. Each file passed with0failed/0incoherent. These are per-file results, not a sum of unique repository coverage. Generous `BL_TEST_TIMEOUT=600` was necessary for the seed corruption/rebuild corpus.
- Mixed release-test bundles are not an acceptance claim: the seed corpus intentionally mutates/reloads foundational modules and can invalidate test-report helpers for later files in the same VM. Run those release mutators separately. The corrupt-header log line is an intentional seed adversary, not a corrupt published floor.
- No tracked `.ex` or `.exs` source files; shell syntax and whitespace checks performed.

## Broader-suite classification

A broad17-file staging bundle initially reported23failures/1error. The real introduced native-call argument-order mismatch was corrected and independently regated. Emit byte equality required publishing the new floor. A read-only independent old-seed audit reproduced pre-existing opaque-map/reference diagnostics, map order, cross-process volatile visibility and frozen namespace-corpus drift. See `agent://235-ClassifyBaselineFailures` and `artifact://158e8a77c44cf6fc/main/bash/1486.txt`. No repository-wide green claim is made.

Some release inventory fixtures predated the six preboot host rows; the explicit mapping fixtures now include those rows and the new optimizer host. Tests were retained, not removed.

## Automatic source measurements

`optimizer-measure.bl` compiles ordinary source through the normal descriptor API, baseline enabled=false versus optimized enabled=true. It checks90 interleaved timing samples:5repeats,3sizes (1000/16000/64000),3cases,2modes. Input construction is included for the list cases. Results are retained in `optimizer-measure-results.json`; raw output remains `artifact://158e8a77c44cf6fc/main/bash/1487.txt`.

At16000 elements, median microseconds / VM reductions:

| Case | Baseline | Optimized |
|---|---:|---:|
| Guarded native callback loop |1263 /144380|1054 /80279|
| Integer fold |536 /54229|582 /55530|
| Strict map/fold |2036 /119585|619 /53226|

The integer-only specialization did not demonstrate lower total VM work here: the backend already handles this simple fold efficiently, and construction/GC dominate the counter. Fusion and direct calls show stronger work-count reductions. Timings are contended-host observations, not guaranteed speedup ratios. This run has no separate allocation profiles. Measurements predate the final argument-order hardening, but these candidates have atomic native-call operands and unchanged arithmetic/fusion lowerings; final effectful-input semantics were gated separately.

## Reproduction

Use the normal CLI after publication:

```sh
ELIXIR_ERL_OPTIONS='+S 8:8 +SDio 8' bin/bl test \
  test/bl/optimize_test.bl test/bl/reduce_kernel_cutover_test.bl \
  test/bl/system/optimizer_call_shape_test.bl test/bl/system/optimizer_laws_test.bl \
  test/bl/pinned_kernel_lowering_test.bl

BL_TEST_TIMEOUT=600 ELIXIR_ERL_OPTIONS='+S 8:8 +SDio 8' bin/bl test test/bl/seed_test.bl
bin/bl run docs/compiler/optimizer.bl.md
bin/bl run '!tasks/artifacts/optimizer-measure.bl'
```

Staging helpers `optimizer-stage.{bl,sh}` and `optimizer-cold.sh` retain the verified-floor cutover procedure. Normalize project app declarations through `app-resource/of-project` before passing them to the seed writer; use a fresh cold layout because the bootstrap installer intentionally preserves existing application resources.
