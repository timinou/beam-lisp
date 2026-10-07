> Latest authorized refresh: main `0f518fdf` is being merged onto this preparation branch; source clean, floor regenerated from combined source, 21-file compatibility gate / 8,553 assertions pass. Historical snapshot receipts below remain scoped to their own commits. See [main refresh and red repair plan](structural-main-refresh.md).

# Corrected structural merge preparation

## Scope and provenance

Preparation branch: `perf/structural-merge-ready`, worktree `/home/user/.cache/bl-structural-merge-ready`. Source combines main `b5e63edbc9b8ccaded5ee6a6c93a5edc99748a73` and integration `d7dc2bf3a2dc73279ae7a4a1bb3df6252f803e58`. Main's 26 intervening commits, including the sole compiled JavaScript core, are retained. Main is not merged or deployed by this preparation. Its unrelated document/xberg working changes are preserved.

The earlier integration report and JSON describe the old-base delivery and its measured fixture; they are not approval of the corrected combined tree. This report records the later soundness, concurrency, and verification gates. All selected gates are verified below. The broader baseline remains failed and incomplete; no green-full-suite or main-merge claim is made.

## Executable predicate authority — BUG-116

`priv/host/optimize.bl` derives arithmetic comparison eligibility from the **executable BIF and its canonical numeric-tower pair**. A comparison label alone does not prove totality. `:arith` descriptors with `:fun :gt` and `:bif :div`, `:rem`, or `:element` retain reference execution. Noncanonical pairs in the opposite direction are conservatively refused too. The public ANF descriptor validator remains usable; this correction is in the existing optimizer, not a second validator/optimizer or author annotation protocol.

Permanent tests in `test/bl/optimizer_first_filter_test.bl` use distinct loaded module atoms for default and reference images. They cover direct intrinsic and captured-global invocation, later errors in the reference filter's forced chunk, returning controls, unknown/partial BIFs, canonical comparisons, and metadata that cannot grant authority. Ordinary source continues to admit the supported private first/filter consumer, with live callable guard and captured fallback.

Old-image negative control: `artifact://1598ead9f02e4261/main/bash/544.txt`, default/reference parity differs (`[:ok 1]` versus `[:error :badarith]`), 16 optimizer assertions fail. Corrected image: 174 optimizer assertions pass in `artifact://1598ead9f02e4261/main/bash/555.txt`.

## Serialized real code retirement — BUG-117

`priv/std/vm/core.bl` uses the existing retirement inventory key `(tuple :vm_retired_modules key)` as the `:global` lock resource, with the calling PID as requester. The entire inventory read, loaded-module scan, soft retirement, retained publication/erase and body counter reset is one per-key transaction. An aborted lock acquisition runs no transaction; a later drain retries. No hard purge, extra cache registry, public test hook, or developer-managed invalidation protocol is added.

Inventory prefixes cover actual source-emitted namespace shims, `Ns.Fn.R<key>.M<n>` bodies, and servers. Speculative `Ns.Body.R`/`Ns.Init.R` prefixes and the synthetic companion test are removed. Actual realm AOT-loader/companion naming remains FUP-155, not a shipped capability.

The permanent concurrency test holds the same resource in a separate process and observes both drain callers entering `global:trans/2` through an isolated OTP trace session. It does not infer blocking from a quiet timing window. While the resource is held, real current code and inventory remain unchanged. After release, both drains complete; the unowned busy caller survives, its old-only identity remains inventoried, allocation while that known lease is active does not reuse its atom, and a later drain after release purges it and permits numbered-name reuse. Workers, locker and trace session are cleaned up.

Old-image negative control: the drain returns `[:early :one {:purged 1 :halted 0}]` before the lock-entry proof; one lifetime assertion fails in artifact544. Corrected image: 32 lifetime assertions pass in artifact555.

This fixes concurrent drains. It does not promote uncontrolled same-key allocation/reopening while teardown is in flight, promise post-close callable validity, or add background reclamation. Reclamation of retained busy code is retried by a later same-key drain. The trace API is documented by [OTP trace sessions](https://www.erlang.org/doc/apps/kernel/trace.html).

## Kernel regression fixture correction — BUG-118

Current main included valid keyword `:k` among invalid callbacks and folded it over an **infinite** lazy range. Two-arity keyword invocation is lookup with a default; it can keep returning the current element and never raise or halt. A bounded probe confirms `(:k 0 1) = 1`, and both baseline/normalized folds of `(1 2 3)` return `3` (`artifact://1598ead9f02e4261/main/bash/562.txt`).

The invalid fixture now contains only genuinely invalid binary callbacks. Finite keyword parity assertions and the existing finite callback-shape matrix preserve coverage; runtime behavior and error contracts are unchanged. The corrected kernel file passes **451 assertions** in `artifact://1598ead9f02e4261/main/bash/563.txt`.

## Coherent bootstrap

The source three-way merge was clean; conflicts were confined to generated bootstrap artifacts. Main's manifest was used only as bootstrap input. The existing authoritative producer regenerated **97 beams** from the corrected combined source, rather than selecting either side as final artifacts. Generation receipt: `/tmp/bl-structural-merge-seed.log`, codegen prefix `12939c1df4bd`, driver prefix `e1d52754be52`. The checked floor is current across **79 namespaces**; action-only data-readers emits no stamped shim (artifact552).

Compatible ignored native artifacts were provisioned from the built checkout after the inspected native source/host ABI paths showed no delta. Generated NIFs are not committed. The first outer tool wrapper expired after 300 seconds; its service later exited unsuccessfully with incomplete diagnostics. A durable-logged rerun completed successfully in 544.938 seconds, peak 246.4M plus 141.2M swap. This is build context, not an application speed claim.

## Verified focused work and cost

Across the explicit per-file receipts, **21 focused/current-main runtime files have 2,799 passing assertions**: artifact555's 20 passing files (2,348 assertions) plus artifact563's corrected kernel file (451). Those original mixed batches also contained incoherent workers; this union is not called a green full suite.

Final distinct-image fixture in artifact576, 200 calls, reference/default result `4`: **1,105,369 → 90,721 reductions**, or **12.18× less runtime work / 91.79% saved**. BEAM size **976 → 1,208 bytes (+23.77%)**; caller compilation **47,225 → 72,885 reductions (+54.34%)**, excluding compiler-worker/native work. Admission visits 18 nodes and reserves 64 emission nodes. Current main has a different runtime baseline than the original 13.38× receipt; no app/browser or JavaScript speedup is inferred.

The ordinary similarity query still reads zero embedding rows after an unrelated write and returns two hits. This reuse existed in base. Snapshot/restricted-view validity is hardened; no generalized query/policy or live skipping certificate is claimed.

Optimizer docs: **three executable cells, zero errors, checked unchanged** (artifact566).

## Initial timeout classification

The first combined batch hit its 20-minute service cap while compiling the exhaustive 357-case JS corpus. SIGTERM caused the later ETS teardown error; that output is not a product correctness diagnosis. The kernel worker's separate incoherence was diagnosed and corrected as BUG-118.

Three smaller JS files then hit the default 300-second per-file ward deadline. The same `js_diff_test.bl` deadline is reproduced on **unchanged main b5e63edb** in a separate baseline worktree (artifact566). That proves the default deadline issue is not unique to this preparation; it does not prove those JS semantics pass. The existing supported `BL_TEST_TIMEOUT` setting is used for a fresh serial run with 1,200 seconds per file, 8G RAM/2G swap cap, and 5,400-second service ceiling. The longer run passes JS differential **367 assertions**, cold CLI **3**, and the exhaustive compiled-core differential **11** (357 cases, artifact567). Macro fixtures make nine builds; the file exceeds 1,200 seconds but passes **15 assertions** under the existing 3,600-second per-file setting (artifact570, 1,242.394 seconds). These are semantic tests, not latency or speedup promises.

## Final verification and remaining baseline debt

The **25 selected files pass 3,195 assertions** across split per-file receipts: the focused/current-runtime union above plus all four JS gates. A final five-file run passes **847 assertions with zero failures and zero incoherent files** (artifact576): optimizer174, lifetime32, kernel451, JSON163 and exception-kind27. It includes the final source and normalized test files. Final fixture measurements above come from this green run; preceding combined-source runs measured 12.23× and 12.33×.

The broader preparation sweep (`./bin/bl --cold test -p .`, artifact570) reaches existing failures before the 1,200-second service cap; it does **not** complete. Selected baseline comparison on unchanged main b5 (artifact574) reproduces seven failing file families: stale ANF corpus snapshots (81 differences), AOT fixture shadow ownership, VM/session CLI, callable shape/error descriptions, datom term ordering, xberg duplicate temp paths and drop packaging. JSON and exception-kind pass that isolated selection, but their broader-prefix failures are reproduced on unchanged main's ordered capped sweep (artifact576). Both files also pass alone in the corrected final five-file run. Their order-sensitive failures are therefore not unique to this preparation; the responsible state leak is not diagnosed here.

Main's ordered sweep also fails its old durable corpus fixtures that acquire a shared `/tmp/x` lease; this preparation already uses `open-fresh` and passes that file. Errors printed after SIGTERM are shutdown output, not additional source diagnoses. **FUP-164** tracks the reproducible broad baseline and suite-order isolation debt. No failures are silently waived and no full-suite-green claim is made. The corrected narrow slice is verified; an actual merge still needs authorization and an explicit policy for the existing baseline debt.

The preparation commits corrected merged source, permanent tests, coherent seed and these receipts. The verified source snapshot is based on `b5e63edb`. During verification main advanced to `4ff1a2e7` through three live/UI commits; these do not overlap the corrected source paths. A follow-on compatibility merge and live/UI gate refresh is recorded below. Main source and unrelated working state are not overwritten. All owned capped services and review workers have exited; diagnostic probes are retained separately, not installed as application APIs. Deferred FUP-155/158/159/160/161 remain open.

## Latest main compatibility refresh

After verified snapshot commit `53894592`, preparation incorporates main `4ff1a2e736c1bebae523c30bbf830e3bfed2b0e6` (three additional live/UI commits). No source conflict or bootstrap-source change occurs. The floor checks current across 79 namespaces again. `artifact://1598ead9f02e4261/main/bash/582.txt` is green: **8 files, 1,213 assertions, zero failures/incoherent** — live app-context21, diff397, projection17, socket118, app3, optimizer174, lifetime32 and kernel451. Runtime34.817s, peak313.2M, zero swap.

The five live files add 556 unique assertions to the selected25-file receipt: **30 selected files, 3,751 passing assertions across split receipts**. The separate final JSON/exception-kind diagnostics add coverage but are not counted in that selected total. Latest first/filter fixture is1,100,808 →90,717 reductions/200 calls,976 →1,208 bytes,46,819 →72,902 caller compilation reductions; preceding fixture table remains explicitly tied to artifact576. These fixture spreads are not an app/UI speed claim. Main is still not merged or deployed by this branch.

## Final native/style snapshot

A final bounded refresh incorporates main `c4b57bc7049e288698604ee3424d716eb9ee2fec`: native JSON persistent-vector encoding/count validation and bounded immutable style declaration reuse. Only that exact main snapshot is claimed verified; later upstream movement needs its own compatibility check. The JSON NIF is rebuilt from this preparation's Rust source with `cargo build --release --locked --jobs 2` in an isolated target directory and staged as an ignored artifact, not copied from a possibly stale installed binary.

`artifact://1598ead9f02e4261/main/bash/588.txt`: native release build succeeds (15.287s,409M peak,0swap), then **6 files/874 assertions/0fail/0incoherent** — native-vectorJSON34, JSON163, loom token20, optimizer174, lifetime32, kernel451. Runtime16.208s,264.7M,0swap. Two new selected files add54 unique assertions: **32 selected files/3,805 passing assertions across split receipts**. The JSON163 diagnostic was already recorded separately and is not counted twice. Main is not merged or deployed.

## Reproduction

Run checkout `./bin/bl`, not the installed drop, with `BL_DAEMON=off`. Inspect `scripts/bl-mem` before each VM, serialize the runs, and use memory/swap/runtime caps. Corrected host source requires the current coherent seed before test results can certify this image.

```sh
scripts/bl-mem
systemd-run --user --collect --wait --pipe --working-directory="$PWD" \
  --setenv=BL_DAEMON=off --property=MemoryMax=8G \
  --property=MemorySwapMax=2G --property=RuntimeMaxSec=1200 \
  ./bin/bl --cold seed --check

scripts/bl-mem
systemd-run --user --collect --wait --pipe --working-directory="$PWD" \
  --setenv=BL_DAEMON=off --property=MemoryMax=8G \
  --property=MemorySwapMax=2G --property=RuntimeMaxSec=1200 \
  ./bin/bl --cold test -p . test/bl/optimizer_first_filter_test.bl \
  test/bl/realm_code_lifetime_test.bl test/bl/reduce_kernel_cutover_test.bl
```

Deferred features remain FUP-155/158/159/160/161. No extra public DSL, parallel lookup cache, speculative realm AOT adapter, or permission-expiry shortcut is introduced.
