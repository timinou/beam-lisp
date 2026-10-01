# Clustered performance repair results

## Accepted implementation

The demand-loading foundation and safe continuation repairs are implemented in the self-hosted BL sources, tests and native memo crate. The current published generation is:

- Compiler: `abfbd9ca9d1fafaa718bf4bac31d98c308d08ae396598e95b74279b19911eccb`.
- Build: `d900aee1f980ab59d9b6966d98e7f242b1651909e565b54da5dbbfb8e2326659`.
- Complete tier inventory: 309 sources, including literate sources.
- Official floor: 93 modules, 66 pinned hosts, 95 seed-directory files.
- Repository-authored Elixir inventory: zero `.ex`, zero `.exs`.

| Cluster | Accepted behavior |
|---|---|
| A | Transparent deferred alias/explicit-ref initialization; eager bare/refer-all edges; captured resolution roots; interface-aware incremental keys; conservative macro invalidation; scoped repair ownership; complete inventory and coherent publication; cold direct-shim bootstrap. |
| B | Admitted creation/publication reserves growth against one authoritative atomic occupied counter. Concurrent publishers cannot spend the same quota. Fold attempts claim before effects; terminal post-production refusal does not replay them. |
| C | Linear own-module-identity lowering and immutable plain-function dispatch specialization. Reloadable calls, bindings, capabilities and malformed-descriptor validation remain observable. |
| D | Constant-size tag/version peek, version-validated full read, retained/reserved diagnostics and existing dirty routing. Public full-state APIs remain. |
| E | One indexed cursor root per finite walk; immutable positions; structural reference-occurrence census with closure fallback and fail-open uncertainty. |
| F | All-clause/guard analysis and consumers; parameter-position-aware incremental hashes; exact SMT arity selection, resolved-call parity, checked actuals and recursion refusal; exact primitive effect signatures; local helper/foreign-callback loop context; generator-domain shrinking and preserved public shrink compatibility. |

General reducers use replay-safe memo chunks, not an unsafe zero-cell fold that can replay a halted prefix. Whole-answer storage remains proportional to the saved result. The graph-lock safety boundary remains intact.

## Verification

Observed final gates:

- Rust native tests: 29 passed after owned-file formatting; release build succeeded.
- Fresh analysis/callable/loop/shrink compatibility: 125 tests, 312 assertions, zero failures/errors.
- Fresh memo/cursor/collector/replay: 107 tests, 1103 assertions, zero failures/errors.
- Real published bootstrap/cache/generation/loading/emitter ABI: all 19 files passed; zero failed or incoherent files.
- Updated original runnable compiler, interface-key, shared-lazy and lazy-force lessons: successful fresh command runs, including the lazy-force assertion after its final edit.

The bundles overlap. They are not summed into a unique test count. A staged floor mismatch and an OS repair-flag-dependent fixture were classified and corrected; the final real published gate is the acceptance result, not the earlier staged failure.

## Final package

`/tmp/bl-performance-final-drop-158e8a77` rebuilds all 309 tier sources. The compound contains 147352288 bytes; its payload is 146187992 bytes with SHA-256 `44983364407d2b49457e5328894ab4e1a31d55c05465d6fea6177d230f853a82`.

The audit compared all 95 floor files with the checkout: zero mismatches. The packaged lazy memo NIF matches the current installed bytes, SHA-256 `b9e1e0420a7920fcb758e7e0b08eb2129c950fc708ce6b6a1f9faf2d1c7a844d`. The `priv` payload has 375 Lisp sources (309 tier plus 66 host sources), no Elixir sources. Outside the repository cwd, version, eval `(+ 1 2)` → `3`, lazy count → `65`, and strict version all exit successfully.

## Post-fix benchmarks

No new pre-fix benchmark was run. Full samples, CPU/RSS caveats and native counters are in `performance-final-measurements.json`. Immutable raw logs and hashes are in `performance-evidence/final-continuation/index.json`; the earlier post-fix checkpoint is retained separately.

| Fresh CLI command | Wall seconds |
|---|---|
| version, three samples | 9.454097 / 7.465494 / 8.072850 |
| version median | 8.072850 |
| --version | 7.065186 |
| eval → 3 | 8.471739 |
| strict version | 8.720416 |
| seed check | 9.866507 |

Incremental fixture, microseconds: initial 3 builds / 66274; unchanged 0 / 5091; provider body edit 1 / 27941; provider interface edit 2 / 50629; subsequent unchanged 0 / 4993. All error lists are empty.

| Size | Lazy samples, ms | Finite-input samples, ms |
|---|---|---|
| 1000 | 5.351 / 6.472 / 7.372 | 4.157 / 5.346 / 7.222 |
| 4000 | 29.339 / 28.947 / 26.776 | 21.089 / 22.409 / 20.329 |
| 16000 | 69.951 / 82.348 / 79.977 | 56.689 / 65.156 / 67.963 |

Answers are 999000, 15996000 and 255984000 respectively. Raw Erlang samples are diagnostic lower bounds, not equivalent lazy sharing semantics. A held 16k memo reports 256024 memo bytes; first count 31248µs, second 3694µs. Native retained bytes stay 634928 across the second count, with 522 live cells and zero reserved bytes. Collector diagnostics record one fail-open abort and zero anomalies.

The host is contended; historical measurements use different runtime conditions. No universal or single-change causal speedup is claimed. Structural gates—build counts, skipped classifier calls, constant-size peek and one cursor root—are the portable evidence.

## Instructional originals

Updated in place after runtime acceptance: `docs/self-hosting.md`, `docs/self/the-language-compiles-itself.bl.md`, `docs/build/interface-keys.bl.md`, `docs/runtime/lazy-realization.bl.org`, `docs/memory-policy/shared-lazy-values.bl.md`, `docs/veritas-for-agents.md`, `research/rt-selfhost/NATIVE-PLAN.md`, and the original performance review/startup/lazy notes. The guides explain current contracts from zero context; historical observations in review artifacts remain labelled historical.

## Explicit boundaries

The repository-wide suite remains outside this focused acceptance; historical broad failures/timeouts are not silently attributed to these repairs. FUP-132 remains open for full-suite classification even though the current release proof is now available.

Cross-source/dynamic loop contexts, full host/NIF type/effect precision, universal cost inference, epoch-cached namespace dispatch and recursive scaffold lifting are not supplied by these repairs. Unknown evidence remains unknown. General Core-call erasure, redundant tuple lowering, unsafe beta/scaffold rewrites, destructive cursors and graph-lock reduction without atomic cycle proof are rejected rather than hidden behind fallbacks. Native byte accounting estimates saved terms, not total process RSS or all external storage.
