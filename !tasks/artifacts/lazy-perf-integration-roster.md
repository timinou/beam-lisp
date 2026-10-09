# `perf/lazy-engine` → source-free `main`: pre-merge roster

**Status: lazy-perf selectively integrated and merged.** The pre-merge audit below was taken at `e420f8b1`; the outcome and remaining gates are recorded at the end.

## Observed state at the checkpoint

- `main` HEAD: `e420f8b1`; `perf/lazy-engine` HEAD: `5340975e`; merge base: `08a02224`. The `beam-lisp--lazy-perf` worktree is clean. `perf/lazy-w1` is included in `perf/lazy-engine`; `perf/lazy-w2` and `perf/lazy-w3` are **not**. They are separate proposals, not implicit parts of this integration.
- At the audit, `main` had **359 changed/untracked paths** and five `.ex` plus `test/test_helper.exs`. That inventory is now **zero `.ex` and zero `.exs`**. The 66-host alias-free seed has source hashes and no `BeamLisp.RT` imports; a scratch checkout without Elixir source cold-booted, evaluated code, and passed `seed --check`. The broad suite remains red and timed out after one hour; release packaging was cancelled after 25 minutes. Do not merge on the still-dirty tree, stage all paths, discard state, or touch another agent's processes.
- A read-only `git merge-tree` of the *committed* heads reports **51 overlapping entries**: **36 generated seed BEAMs** and **15 text paths** (compiler BL, obsolete `manifest.exs`, seed writer, the lazy/refs/cursor hosts, and their tests). This excludes the additional working-tree changes. The branch was based on an older substrate and still publishes `manifest.exs`; the current tree reads **data-only `manifest.term`**. An unqualified merge is not a time-saving shortcut.
- The branch's PLAN-151 records a clean-clone boot/seed check, eight Cargo tests, and performance/cycle gates on its own OTP 29 image. Those are **historical branch evidence**, not verification that the combined current tree works. It also records an OTP-version-sensitive collector calibration and a prior infinite-input laziness regression fixed in `16e7cfa2`.

## File disposition — decide before any source transfer

| Disposition | Branch content | Reason / integration rule |
| --- | --- | --- |
| **Carry as a coherent feature, after adaptation** | `priv/boot/{core,rt,compiler}.bl`; `priv/host/{lazy_memo,lazy_seq,lazy_seq_enumerable,lazy_seq_force_error,lazy_seq_inspect,seq_cursor,seq_cursor_enumerable,refs,atom,future,promise,reduced,volatile}.bl`; `native/lazy_memo/src/{lib,collector,seen}.rs` and its fixture | Chunked producers + `for`, fold recipes, versioned memo cells, O(n) native Seen, cycle collection and cell-backed references form one ABI/data-model cutover. The native functions, BL callers and test fixtures must agree. Reconcile against current pinned host APIs—not whole-file overwrite. Preserve the main-tree hard heap bound and bounded-future unlink/start handshake in `priv/host/refs.bl` while reconciling the branch's promise/volatile rewrite. |
| **Carry tests and measurements, adapting expectations** | `test/bl/{lazy_producers,lazy_fold,lazy_scaling,ref_cycles,host_lazy,host_reactive,host_refs,host_set,catch_raw}.bl`, relevant existing suite additions; `bench/{lazy_scaling,memo_cell}.bl`; `priv/std/deodorant.bl` | Preserve sparse infinite-source termination, realise-once, n→4n scaling, leak/cycle and pinned-export gates. Reconcile tests already ported from ExUnit on `main`, including the new resource-limit regression. Relative scaling evidence is preferable to absolute wall-time thresholds under this host's swap contention. The collector gate must account for OTP calibration/fallback. |
| **Do not import; regenerate locally** | `priv/bootstrap/seed/*.beam`, `priv/bootstrap/seed/manifest.exs`, branch edits to `priv/build/seed.bl` and `bin/bl-stage-hosts` | Branch floor was built for a 23-entry host table and an Elixir manifest; current `main` has 66 entries. The source-free floor uses this expanded pinned-host inventory and `manifest.term` with SHA validation before boot. Preserve current writer/stager contract; regenerate BEAMs, `manifest.term`, compiler key, app resource and release only from integrated BL/Rust sources. Never choose one side's binary during a conflict. |
| **Do not resurrect** | Branch `lib/beam_lisp/{lazy_memo,lazy_seq,reactive,refs,seq_cursor,set}.ex` deletions and `lib/beam_lisp/bootstrap.ex` edits | The first six are already gone on `main`; Bootstrap has now been deleted along with the final five `.ex` files. Transfer any still-relevant behavior to the pinned BL host, not back into `.ex`. Likewise, keep all migrated ExUnit `.exs` deleted. |
| **Keep as provenance, not an executable dependency** | PLAN-151 and FUP-112/FUP-129 notes | Historical measurements describe the old branch and machine; link them to new integrated measurements rather than replacing current PLAN-150's source-free gates. `perf/lazy-w2`/`w3` remain separate until independently reviewed. |

## Original ordered execution roster

1. **Checkpoint current migration.** The five-host cutover, helper removal, bounded-future proof and scratch cold boot/build/seed check are done. Commit only owned migration files, retain concurrent credential/other agent modifications, and document unresolved full-suite/release gates before performance changes make diagnosis ambiguous.
2. **Reconcile source layers on an integration branch.** Port the coherent perf ABI and BL producer/fold/collector changes into the *current* pinned hosts and native crate. Compare exports, result shapes, environmental ownership and error handling; preserve today's manifest-term, launcher and future heap-limit behavior. Do not use a bulk `git merge` or blanket copy of `priv/host/`.
3. **Regenerate, never merge artifacts.** Run memory-capped native build and BL build; generate the seed from the integrated source, update SHA manifest and compiler-key provenance, and verify a scratch clone cannot load stale beams. The release must contain only BL-emitted repository modules; Elixir remains an external runtime dependency.
4. **Prove correctness + benefit.** Run Cargo tests; focused lazy producer/fold/Refs/cycle/compatibility suites and sparse-infinite-input timeout gates; compare n→4n benchmark ratios with a same-host baseline; run the full BL suite, release-image inspection, `seed --check`, and a tracked-source `.ex`/`.exs` inventory returning **zero**. Record any OTP collector calibration fallback. Only then commit the integrated wave.

**Decision at the audit:** selectively reconcile the useful performance implementation; do **not** directly merge the branch into the then-dirty migration. The native/BL speedups may make later runs faster, but resolving obsolete seed formats, binary conflicts and source resurrection now is riskier and likely slower than checkpointing the source-free cutover and classifying the remaining broad-suite failures first.

## Integration outcome (after the roster)

- Source-free baseline `856d49c7`; selective integration commit `13659b7d`; merged to `main` as `801ebbbc`. The merge had **zero** overlap with concurrent credential/datom commits or unstaged edits. No `.ex`, `.exs`, branch `manifest.exs`, or branch seed BEAM was imported. The integrated 66-host `manifest.term` and BEAMs were regenerated by `bl seed` from the combined source.
- Native crate: `cargo test --offline` **9 passed**, including a forced optional-collector thread-start refusal. On this OTP 29 host the collector calibrates successfully; its live cycle gates passed. The NIF remains a strict superset of the original 17 exports. The hard future heap-limit/unlink handshake remains green.
- Focused BL gates on merged `main`: `catch_raw`, lazy producers/folds/scaling, ref cycles, LazySeq host and Refs heap **7 files passed, 0 failed**. In the integration worktree, host memo/Refs, SeqCursor, Set, prelude, deodorant, reactive and legacy LazySeq suites also passed. `catch-raw` now records a persistent **frame list** rather than an ephemeral VM token, so failures stored in native memo cells replay with the original class and reason.
- A **Git-free** scratch checkout containing zero `.ex`/`.exs` and no build image cold-booted the integrated floor, evaluated `(vec (take 5 (range 10)))` to `[0 1 2 3 4]`, and passed `bin/bl seed --check`. Its second warm `version` did not print a tier rebuild, though startup took 2m51s on this contended host.
- `bin/bl self-build` produced `/tmp/bl-lazy-drop-1592` (70.3 MB). The compound itself ran `version` and evaluated the lazy vector. The assembled app contains **zero** `.ex`/`.exs`; all **66** app ebin host BEAM hashes match the packaged seed manifest, and no `Elixir.BeamLisp.RT.beam` forwarding alias is present.
- Same-host benchmark evidence at `n=2000`: integrated map-indexed **20/36 ms** (n/2n), keep-indexed **10/40 ms**, distinct **33/56 ms**; baseline source-free run produced **13,467/56,807 ms**, **7,884/26,032 ms**, **27,075/105,426 ms** respectively, then timed out before the other cases. These are observations under changing load/swap, **not** a claimed general speedup factor. The independent native BL n→4n scaling gate passed; a full baseline benchmark did not finish.
- **Not claimed:** the monolithic repository suite. Its pre-integration 3600s run timed out midway and reported several unclassified failures. FUP-132 owns broad-suite classification and a current-`main` release-image rerun that includes unrelated concurrent commits. Historical branch PLAN-151 numbers are not substituted for those gates.

## Worktree re-audit — 2026-10-09

Reviewed `perf/lazy-engine` at `5340975e` against main `407a87d7`, then merged
`mobile` as `78bef8d3`. The lazy branch's 26 ancestry-only commits do **not**
mean its implementation is missing: `13659b7d` selectively ported the feature,
and merge `801ebbbc` is an ancestor of current main. Main subsequently repaired
the implementation in `9a48e5bd` and optimized capture walks in `0794a447`.

| Original feature | Current disposition |
| --- | --- |
| One input-bounded chunk engine, indexed producers, nested `for` flattening | Present in `priv/boot/core.bl`; the producer/scaling tests retain sparse infinite-input and chunk-boundary coverage. All original core/compiler definition names remain. |
| Fold recipes for runtime producers | Present in `priv/boot/rt.bl` and `priv/host/lazy_seq.bl`. The old `lazy-recipe` / `lazy-fold-pending` helpers were replaced by `lazy-fold-claim` / `lazy-fold-claimed`, taking ownership before effects. |
| No per-element memo allocation | Retained for trusted full count/materialization consumers. Arbitrary reducers deliberately keep shared chunks: restoring a halted recipe to pending would repeat the producer's effects on the next consumer. Current fold tests check this prefix/replay contract, concurrent readers and bounded chunk allocation. |
| Versioned memo cells and recipes stored on the cell | Present in the pinned BL hosts and native crate. Current main also has atomic retained/reserved budget admission, constant-size tag/version peeks and terminal publication refusal. |
| Native `Seen` for linear `distinct` | `native/lazy_memo/src/seen.rs` is byte-identical to the old branch. The producer still computes fallible keys before batch admission. |
| Cycle collection and cell-backed reference family | Present. The integration added optional collector thread-start fallback; main preserves bounded-future heap enforcement and the shared reference-struct source. |
| Catch class/reason/stack replay | Present with persistent frame lists rather than an ephemeral stack token. |
| Tests, bench and tail-capture lint | Producer tests are unchanged from the branch; fold/scaling coverage has been extended. The old combined host tests were adapted into current host-specific suites. The lazy scaling benchmark and `lazy/tail-capture` lint are present. |

The definition inventory found no removed BL definition names in the original
core/compiler, lazy/memo/Refs/cursor hosts or deodorant, except the two replaced
RT fold helpers above. No original native function names are absent. This
inventory is a completeness aid; the behavioral source review and regression
gates are the evidence for the retained contracts.

`perf/lazy-w2`'s older unchecked fold path is superseded by this implementation;
its zero-cell arbitrary-reducer optimization must not replace the shared-prefix
path. `perf/lazy-w3`'s benchmark is also already represented in main. These
branches are historical proposals, not additional features to merge blindly.

**Decision:** keep current main's implementation. No lazy runtime transplant,
generated seed merge, obsolete Elixir source restoration or synthetic ancestry
merge is needed. Keep the old worktree as provenance; no branch deletion or
reset was performed.

Fresh validation on the merged tree is recorded below. Runs use systemd memory
and runtime ceilings; no full-suite or device acceptance is implied.

- Native: `cargo test --offline --locked` in `native/lazy_memo`: **29 passed,
  0 failed**; 35 s service runtime, 693.5 MiB peak memory, 3.6 MiB peak swap.
- Initial BL attempt (`bl-mobile-lazy-review.service`) hit its 1800 s runtime
  ceiling during the LazySeq host tests. It first rebuilt the entire boot tier
  (approximately 20 minutes), then refreshed libraries and reached the host
  suites. Peak memory was 316 MiB and peak swap 301.7 MiB. The shutdown-time ETS
  error followed systemd's SIGTERM; this incomplete attempt is **not** a green
  test result or evidence of a LazySeq defect. Its processes were stopped by
  the service ceiling. Validation resumed serially against the prepared image
  in `bl-mobile-lazy-final.service`, capped at 1200 s / 8 GiB RAM / 2 GiB swap.
- Completed continuation: **22 files passed, 1 failed, 0 incoherent**; 14m40.718s
  service runtime, 440.9 MiB peak memory and 240.2 MiB peak swap. All producer,
  fold, LazyMemo/LazySeq host, cycle, scaling, budget, Refs/heap, SeqCursor and
  catch-raw files passed. Android events/Loom/UI, shared surface/desktop,
  environment, dependencies/compilation/lock, CLI and Hiccup checks passed.
- `aot_drift_test.bl` recorded **16 positive assertions, 3 failures**. All three
  failures belong to the existing
  `dev-a-fresh-vm-with-a-stale-beam-auto-heals-the-added-var-exists` case: the
  child exits 1 with `LOAD REFUSED` because its source would replace the
  library namespace `drift.fixture` without a declared realm shadow. That case
  is byte-identical to pre-mobile main `407a87d7`, and the same baseline failure
  is documented in mobile commit `e404814c`. Mobile's new
  `source-free-runtime-never-asks-the-planner-for-a-closure-key` case **passed**,
  as did the other in-process drift checks. No loader guard was weakened and
  this combined run is not claimed as entirely green.
- The continuation started at `78bef8d3`. Main advanced concurrently through
  the Foundry configuration commits `7da0b932` / `6c88ad14` and browser commit
  `cb485ab3`; those changes were preserved. No reviewed boot, host, native lazy,
  Android or shared-surface sources changed in that interval. This was a live
  checkout run, not certification of an immutable image containing every
  concurrent change. No device, full-suite or fresh universal speedup claim is
  made. All processes started for this review have exited.

Completed BL command (from the repository root):

```sh
systemd-run --user --collect --wait --working-directory="$PWD" \
  --property=MemoryMax=8G --property=MemorySwapMax=2G \
  --property=RuntimeMaxSec=1200 --setenv=BL_TEST_TIMES=1 \
  --setenv=BL_TEST_TIMEOUT=600 ./bin/bl test \
  test/bl/android/events_test.bl test/bl/android/loom_test.bl test/bl/android/ui_test.bl \
  test/bl/loom/surface_test.bl test/bl/loom/desktop_test.bl test/bl/env_test.bl \
  test/bl/deps_test.bl test/bl/deps_compile_test.bl test/bl/system/cli_test.bl \
  test/bl/lazy_producers_test.bl test/bl/lazy_fold_test.bl \
  test/bl/host_lazy_memo_test.bl test/bl/host_lazy_seq_test.bl \
  test/bl/ref_cycles_test.bl test/bl/lazy_scaling_test.bl test/bl/lazy_budget_test.bl \
  test/bl/host_refs_test.bl test/bl/host_refs_heap_test.bl test/bl/host_seq_cursor_test.bl \
  test/bl/catch_raw_test.bl test/bl/live/hiccup_test.bl test/bl/deps_lock_test.bl \
  test/bl/aot_drift_test.bl
```
