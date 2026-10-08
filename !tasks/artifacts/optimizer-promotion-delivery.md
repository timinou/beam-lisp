# Checked strict lexical fusion: production integration

## Delivered behavior

The ordinary compiler uses `optimize-2` in the one `BeamLisp.Optimize` pass through `lower/module->core`. Eligible closed integer callbacks carry definition-scope facts through local aliases. Immediate strict map/fold composition and the sole-direct-consumer private let shape are default behavior, without the retired `:lexical?` switch. Recognition does not authorize standalone callback-body copying: safe alias-only integer-fold candidates retain the variable callback and report `:callback-rematerialization-not-profitable`. Literal integer-fold specialization remains available.

The supported grammar/domain/order/ownership boundaries remain those of the accepted strict map/fold law. Callback grammar analysis stops at64nodes; the visitor and cumulative callback expansion allowances are distinct, seeded by `:max-nodes`. Unknown captures, helpers, globals, numeric domains, escapes, sharing and lazy demand remain baseline. Runtime normalized reduction remains explicit; hoisted variants remain isolated experiments.

Implementation checkpoint `1c4208b7`; verification snapshot `f4e26cafb47a5cb409ce7b9bd58bfc866a97934c` includes promotion and measurement updates. This is current-source-generation acceptance, not the earlier `9f76122a` frozen prototype. Source-only independent review `agent://246-AuditPromotion`: no high-confidence material promotion-delta findings; confidence0.87. Tests provide the runtime evidence.

## Verification

- Normal-source focused bundle:105tests /3680assertions /0failures /0errors. Includes default fusion, literal and alias callbacks, non-fusing alias controls, shadowing/hygiene, effects/errors, integer domains/bignums/noncommutative reducers, multiple-use/escape refusal, both budgets, open-world changes, callable/live-predicate controls, checked laws, call-shape and pinned lowering.
- Executable compiler guide: `PROMOTION-GUIDE-OK optimize-2`, applied strict fusion,11charged callback nodes. The executable blocks are extracted from `docs/compiler/optimizer.bl.md`; the first API signature fragment is introductory, not standalone code.
- Official keyed build:317sources compiled, `:errors []`, native errors[], no copied absolute-path ownership state. This is build acceptance, not repository-wide test acceptance.
- Official isolated seed:97modules /67pinned hosts /12boot namespaces, errors[], oktrue. Compiler key `1ff4dc409b5ecb2beeed848ec8c1a87fae2e869446e9c7ed5f92d6c1b2135c61`; build key `b2105f6e2bf74a05463c476c9f476036ac80d9c06661c21aa1bda8b0d225fc74`.
- Strict fresh VM installs that candidate with ZERO previous-generation staging exemptions, reports `optimize-2`, arithmetic3, strict-fold992 and the compiler key, then repeats105tests/3680assertions with0failures/0errors.
- Offline law tests use an explicitly pinned Z3 asset (4.16.0) from release44983364; the production optimizer does not start a solver.

The initial test command used three incorrect test paths and produced an empty log; it is not acceptance evidence. Verified paths are `test/bl/system/optimizer_laws_test.bl`, `test/bl/system/optimizer_call_shape_test.bl` and `test/bl/pinned_kernel_lowering_test.bl`. The final bundle and strict cold run above use those exact files.

## Measurements and code growth

The existing normal-source harness now compares disabled vs production, not the historical experimental flag.150checked timing samples:5cases ×3sizes(1000/16000/64000) ×2modes ×5alternating-order repeats. Input construction is included. New cases exercise a noncommutative reducer and reuse one callback in two immediate fusions. Timings are contended-host observations; VM reductions are execution-work counters, not allocation/total-memory proof.

At16000, disabled→production median reductions:

| Case | VM reductions | BEAM bytes |
|---|---:|---:|
| Callback alias only |53070→53025|1040→1040|
| Private mapped list |118671→53023|1300→920|
| Callback aliases + private list |118669→53027|1308→1380|
| Aliased noncommutative private map |118669→53027|1292→1364|
| One callback, two immediate fusions |237764→111263|1392→1528|

All admitted fusion images omit `lists:map/2`. Alias-only has no `integer-callback` rewrite, no charged expansion and no BEAM growth. Fusion can retain original closures and slightly grow output; that bounded tradeoff accompanies removal of measured traversal work, not an unconditional code-size claim. Unused callback cleanup and alias-only specialization remain deferred until their independent profitability/safety gates pass.

## Reproduction and durable deferrals

Use `optimizer-stage.sh` with isolated `BL_EBIN` for hosts/optimizer/test/eval/build/seed. Stage legitimate previous-floor exemptions only during bootstrap. Do not copy `compile.beam_lisp` or `build.log` ownership from another absolute source tree. Use `optimizer-cold.sh` with `BEAM_LISP_STRICT_SEED=1`, `BL_CANDIDATE_SEED`, a fresh `BL_COLD_EBIN` and the focused comma-separated `BL_COLD_TESTS` paths. Resource cap:MemoryMax6G/MemorySwapMax1G and `ELIXIR_ERL_OPTIONS='+S 8:8 +SDio 8'`.

Current compiler guide: `docs/compiler/optimizer.bl.md`. Standalone reasoning, counterexamples, missing dependencies and concrete revisit/promotion gates for every deferred domain: `research/optimizer-integration/README.md`. Historical negative/positive prototype evidence remains `optimizer-prototypes-delivery.md`, `optimizer-prototypes-results.json` and the immutable `performance-evidence/optimizer-prototypes` checkpoint; historical measurements are not relabelled as this generation.

## Follow-on branch integration

User additionally requested merging `ns-defs-beam` after this promotion. Its source changes introduce BEAM-backed namespace definition tables and new Env/AOT/Link runtime seams. Its old96-beam seed is NOT combined-generation authority. Merge must preserve current optimizer and Env fixes, retain a complete compatible floor during bootstrap, and obtain new official build/seed/strict-cold acceptance for the combined source. That gate is separate; no combined acceptance, package publication or whole-suite-green claim is made by the pre-merge results above.
