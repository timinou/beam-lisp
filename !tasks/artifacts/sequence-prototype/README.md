# Isolated sequence optimization prototype

## What this experiment establishes

All four proposed mechanisms execute and have independent comparison cases:

1. Use the existing representation-directed RT reducer rather than a second general reducer.
2. Emit a direct BEAM fun call for an arity-2 function instead of RT.invoke.
3. Specialize an immutable, known integer-add callback and preserve a guarded suffix fallback.
4. Compile a closed, pure, non-escaping range/indexed-map/take/sum program into one loop, authorized by SMT induction obligations.

This is a prototype, not a production compiler change. It is written in Beam Lisp and uses Core Erlang as the code-generation interface. The direct/specialized machine kernels are constructed explicitly to test what a future lowering pass should emit. It does not discover and optimize arbitrary Beam Lisp source or automatically specialize today's core/+ value.

The production sources, native ABI, configured build inventory and bootstrap seed are untouched.

## Run

From the repository root:

```sh
export BEAM_LISP_PATH="$PWD/!tasks/artifacts/sequence-prototype"
export ELIXIR_ERL_OPTIONS='+S 8:8 +SDio 8'
export ERL_CRASH_DUMP=/dev/null

systemd-run --user --scope --collect -p MemoryMax=6G -p MemorySwapMax=1G \
  env BEAM_LISP_PATH="$BEAM_LISP_PATH" ELIXIR_ERL_OPTIONS="$ELIXIR_ERL_OPTIONS" \
  ERL_CRASH_DUMP="$ERL_CRASH_DUMP" \
  bin/bl test '!tasks/artifacts/sequence-prototype/prototype_test.bl'

systemd-run --user --scope --collect -p MemoryMax=6G -p MemorySwapMax=1G \
  env BEAM_LISP_PATH="$BEAM_LISP_PATH" ELIXIR_ERL_OPTIONS="$ELIXIR_ERL_OPTIONS" \
  ERL_CRASH_DUMP="$ERL_CRASH_DUMP" \
  bin/bl run '!tasks/artifacts/sequence-prototype/benchmark.bl'
```

Use `set -o pipefail` if adding `| tee`. The explicit library root is necessary for isolated tests; the test runner does not automatically add this directory to namespace roots.

## Files and APIs

- `performance/sequence-kernel.bl`: generates and loads one uniquely named, ephemeral BEAM module. There are no new repository-authored Elixir/Erlang source files. A normal module_info interface makes this generated image inspectable by the profiler.
- `performance/sequence-prototype.bl`: experimental public entry points and guards.
- `performance/sequence-proof.bl`: actual base, transition and terminal SMT obligations.
- `prototype_test.bl`: semantics, fallback, effect, refusal and emitted-instruction tests.
- `benchmark.bl`: independent timing, memory-allocation and call-count phases.
- `test.log`, `benchmark.log`, `results.json`: accepted final evidence.
- `benchmark.partial.log`: incomplete earlier run, retained as provenance only; its native counters included a measurement-helper allocation and its cprof phase failed before generated module_info was added. Do not use it as final evidence.

Use `representation-reduce(f, init, coll)`, `direct-reduce(f, init, coll)` and `arithmetic-reduce(f, init, coll)` to exercise the first three stages. `adder()` supplies the known immutable callback. No snapshot of reloadable core/+ is declared to be a trustworthy immutable operation.

`compile-plan(pipeline, :fused)` returns a compiled guarded callable only after the obligations are proven. `:formula` additionally selects the proven closed-form result. Compile-plan accepts this exact program:

```clojure
{:source :range-zero
 :map [:int-add :index :value]
 :reduce :int-add
 :init 0}
```

It creates the source internally, only returns the scalar result, and accepts an integer bound n>=0. It never accepts caller assertions such as `:pure true` or `:proof {:verified true}`. Extra fields, custom functions, external/shared sources and unsupported modes are refused. Arithmetic/domain and non-escape knowledge come from this closed program vocabulary, not from arbitrary closure introspection.

## Guard and replay contracts

- Non-list representations and non-arity-2 callables retain the existing RT reducer.
- Direct calls preserve the callback, ordering, early Reduced termination and one-level sentinel peeling, including lazy improper tails. Error/throw kinds and reasons are tested; generated stack frames necessarily differ.
- Integer specialization requires exact identity with the generated immutable adder and integer initial state. Noninteger elements resume at the unchanged suffix with the same callback; prior elements are not replayed. Floats, errors and big integers are covered.
- Unsupported effects/sharing in a fusion request are refused before invoking a custom callback.
- This is an explicit opt-in DSL, not a transparent replacement for arbitrary sequence expressions. Native statistics, memory-budget refusal timing, VM resource exhaustion and concurrent code-loading behavior are not modeled by the algebraic SMT proof. A production rewrite must establish its resource/reload/error observability contract rather than claim these were universally proven here.
- The prototype is not a security boundary against replacing its implementation or oracle. It neither changes sandbox capability handling nor grants authority to opaque callables.

## What was formally checked

For the accepted program, x=i and mapper(i,x)=i+x=2i. The loop invariant is:

```text
0 <= i <= n
acc = i*(i-1)
```

The SMT obligations establish the base at i=0, preservation by acc'=acc+2i and i'=i+1 while i<n, and terminal result n*(n-1) at i=n. All three statuses are unsat. Changing the multiplier to3 is a negative control: the transition is sat and authorization is false.

The constructor uses only the verified factor2 template. Unknown/error outcomes cannot set verified=true. Solving is setup work, not an operation performed per element. The other reducer stages use runtime guards and differential tests; they do not claim a universal SMT proof of the existing RT collection semantics.

## Verification

The final gate reports **123 passed**, with1 file passed,0 failed and0 incoherent. It contains15 named tests and covers:

- Empty/singleton and31/32/33/63/64/65 chunk boundaries.
- Lists, vectors, sets, maps, native tuples and lazy fallback.
- Ordinary and lazy improper tails, no producer replay, no force after early halt.
- Callback effects/order, Reduced nesting/initial state, arity, error and throw reasons.
- Float suffix fallback, invalid operands, big integers, changed callback identity.
- Real proven/refuted SMT obligations and refusal of custom/shared/forged plans.
- Disassembled direct call_fun/call_fun2 and absence of RT.invoke in the generated plain kernel.

The accepted benchmark has **150 checked unprofiled samples**, **30 calibrated allocation profiles**, and **10 separate cprof profiles**. All answers match n*(n-1). Five interleaved repeats run at1000,16000 and64000 elements.

## Measurements at16000 elements

Times are microseconds. Heap words are allocated over one operation, not retained memory or peak RSS.

| Case | Median us | VM reductions | Allocated heap words |
|---|---:|---:|---:|
| Raw Erlang fold over prebuilt list |132|48243|0|
| Current public reduce, core/+ value |19898|4528706|944045|
| P1 RT representation reducer, same core/+ |6502|1008790|624066|
| P1 RT reducer, known immutable adder |1171|224566|128048|
| P2 direct callback application |244|48876|84|
| P3 integer arithmetic specialization |152|17087|104|
| Raw Erlang range construction plus fold |373|55919|32000|
| Unfused closed pipeline, known callbacks |100567|12985205|3729640|
| P4 verified fused loop |69|16581|43|
| Bonus verified n*(n-1) formula |6|580|43|

### Interpretation

P1 is an apples-to-apples operator-value comparison. The next P1-known control intentionally switches to a certified callback; do not attribute that change to representation routing alone.

P2 removes per-element dispatcher/argument-storage work:128048 allocated words become84, and224566 reductions become48876. The whole-call profile still has constant wrapper/checking overhead; the inner generated kernel uses direct fun application.

P3 inlines the known integer operation: the16000 callback invocations disappear, leaving17087 reductions. Its extra identity/type guards cost20 more fixed heap words than P2; allocation is still independent of sequence length in these small-integer runs.

P4 eliminates the source/mapping/take adapters and memo cells for the closed single-consumer program. Heap allocation falls from3729640 words to43; native new-fast operations fall from1501 to0, and fast reads4997 to0. Unfused/fused VM work is783x different. Observed median timings differ by1457x, but host contention and scheduling mean this is not a universal speedup promise.

The fused loop measured5.4x faster than the list-building Erlang reference and used less VM work/storage because it avoided the list and callback machinery. It is **not** a demonstration of superiority over an already-optimal hand-fused Erlang loop. The same Core Erlang can be produced by another language.

The optional formula demonstrates an actual algorithmic reduction, not loop micro-optimization. It replaces O(n) traversal with integer arithmetic for this proven program. Arbitrarily large integers still have size-dependent arithmetic cost; it is not O(1) in integer bit width.

At64000 elements, medians were: raw prebuilt list590us; current public reduce136611us; P1-known5933us; P2 direct1234us; P3 specialized996us; raw range+fold1929us; unfused616880us; fused371us; formula11us. All raw samples and1000-element results are retained in results.json.

## Measurement method and caveats

This run used OTP29 and8 schedulers. Inputs for reducer-only controls were built before timing; raw-range-loop and pipeline controls include source construction. Timings include the same answer-checking wrapper. cprof is separate from unprofiled timings.

Heap allocation uses OTP's isolated trace session and call_memory on exactly one outer thunk. Each observation requires a matching function and exactly one call for the current process. This includes allocations in untraced callees, not NIF-owned/native saved-term memory. The counters are captured before formatting/selection helpers to exclude measurement-created lazy nodes. The API is documented at https://www.erlang.org/doc/apps/kernel/trace.html#info/3.

Kernel emission/loading took9838us. First proof-backed plan setup took338453us, including demand-loaded proof/oracle initialization. The subsequent formula setup took3260us with reused proof infrastructure/cache. Those are setup observations, not isolated solver timings and not included in hot execution.

The machine is contended, so use work/allocation counts alongside wall times. Per-call constant wrapper overhead is visible in the prototype and makes the tiny formula timings noisy. Native operation statistics are global; they are not a replacement for rooted native retention measurements.

## Next production decision

The experiment supports all four mechanisms. Integrating them requires a real source/ANF recognition and proof-to-lowering path, guarded higher-order operator evidence and a single reducer cutover. It must preserve unsupported callables/representations and explicitly decide which observable resource/reload behaviors constrain fusion. Production performance and the repository-wide suite have not been changed or declared green by this prototype.
