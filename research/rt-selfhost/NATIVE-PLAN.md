# A semantic kernel with representation-directed lowering

Execution: see [EXECUTION.md](EXECUTION.md) for implemented experiments, current measurements and unpassed production gates.

Status at plan creation: source-reviewed design and prototype plan, 2026-09-21. No new performance runs or seed rebuild were performed for this review. This document qualifies the earlier RESULTS.md; those measurements are a small exploratory sample, not evidence of a correct replacement runtime.

Tracking: PLAN-137-evaluate-native-lowering-and-runtime-rep. Production cutover remains separate (FUP-117).

## 1. Conclusion

Self-host the semantics, not necessarily every storage mechanism. Describe each value family once; compile that description into direct BEAM operations where shapes are known, retain a generic BL implementation where they are not, and offload bounded bulk kernels only where conversion and scheduling costs justify it.

The central distinction is **semantic family versus physical representation**. A small vector and a trie vector have one meaning but different access paths. A decimal and an integer may compare equal without sharing a layout. A lazy sequence has an observation protocol, not a materialized container layout.

A single classifier called on every element is not the destination. A single authority that lets the compiler eliminate classification is.

## 2. Existing lowering: what is available

### Core Erlang backend: use immediately

`lib/beam_lisp/aot_cache.ex:aot_backend` defaults to Core. `priv/boot/compiler.bl` emits bl-ANF; `priv/boot/lower.bl` lowers it to Core Erlang and calls `compile:forms`. OTP then supplies BEAM execution, including its platform-dependent JIT. This is distinct from BL's research Cranelift path.

The IR in `priv/boot/anf.bl` already contains `:cons`, `:enil`, `:tuple`, `:map`, `:struct`, `:case`, and pattern nodes. `compiler.bl:cons-cell` already creates cons IR for syntax quotation; `lower.bl` already emits `cerl:c_cons`, tuples, and native clauses.

Consequences:

- Do not keep krt's make_tuple/setelement/tuple_to_list/append construction dance. Give the kernel a compiler-recognized, hygienic path to the existing constructors. Recognize resolved intrinsic identities, not the spelling of a user-rebindable `cons` or `tuple`.
- Generate classifier and dispatch clauses from the same kind descriptions. Predicate calls, match arms, and generic fallback must not maintain separate lists of struct exceptions.
- Specialize known representations: vector count becomes the tuple size or trie count field; vector nth uses its existing tree operation; known map lookup bypasses generic kind dispatch.
- Hoist unknown-input dispatch outside a reduction. Avoid repeated `kind`, `first`, `next`, and wrapper allocation in the inner loop.

These are proposed kernel/compiler integrations, not features proven to be wired today. Reuse the IR and lowerer rather than adding a second compiler.

### Existing defnative: retain for mechanisms

`priv/boot/compiler.bl:compile-defnative` calls `priv/std/vm/native.bl:declare`; build machinery in `priv/build/build.bl` compiles native crates. This loads prebuilt NIFs; it does not compile arbitrary BL functions into machine code.

The existing lazy memo resource is a good boundary: BL can own realization policy while native code owns resource lifetime and synchronization. Keep its concurrency contract intact during the protocol port. Owner death and recursive forcing are semantic decisions, not performance defects to change accidentally.

### Cranelift: selective second experiment

`research/j1_probe/src/main.rs` supports scalar integer operations, byte loads/stores, and a counted-loop kernel. `research/lowerers_spike/lower2.bl` emits its IR. `research/native-offload/offload.bl` invokes the standalone process. There is no integrated Cranelift NIF host in the inspected native tree, and no SIMD vocabulary in this probe.

Good initial workload: a bounded fold over an already-packed byte binary. Later candidates include typed numeric scans and codecs, but those require additional supported operations and explicit semantics. Arbitrary maps, lazy realization, numeric-tower operations, and tiny `first`/`kind` calls are poor initial candidates.

The current gate is not sufficient as an execution-safety certificate:

- `priv/lib/native/eligible.bl` checks effects, termination, and return sorts, not a complete input/buffer/work contract.
- `priv/lib/system/prove.bl:native-eligible?` and the LSP have weaker eligibility predicates. They should consume one verdict, not become independent authorities.
- Termination alone does not establish a scheduler-safe work bound.
- A differential test establishes agreement on tested inputs, not universal equivalence.

Before in-VM execution: validate argument sorts, overflow behavior, buffer lengths, read/write bounds, aliasing and ownership, maximum work, and scheduling policy. A dirty CPU NIF is not automatically cancellable or harmless. A JIT handle must be an owned resource retaining executable memory and ABI metadata, not an unchecked integer-to-pointer registry. Resource lifetime must cover concurrent calls and hot code replacement.

## 3. Data structures from first principles

| Structure | Keep | Change / investigate |
|---|---|---|
| Lists | BEAM cons cells; O(1) head/tail and cheap persistent sharing | Empty test must be constant-time. Never use `length` merely to discover a head. |
| Vectors | Current small tuple and persistent 32-way trie with tail buffer | Separate indexed access from traversal; introduce/reuse a cursor or leaf-chunk reducer, not list materialization. Measure retained-parent memory for views. |
| Plain maps and sets | BEAM maps/MapSet for persistent storage; do not replace their mature storage engine casually | Separate semantic key normalization from storage. Remove Set -> RT semantic dependency. Preserve original keys if iteration promises them. |
| Sorted collections | Existing gb_trees range-iterator affordance | Audit `Sorted.encode_key` against the same semantic order as compare. gb_trees uses Erlang term ordering, so an arbitrary comparator cannot simply be injected. Keep an order-preserving key projection or deliberately choose another tree. |
| Lazy sequences | Existing memo resource, concurrency policy, chunking and SeqCursor mechanisms | Use bounded observation. `nth n` must force only its required prefix; comparison stops at the first difference. Equal infinite sequences need not terminate. |
| Strings/binaries | BEAM binaries and iodata sinks | Distinguish bytes, codepoints and graphemes. No byte-loop optimization may silently change grapheme semantics. Copy small escaping slices when retaining the backing binary is worse. |
| Records | Current representation at public/interop boundaries | Fixed-layout tuple specialization only for proven closed shapes whose representation does not escape to reflective interop. |
| Typed bulk values | Packed binaries where element sort is explicit | Treat them as a separate physical representation, not as a forced replacement for heterogeneous persistent vectors. Conversion must be included in timings. |

Evidence: `lib/beam_lisp/vector.ex` contains the two vector layouts and trie operations; `set.ex:add/del/member?` call RT.hash_key; `sorted.ex:encode_key` owns a separate encoding table; `lazy_seq.ex` and `seq_cursor.ex` already supply resource/chunk mechanisms worth extending.

The prototype adds avoidable costs in `krt/seq.bl`: list `k-first`, `k-rest`, and `k-seq` call `erlang/length`; vector rest calls `Vector.to_list`; lazy nth calls `k-to-list`. Repeated list traversal through these operations becomes quadratic. A fixed-size microbenchmark cannot establish their scaling behavior.

### Traversal is its own protocol

Prefer a collection-specific reduction/cursor capability over making every operation funnel through a list-shaped seq. Select the traversal once; visit trie leaves, map iterators, sorted ranges, or lazy chunks directly. Keep `seq` as the user-visible adapter, not the compulsory implementation of everything.

Build eager outputs with a builder whose ownership is explicit. Reuse existing transient affordances where their contract fits. Do not introduce mutation until non-escape is proven; persistent fallback remains correct. Stopping a reducer must not force the next lazy cell or invoke callbacks that an unfused program would skip.

## 4. Semantics: the missing center

The previous '= is compare==0' construction guarantees only that those two implementations agree. It does not guarantee a valid order, compatible hashing, or the intended language semantics.

The contract must cover:

1. Equality reflexivity, symmetry, and transitivity on its declared domain.
2. Comparison antisymmetry and transitivity; compare==0 iff equal for orderable values.
3. Equal keys produce the same semantic hash/key representation. Hash collisions never establish equality.
4. An ordered-key encoder preserves comparison and does not merge unequal admissible keys.
5. Metadata, numeric cross-kind equality, sequential families, sorted/hashed siblings, exceptions and lazy realization obey an explicit policy.
6. Persistent encodings exclude or explicitly encode runtime-local identities such as functions, PIDs, and resource handles. Runtime order is not automatically a portable storage format.

Do **not** make full canonical materialization the implementation of all equality. That would sort/copy collections unnecessarily and force lazy or infinite values. Use a shared semantic specification with specialized algorithms: size/membership checks for unordered equality, streaming sequence equality, ordered comparison only when requested, and key canonicalization at finite-key boundaries. Their shared specification and law tests—not a claim that all algorithms are one function—establish coherence.

A proposed descriptor separates:

- physical recognition and reserved runtime tags;
- semantic family and supported capabilities;
- cardinality/traversal facts;
- equality/hash/order policy;
- constructor/access primitives;
- effects, realization and ownership constraints;
- specialization conditions and generic fallback.

Generate predicates and dispatch from recognition data. Keep actual algorithms as normal BL functions. Avoid an ambitious universal registry that encodes algorithms in opaque metadata. Adding a kind must either supply required capabilities or cause a validation error; unknown host structs must have an explicit opaque fallback.

Sequential equality needs a decision before cutover: current vector/list/lazy behavior cannot all be preserved while making equality transitive. The prototype plan must expose this as a compatibility decision, not silently turn it into an optimization.

## 5. Corrections to the initial prototype evidence

Source review found:

- `krt/eq.bl` gives different function values comparison result +1 in both directions: not antisymmetric.
- Different numeric kinds with the same rank still fall through to a kind-name tiebreak: integer/float equality is not preserved.
- Sharing a rank does not implement cross-kind structural comparison. The rank-table comment claiming unified list/vector/lazy equality is not what the final branch does.
- `krt/kind.bl` predicates inspect field presence independently of `kind`: a plain map with `:items` can satisfy `vector?`. The claimed single authority is not yet achieved.
- `krt_test.bl` prints counts rather than asserting failure; its parity check excludes operations where RT throws and does not establish equality parity. Returning nil where RT throws changes semantics, not merely robustness.
- The benchmark uses wall-clock time, callback dispatch, best-of-three, a fixed collection size, and compares krt comparison against RT equality. The measured ratios cannot isolate classifier cost or prove a faster comparator.
- No call-site/import analysis here proves transitive independence through storage modules. An unexplained RT import is an unresolved edge, not proof of its irrelevance.
- The earlier 'four identifiers' describes visible compiler seams, not the full cost of replacing all boot-time operations, literals, hashing, invocation, storage dependencies and linking.
- BUG-090 is resolved as an invalid reproduction. `interop_test.bl` verifies computed, bound and inline argument lists all work; the recorded `P` supplied lists where maps:from_list requires tuples. There is no demonstrated computed-apply compiler blocker.

These do not undermine self-hosting feasibility. They change what the next prototype must prove. No new runtime reproduction is claimed in this review.

## 6. What would make this compelling

### A runtime that disappears at known call sites

Same BL source and semantics; a known vector count becomes a field read, a known list head becomes a cons match, and an unknown value keeps the generic implementation. Self-hosting makes semantic implementations visible to the compiler rather than maintaining separate optimizer folklore.

### One collection expression, no intermediate collections

A pure map/filter/reduce over a vector walks leaf chunks directly; over a packed binary it can become a bounded native kernel. This is conditional fusion, not permission to reorder user effects or alter exception/realization order. Intermediate allocation eliminated is often more valuable than a faster allocator.

### An explainable optimizer in the REPL

Reuse analysis and codebase affordances to explain: chosen representation, eliminated dispatch, residual fallback, eligibility refusal, and proof dependencies. For example: 'BEAM vector-leaf fold; native refused: callback effect unknown.' This is a proposed integration, not an existing UI claim.

### Storage order as a checked projection

The same semantic policy can govern collection equality, sorted keys, and admissible datom encodings. This enables trustworthy cross-representation lookup and range behavior. Codec compatibility requires versioning and migration; changing a rank table must not silently reinterpret persisted indexes.

### Specialization with a small trust base

The reference BL implementation is the differential oracle. Constructors and shape checks lower through existing ANF. Native code stays a narrow mechanism or certified fragment. Specializations are keyed by semantic/representation version and the relevant compiler summaries, so hot reload invalidates the right artifacts. This does not itself solve existing node-global namespace isolation.

## 7. Prototype plan: small experiments, hard gates

### P0 — Repair the evidence before optimizing

Target existing krt files and harness in `research/rt-selfhost/`; no production behavior changes.

- Add failing assertions for kind/predicate coherence, numeric cross-kind behavior, comparison antisymmetry/transitivity, metadata-insensitive keys, sorted/hashed pairs, and collection-key lookup.
- Cover vector sizes 0, 1, 31, 32, 33, 1024 and 1025; nested values; reserved tags; invalid indices; unknown structs.
- Instrument lazy callbacks: nth only forces the requested prefix, unequal infinite streams can stop, take/reduce do not force an extra effectful cell.
- Separate intentional policy changes from compatibility failures. Do not call scalar count totality an optimization.

Gate: failures exit nonzero; law tests and compatibility expectations are explicit. Capture the current failures before fixing them.

### P1 — One descriptor, two execution paths

Build one small descriptor for list, vector and plain map; derive recognition predicates and generic dispatch. Extend existing ANF constructor paths so the kernel no longer allocates temporary tuples to manufacture cons cells. Generate direct Core clauses for proven shapes with a generic fallback.

Gate: inspect ANF/Core/BEAM for actual cons/tuple nodes, constant-time list emptiness, and eliminated generic dispatch on known shapes. Differential tests include malformed/unknown input and exception behavior. Measure a transitive dependency graph; do not waive unexplained RT edges.

### P2 — Cursor/reduction experiment

Reuse existing SeqCursor/chunk contracts where applicable; add a vector leaf traversal and a streaming lazy nth. Compare generic sequence traversal, representation-directed BEAM traversal, and the existing RT at geometrically increasing sizes.

Gate: linear whole-collection traversal; bounded lazy realization; no full materialization for a prefix; report elapsed time, allocation/GC, reductions and retained memory. Benchmark equal operations, warm the code, use monotonic time, consume outputs, include a harness baseline, alternate variant order and publish all sample distributions. A speedup without these checks does not pass.

### P3 — Native only where the batch earns it

Start with the existing standalone Cranelift byte-fold pipeline over a packed binary, not a new general collection backend. Run an actual live differential comparison against compiled BEAM, including overflow and zero-length cases. Only after a conversion-inclusive crossover is measured should an in-VM JIT resource be added through defnative.

Gate: one shared eligibility verdict; refusal tests for unsafe sorts/bounds/work; verified buffer contract; scheduler responsiveness under load. If in-VM integration proceeds, test resource lifetime, concurrent calls, invalid handles and hot replacement. No speed target is assumed in advance; keep BEAM when offload loses.

### P4 — Scratch bootstrap fixpoint

After the required boot operations and key semantics are implemented, install the kernel in an isolated copy/cache, rebuild the toolchain, then rebuild with that generation. Leave committed `priv/bootstrap/seed/` untouched during the experiment.

Gate: explicit transitive host-dependency inventory, no RT dependency in the intended replaced layer, focused language suites and deep doctor pass, and stable generation artifacts (byte identity where deterministic, otherwise a documented normalized comparison). Only then propose production cutover.

The first decisive demonstration is P1+P2: BL-authored semantics, direct BEAM constructors, dispatch erased where proven, and linear traversal with correct lazy effects. Cranelift is an optional accelerator after that—not the justification for the architecture.
