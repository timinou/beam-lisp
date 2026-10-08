# Current sequence overhead: diagnosis, not an optimization claim

## Request

The user rejects several-hundred-fold overhead against Erlang and expects Beam Lisp's formal tools to produce faster, more efficient execution. The diagnosis confirms that most of the demonstrated gap cannot be excused as an unavoidable cost of Lisp or lazy semantics. The previous repair completed loading, generation, safety and analysis foundations; it did not deliver general proof-directed sequence specialization or fusion.

## Reproduction and evidence

Run `!tasks/artifacts/sequence-overhead-decomposition.bl` through the current published `bin/bl run` in a systemd user scope with MemoryMax=6G, MemorySwapMax=1G, ELIXIR_ERL_OPTIONS='+S 8:8 +SDio 8', ERL_CRASH_DUMP=/dev/null. Use pipefail if piping into tee.

- `sequence-overhead-decomposition.log`: initial nine-case investigation, 45 checked timing rows and 9 profiles.
- `sequence-overhead-matched-kernels.log`: final expanded twelve-case investigation, 60 checked timing rows and 12 profiles.
- `sequence-overhead-summary.json`: medians and all sorted timing samples from the final run.

Every result is 255984000 at n=16000. Same-list controls use prebuilt input; construction is excluded. Five unprofiled repetitions are interleaved across cases after warmup. cprof is run separately, never used as a latency sample. Final CLI `nil` is not a JSON evidence row. The first attempted run failed because the diagnostic used the wrong JSON namespace; the corrected artifact uses bl.json/encode.

This workstation is strongly contended. Wall measurements vary widely and are observations rather than isolated causal speedups. VM reduction counts are considerably more stable across repetitions. cprof counts include both namespace facade and body calls: do not count their equal kind-kind tallies as twice as many classifications. Native stats are global; concurrent collection can produce negative retained-byte deltas. Those deltas are not per-case peak-memory measurements.

## Final matched measurements

| Case | Median milliseconds | Median VM reductions |
|---|---:|---:|
| Raw Erlang fold, multiply and sum | 0.124 | 48024 |
| Raw fold over already-doubled list | 0.126 | 48024 |
| BL +/* arithmetic inside raw fold | 0.196 | 48024 |
| Explicit BL integer loop | 0.420 | 48027 |
| Existing RT list kernel, BIF callback | 2.456 | 224043 |
| Existing RT list kernel, + as a value | 8.941 | 1008246 |
| Public BL reduce, BIF callback, same list | 19.251 | 3712295 |
| Public BL reduce, + as a value, same list | 30.825 | 4528480 |
| Finite-input pipeline, BIF callbacks | 137.320 | 8932785 |
| Finite-input pipeline, BL callbacks | 196.512 | 9764371 |
| Lazy pipeline, BIF callbacks | 129.392 | 13004202 |
| Lazy pipeline, BL callbacks | 235.440 | 13854192 |

Use the JSON for ranges; these are not latency guarantees. The public same-list BIF path does 77.30x the raw VM work. The existing RT BIF kernel does 4.67x, so the public path uses 16.57x more work than the already-present kernel. Full lazy pipeline work is 288.48x raw. No fresh optimized implementation was installed or benchmarked.

## Observed causes

### 1. Public reduction does not consistently use the representation-directed kernel

`priv/boot/core.bl:37-63` sends a LazySeq to RT/k-reduce, but implements other collections through its own loop using empty?, first, rest, dynamic callback invocation and a value-bound reduced? predicate. `priv/boot/rt.bl:3756-3799,4026-4055` already contains representation-directed folds with raw list tests and head/tail access.

For the public same-list BIF case, cprof recorded in the body (with matching facade traffic):

- kind-kind:224014 (about14 classifications per input integer).
- Core tuple__bl_v and to-list:32002 each.
- Core list__bl_v:16001.
- Rt invoke/call-invoke:32001 each.
- Env fetch!, own-module, epoch_ref/current_epoch:16001 each.
- list_to_tuple:32002.

There were no memo creation/read/CAS operations in this case. Thus lazy storage is not the cause of this plain-list gap. The profile identifies generic predicates, conversions, namespace lookups and wrappers as substantial per-element work; it does not assign exclusive time to every individual helper.

Calling the existing RT BIF list kernel directly drops kind-kind to1 for the whole fold and removes Core conversion/Env traffic from the dominant call profile. It still invokes Rt.invoke/call-invoke16000 times. In `rt.bl::step`, even the is_function(f,2) branch writes an ordinary `(f acc x)` call; `compiler.bl::anf-invoke` emits the generic runtime dispatcher for such calls. The compiler does not use the branch's arity evidence to lower this to a direct fun call.

### 2. Direct arithmetic specialization is lost when arithmetic becomes a callable value

`compiler.bl::linked-call` already lowers fixed binary numeric calls into an :arith node with native int/float handling. This is why BL +/* inside the raw fold has the same48024 reductions as direct BIF arithmetic, and no numeric-host dispatch dominates its call profile.

But `rt.bl::seed-closures` constructs + as a multi-fn with no fixed arities and a variadic clause folding from0. When + is supplied as a reducer value, each binary step goes through multi-fn dispatch, argument packaging and an internal fold. The RT + list case uses4.50x the work of the RT BIF callback case. Operator identity/arity information is not carried through the higher-order call sufficiently to use the existing binary specialization.

### 3. Sequence stages remain adapters and memo machinery, not a fused consumer loop

`core.bl::map-indexed` uses the generic chunked producer, whose step calls LazySeq.cell, constructs output/state tuples, advances an index and uses prepend-all and sequence helpers. `chunked` creates memoized chunk producers. This is different from the specialized fold recipe present in `rt.bl::lazy-map`; do not attribute that recipe to map-indexed.

The full lazy BL profile records660001 kind-kind body calls and130000 invoke/call-invoke body calls. Native stats record1501 new-fast operations,1499 CAS plus1499 fast CAS, and4997 fast reads. Replacing user arithmetic with BIF callbacks still leaves about13million reductions. Arithmetic alone cannot remove this layered sequence work.

### 4. Plain BL loops are viable, but loop lowering still has a scaffold

The explicit integer loop uses48027 reductions, near the raw fold's48024, without generic sequence machinery. cprof observes two anonymous functions16001 times each, consistent with compiler.bl's self-application loop lowering. This is a remaining optimization candidate, not an exclusive allocation/latency attribution; no allocation trace or revised loop emitter was run.

## What formal logic must do to earn its performance claim

Formal analysis is useful only when its evidence drives code generation. The current compiler has specific arithmetic lowering and safety checks; source proof/type/effect tools do not constitute a general sequence-fusion optimizer. Loop annotations retain trusted termination evidence and do not automatically erase scaffolds or intermediate collections.

Priorities derived from this evidence:

1. Cut over public reduction to one verified representation-directed implementation, preserving supported collections, sentinel/error behavior and intentional live-binding semantics. Do not add another parallel reducer.
2. Use proven callable arity/type to emit direct fun calls, and specialize known binary numeric callbacks without silently changing numeric-tower/errors/rebinding semantics.
3. Fuse single-consumer sequence stages where types, callback effects, escape/sharing, demand/error order and runtime/budget contracts permit. Shared/escaping or unsupported producers must retain memo replay.
4. Lower eligible self-application loops into direct recursion after proving captures and return/error behavior.
5. Gate on end-to-end result/semantics tests and call/allocation/work budgets, not merely source changes or one lower timing.

Fusion and algebraic reduction can beat an unfused straightforward Erlang program by doing less work. The same optimal loop or BIF on the same BEAM cannot be promised faster merely because the source is Lisp or carries proofs. Formal logic can establish permission to remove work; an implemented lowering pass must actually remove it.

## Scope boundaries

This is a fresh diagnosis with reproducible evidence, not a production performance fix. Production sources and the source-generated seed remain unchanged. The whole language has not been profiled: these mechanisms plausibly affect other generic/higher-order paths, but each claimed regression needs its own same-semantics attribution. Full-suite classification remains separate.
