# Runtime lowering prototype: execution report

Research-only implementation of [NATIVE-PLAN.md](NATIVE-PLAN.md). Production sources and committed bootstrap seed are unchanged. The decisive result is **BL semantics with generated Core fast paths and representation-directed traversal**, not a completed replacement of RT.

## What runs

| File | Responsibility |
|---|---|
| `krt/kind.bl` | Registered representation descriptors; one classifier; predicates read classification, structured families read the descriptors |
| `krt/number.bl` | One exact rational projection for integers, IEEE floats and decimals |
| `krt/eq.bl` | Family-directed comparison; equality derived from comparison |
| `krt/key.bl` | Canonical finite hash keys; refuses lazy/identity/opaque values, including nested ones |
| `krt/seq.bl` | Constant-time list head/emptiness, bounded lazy nth/take, record extension fields, cons chains with lazy tails |
| `krt/reduce.bl` | Direct list, vector-leaf/trie, lazy and map-iterator reduction; reduced short-circuiting |
| `krt/emit.bl` | Emits raw constructors/callback application and shape-directed count/sentinel matches through existing ANF/Core APIs |
| `run.bl` | Installs the generated floor, then runs the asserting suites |
| `bench.bl` | Five samples per variant, geometric vector sizes, consumed outputs, monotonic timing and resource counters |
| `bootstrap_probe.bl` | Disposable-process **subset** generation fixpoint |
| `audit.bl` | Static module-import closure with explicit dynamic-edge limitations; asserts the intrinsic is RT-free and that kernel roots reach RT |
| `native_experiment.bl` | All-BL harness: independently compiled BEAM versus live standalone Cranelift byte fold |

The earlier `krt_test.bl` and `krt_bench.bl` names delegate to the new harnesses; there is only one current implementation of each suite. `RESULTS.md` is an explicitly qualified historical report, not the current verdict.

## 1. Core lowering does useful work now

The generator consumes the registered vector and reduced-sentinel module identities. Its descriptors lower through `anf/module` and `lower/descriptor->beam`; no production compiler extension was needed.

Generated `Elixir.Krt.Intrinsics` implements:

- cons as Core `[_h|_t]`, empty as `[]`;
- tuple construction as Core tuples;
- list head/tail as cons patterns;
- two-argument callback invocation as direct Core application, not an allocated argument-list followed by runtime invocation.

Generated `Elixir.Krt.Specialized` implements:

- a **known-vector count** with no classifier and no fallback;
- generic count with direct vector/plain-map cases and a krt fallback;
- a reduced-sentinel pattern match generated from the same representation descriptor used by classification.

The vector pattern includes the actual trie discriminator (`:bl_vec`, integer count greater than 32). Tests cover a five-element small vector containing the trie tag: tag-only recognition would be wrong. The generic list count retains the protocol fallback because an improper cons chain may have a lazy tail; a blind `length` would throw.

This is an explicit generator experiment. It is **not** automatic whole-program specialization of arbitrary user code, nor a new surface-language intrinsic syntax. Primitive list/map patterns are authored against BEAM primitives; only registered struct identities/families are descriptor-derived today. Generated modules are snapshots: changing descriptors requires explicitly reinstalling them. Automatic dependency invalidation and hot-reload integration are not implemented.

## 2. Correctness gates, including the gate itself

The semantic harness now requires a literal true result. Its independent canary rejects false-returning and raising checks before the law matrix runs. The original harness discarded false results; its old green count was not trustworthy.

Coverage includes:

- predicate/classifier coherence, reserved tags, opaque foreign structs;
- comparison antisymmetry and transitivity over a heterogeneous matrix;
- sequential and sorted/hashed sibling relationships;
- exact numeric comparison/key congruence at 2^53, subnormal floats and decimal boundaries;
- metadata transparency, including nested values and trie-held vectors;
- finite semantic-key lookup and refusal of unsupported nested values;
- record type identity and extension fields added by assoc;
- vector traversal at 0, 1, 31, 32, 33, 1024, 1025, 4096, 32768 and 100000 elements;
- lazy nth, take-zero, no extra cell after take/reduced termination, and unequal infinite-sequence comparison stopping after the first observed difference;
- raw constructor, callback, sentinel, fallback and known-shape rejection behavior.

Timing diagnostics do not decide correctness. The list-head scaling test prints its timing but gates on behavior, not wall-clock ratios.

### Explicit prototype policies

This is not a compatibility cutover:

- Lists/vectors/lazy sequences form one sequential equality family.
- Numbers compare by exact value: integers n/1, floats via `Float.ratio`, decimals unscaled/10^scale, reduced by gcd. Thus `1 = 1.0 = 1M`, but binary float `0.1` is not exactly decimal `0.1M`.
- Records retain their type and every field except the implementation tag; metadata wrappers are transparent.
- Finite key projection is a **hash-key representation, not an order-preserving codec**. It does not authorize replacing Sorted.encode_key or persisted datom indexes.
- Existing BEAM sets/maps can physically contain numerically equivalent but representation-distinct keys (such as 1 and 1.0). This prototype preserves that carrier multiplicity rather than silently merging entries. Full collection construction under the new equality policy remains cutover work.
- Scalar sequence/count behavior is the prototype's documented policy, not an assertion of production exception parity.

## 3. Measurements

Full samples: [`evidence/bench-samples.edn`](evidence/bench-samples.edn). Aggregates: [`evidence/bench-summary.json`](evidence/bench-summary.json).

Five warmed samples, alternating variant order; every result is consumed and checked. These are compiled BEAM functions: current `compiler/eval_form` compiles through `lower/eval-anf`; `bl run` is not the reference tree interpreter.

### Complete vector sum: median milliseconds

| Elements | Generic krt seq walk | Core reduce | RT reduce | BL leaf reducer |
|---:|---:|---:|---:|---:|
| 32 | 0.0367 | 0.0135 | 0.00274 | 0.00511 |
| 1024 | 0.6016 | 0.2253 | 0.0484 | 0.0598 |
| 8192 | 6.9783 | 2.5071 | 0.5791 | **0.5147** |
| 32768 | 40.0976 | 16.2172 | 3.1647 | **2.4203** |

At 8192 elements the BL leaf path is 13.6× faster than generic krt traversal and 4.9× faster than Core reduce. It is in RT's range, not consistently faster across all sizes. At 32768 it has a better median than RT, but sample ranges overlap substantially: leaf 1.30–3.24 ms; RT 2.55–9.06 ms. Do not turn this noisy host run into a universal speedup claim.

A useful controlled implementation delta: before generated callback application and sentinel matching, the 8192-element BL leaf median was 2.4436 ms with about 274600 reductions. Afterwards: 0.5147 ms with about 111000–112000 reductions. Both runs consumed the same sum. Runtime work dropped, not merely elapsed time.

Reduction counts scale approximately linearly with input size (about 14570 at 1024, 112000 at 8192, 443000–445000 at 32768). The vector walk visits trie leaves and tail directly, without Vector.to_list. This does not imply every existing production vector consumer was quadratic; the measurements do not support that blanket claim.

### Vector count: median nanoseconds per call

100000 calls per sample, including the loop/callback harness:

| Variant | ns/call |
|---|---:|
| Harness baseline | 20.7 |
| Generic descriptor-driven krt count | 559.4 |
| RT count | 28.7 |
| Generated generic count | **25.9** |
| Generated known-vector count | 32.7 |

The meaningful result is removal of descriptor lookup (~21.6× relative to generic krt count here), not a claim that a 3 ns difference beats RT. Harness cost dominates the fast variants and their distributions overlap.

### Memory evidence

The harness records per-process reductions and before/after/post-GC memory, plus explicitly labeled VM-wide GC counters. At 8192 elements, post-operation process memory was 265–428 KB for the leaf path versus 603 KB for RT and 1.12 MB for generic krt traversal. These are snapshots, **not peak allocation or retained-view bounds**. GC history and other VM activity affect them; the raw records are retained instead of collapsing them into a claimed allocation factor.

## 4. Native experiment: a real differential, not a new runtime backend

The existing standalone Cranelift program was rebuilt from current source in an owner-private temporary directory. It agrees with independently AOT-compiled BEAM, a Python integer oracle and the probe's Rust reference for five fixtures: zero bytes, one byte, 64 bytes, the first u64-overflow case, and a deterministic 1 MiB buffer.

Latest 1 MiB inner times: **2.129878 ms native / 145.657 ms compiled BEAM** (about 68×). BEAM uses explicit u64 masking and best-of-three timing; native's CLI reports its own inner run. Process walls (6.79 ms native / 1577.47 ms BEAM) and BEAM startup (~940 ms) are separately reported, not presented as kernel speedups. Tiny microsecond-zero readings are below timer resolution.

Evidence: [`evidence/native-summary.json`](evidence/native-summary.json); full method and the initial independent run in [NATIVE-EXPERIMENT.md](NATIVE-EXPERIMENT.md).

No in-VM JIT was added. The experiment does not exercise a complete shared eligibility gate, prove native bounds/work/ownership, measure an in-VM conversion crossover, or validate resource lifetimes and scheduling. It supports choosing a packed bulk kernel as the next native target; it does not license native execution of the generic runtime.

## 5. Independence and bootstrap: what actually passed

The generated intrinsic module imports only Erlang functions. The known-vector and sentinel branches contain no classifier/Env calls. The generic specialized module retains a krt fallback by design.

The broader kernel is **not transitively RT-free**. Static module-import closure finds:

- semantic bodies → Env → RT;
- sequence and reducer bodies retaining RT.invoke imports;
- namespace init/link machinery → Env/Emit/Loader → RT;
- storage and lazy mechanisms with their own host dependencies;
- explicit dynamic callable fallback in the reducer.

The audit is conservative at module granularity, not a proof that every operation invokes all those dependencies. Conversely, dynamic Env lookup/apply/callback edges are not captured completely. No import is dismissed as 'vestigial' to manufacture an independence claim.

The subset fixpoint passed: install the generated modules, retarget both core links and values for first/rest/next/seq/count/nth to krt, recompile the generator, and emit the two modules again. Their BEAM binaries are byte-identical.

**This is not a full toolchain bootstrap.** The already-compiled compiler retains old links, and the full required boot surface (invocation, hashing integration, constructors, printer and other operations) is not replaced. Therefore the full P4/no-RT-seed gate remains unpassed, as does the production cutover. Nothing was written into the committed seed.

## 6. Reproduce

Run from repository root. Use a private scratch directory for generated artifacts:

```sh
export KRT_OUT="$(mktemp -d /tmp/rt-selfhost.XXXXXX)"
BL_NO_LOCK=1 bin/bl -p research/rt-selfhost run research/rt-selfhost/run.bl
BL_NO_LOCK=1 bin/bl -p research/rt-selfhost run research/rt-selfhost/bench.bl
BL_NO_LOCK=1 bin/bl -p research/rt-selfhost run research/rt-selfhost/bootstrap_probe.bl

BL_NO_LOCK=1 ELIXIR_ERL_OPTIONS="$ELIXIR_ERL_OPTIONS -pa $KRT_OUT" \
  bin/bl -p research/rt-selfhost build research/rt-selfhost/krt --out "$KRT_OUT/aot"
BL_NO_LOCK=1 bin/bl -p research/rt-selfhost run research/rt-selfhost/audit.bl

BL_NO_LOCK=1 bin/bl run research/rt-selfhost/native_experiment.bl
BL_NO_LOCK=1 bin/bl test test/bl/core_aot_test.bl test/bl/core_backend_test.bl
```

The final integrated suites passed **131 semantic checks and 127 traversal checks**, plus the generated-lowering assertions; the existing Core suites passed 16 and 29 assertions. The targeted AOT build compiled seven prototype sources. The native harness exits nonzero on any fixture mismatch. The audit prints its report and writes `$KRT_OUT/dependencies.txt`, exiting nonzero unless `Elixir.Krt.Intrinsics` reaches no RT and at least one kernel root reaches RT transitively. The AOT audit snapshot and complete benchmark samples are retained in `evidence/`.

The next architectural step is to graduate **descriptor-derived clauses and direct traversal**, not to rewrite all storage in native code. Complete semantic key/construction integration and the invocation floor before claiming an RT-free compiler generation.
