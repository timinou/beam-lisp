# From sequence kernels to an automatic Beam Lisp optimizer

## Scope and evidence

This is a design proposal answering how the measured experiment can become automatic across Beam Lisp. It does not implement or measure a production optimizer. Reuse `README.md`, `results.json`, `test.log` and `benchmark.log`; do not extrapolate their speedup ratios to unrelated programs.

The desired universal property is semantic safety: every program can pass through the optimizer, and unsupported cases retain their existing implementation. Universal elimination of overhead is neither established by the experiment nor attainable by a complete analysis of arbitrary dynamic programs. Unknown facts must remain unknown, not become permission to rewrite.

The experiment establishes four useful mechanisms, not a general source recognizer:

1. Choose an existing representation-specific reducer instead of generic per-element sequence operations.
2. Apply a proven native function directly instead of packing arguments for RT.invoke.
3. Expose and specialize the actual higher-order operation, with domain guards and suffix fallback.
4. Eliminate pure owned intermediates, or the traversal itself, when an equivalence obligation is satisfied.

The general insight is to preserve semantic information until emission. More native code is not the necessary first step: the experiment obtained its gains by generating better BEAM code.

## Existing architecture: useful extension points and limits

Observed in the current source:

- `compiler` (`priv/boot/compiler.bl`) emits the canonical bl-ANF. `anf-invoke` currently represents a general callable invocation as a remote RT.invoke with an argument cons chain. `linked-call` already emits a canonical `:arith` for supported binary numeric links. `assemble-fn` distinguishes native fixed-arity functions from tagged multi-arity/variadic callable values.
- `anf` (`priv/boot/anf.bl`) already has `:apply`, `:arith`, patterns, clauses, annotations and a validated module descriptor. A new direct-call IR is unnecessary: `lower` already lowers `:apply` to `cerl/c_apply`.
- `lower/module->core` validates and emits that descriptor. `descriptor->beam` and `eval-anf` share the descriptor path, giving a common place for an optimization pass covering AOT, eval and reload. The same source also preserves source positions and deterministic fresh names.
- `core/reduce` currently routes LazySeq to RT.k-reduce and otherwise uses generic operations. `rt` already owns representation-specific reducers. Its `step` checks `erlang/is_function(f,2)` but writes the callback as ordinary `(f acc x)`, which the current frontend still routes through general invocation.
- `system.ir` supplies canonical traversal, aliases and annotation support. `system.summary` and `system.analyze` supply return/effect/call summaries and coarse higher-order flow. Current call-set extraction recognizes RT.invoke and remote calls; general `:apply` targets need consistent modeling too. `system.footprint` currently treats unknown genuine `:apply` as opaque, which is conservative but not a precise optimized-call summary. Their current source-facing analysis APIs compile source again; a compiler-integrated pass must consume the descriptor it already has rather than recursively invoking source compilation.
- `system.analyze` currently computes a coarse name-to-function flow map with a bounded round count. That is useful analysis infrastructure, not automatically a sound closed-world authorization for specialization. Optimizer facts need lexical/namespace/arity identities, explicit unknown flow and sound widening or fallback at a convergence limit.
- `typed` and `system.typecheck` provide type diagnostics. Diagnostic tagsets are not automatically proofs of exact representation, callback ABI or integer-only arithmetic.
- `system.footprint` classifies exact primitive operations by module/function/arity. However, its `pure?` permits read footprints. Reading an atom, a file or a live binding is not referential transparency. It also does not by itself establish absence of exceptions, stable reads, safe demand reordering or algebraic commutativity.
- `system.linear` primarily verifies that compiler emission does not duplicate compiled subtrees and blow up code size. This is important for specialization, but is not a producer-escape or lazy-consumer-ownership proof.
- `self.anf` and `host.anf-interpreter` provide an independent control/binding interpreter over the same runtime. Keep it as a differential oracle, while remembering that shared runtime bugs still need independent expected-result tests.
- `host.aot-cache` hashes all boot sources for the compiler identity and has source-closure keys. `ns-interface`, `source-graph`, `seed` and `selfbuild` are deployment/build integration surfaces. Inlining a dependency's body requires body dependencies, not only its public interface key.

## Recommended architecture

Use one automatic pass pipeline over the existing ANF, before Core Erlang dispatch scaffolds erase useful distinctions:

```text
source
  -> macro expansion, symbol/link resolution
  -> canonical ANF descriptor
  -> value/callable/type/effect/use facts
  -> candidate rewrites + checked preconditions
  -> optimized, validated ANF descriptor
  -> Core Erlang -> BEAM
```

One proposed boot-safe namespace, `optimize`, would own pass orchestration and checked rewrites. This is a proposed name, not an existing namespace. Start by emitting existing ANF operations. If explicit loop-region vocabulary is later justified, update `anf`, its validator, all `system.ir` traversals, `self.anf` and lowering together; do not create a competing sequence IR that only the optimizer understands.

Facts may be derived views of ANF, but ANF remains executable truth. Add one shared call-site reading in `system.ir` for general RT.invoke, proven native `:apply`, resolved remote calls and their actual arguments. Call graphs, effects, termination, typing and tooling must remain consistent when a rewrite changes call shape; do not teach each engine a different dispatcher pattern. This is necessary even if no new ANF opcode is introduced.

Suggested facts include:

- Callable representation, exact accepted arity, possible targets and whether those targets are stable.
- Collection representation and element/accumulator domains.
- Effects, possible exceptions/divergence, read stability and live binding dependencies.
- Producer uses, escape/alias information, demand behavior and replay requirements.
- Callee body identities and the assumptions under which each fact holds.

The pass should have three outcomes:

1. Preconditions statically established: emit the fast form.
2. Preconditions cheaply testable: evaluate inputs once, emit guarded fast/fallback forms.
3. Preconditions unknown, costly or invalid: keep the original form.

A failed entry guard can run the original program. A guard failing after traversal starts cannot restart effects or replay a prefix: carry the current accumulator, source cursor and remaining stage state into a continuation of the baseline semantics, or restrict that rewrite to entry-proven inputs.

## Four priorities as automatic rules

### 1. One authoritative reducer

Route the public two- and three-argument reduction contracts through the existing RT kernel, after differential coverage of all supported representations and observable binding behavior. Remove the redundant generic walk rather than introduce a competing public fast-reduce API.

Maintain collection-specific storage walks underneath that one semantic boundary: proper/improper lists, dense/trie vectors, maps/sets with existing ordering, native tuples and shared lazy cursors. Preserve empty no-init behavior (including callback arity zero), Reduced handling and exactly one sentinel peel at the appropriate boundary.

This benefits ordinary library code without a solver and without purity assumptions on callbacks. It is still a semantic cutover needing tests, not a license to bypass supported rebinding or collection contracts.

### 2. Direct callable lowering

The smallest useful frontend rule is branch refinement:

```text
if erlang:is_function(f, 2)
  then invoke(f, [a,b]) -> apply(f, a,b)
```

Here `f` must denote the same immutable lexical value in both expressions, the guard must dominate the call, and argument evaluation order/count must be unchanged. Use the existing `:apply`; no SMT call is necessary for this structural theorem.

This closes the precise hole in RT.step and applies to user code, comparators, predicates and higher-order helpers too. Direct invocation does not require a pure callback: effectful callbacks can still execute exactly once in the same order.

Then specialize the reducer's callback mode once per traversal where invariant, rather than repeatedly deciding native/tagged/variadic dispatch per element. A native-fun fact is stronger than the generic label `:fn`. Tagged callable values can eventually have checked fixed-arity extraction, but keywords, maps, protocol dispatch and unknown callables must keep their own semantics.

### 3. Higher-order operation specialization

Preserve an operation's identity through value positions, lexical aliases and helper parameters. Recognize the actual resolved implementation, not a source spelling such as `+`.

For an established integer-add callback, generate the guarded integer loop automatically. For a user lambda such as `(fn [a x] (+ a x))`, specialize only when its resolved body and captured dependencies authorize that lowering. Keep generic numeric-tower and callable fallback.

In particular, the experiment's immutable adder does not prove that today's variadic core/+ value equals a raw binary addition in every numeric domain. Arity, intermediate initialization, decimal behavior, signed floating-point values and error behavior need domain-specific evidence. Do not reassociate floating-point sums merely because integer addition is associative; BEAM arbitrary-precision integers also differ from fixed-width native integers.

Use a bounded number of private variants, selected by static facts or cheap entry guards. Do not create a module/atom per runtime value. Variant limits and compiler-output linearity are acceptance gates.

### 4. Recognize and fuse ordinary pipelines

Recognize producer/transformer/consumer relationships in resolved ANF, including aliases and helper calls. A normal expression such as:

```clojure
(reduce + 0
  (map-indexed (fn [i x] (+ i x)) (range n)))
```

should eventually select a guarded fused loop without a special pipeline DSL, subject to the actual resolved call identities, bound domain, demand semantics and resource policy.

Start with closed finite integer sources and scalar consumers. Preserve stage order and state: an index before a filter is not an index after it; take-before-filter counts a different stream from filter-before-take. For transducers, initialization, completion and early Reduced are part of the contract, not only the two-argument step.

Fusion does not require an associative reducer when it preserves sequential left-fold order. Parallel reduction and algebraic reassociation are separate rules requiring stronger laws.

For the first production fusion rule, require intermediates to be private, non-escaping and sufficiently pure/total over the accepted domain. Unknown consumers, saved/shared LazySeq values, mutable reads, observable producer failures and chunk lookahead are barriers unless an additional theorem accounts for them. A hypothetical new `system.ownership` analysis would answer this question; it must not be confused with current `system.linear`.

Use parametric rewrite laws for common map/filter/take/fold composition. Prove library laws once and match their preconditions cheaply; use bounded SMT for new arithmetic invariants, domains and closed forms. Do not run a global solver on every function, during every startup or in hot loops.

## Proof validity, cost and reload

A proof authorizes a specific rewrite over specific inputs and dependencies. A useful certificate identifies the original region, replacement, rule/version, domain, effects, ownership assumptions, callee body hashes, compiler/runtime semantics version and any runtime guards.

Author metadata is a hint to be checked, not authority. A user-authored `:pure`, `:verified` or forged annotation cannot authorize a rewrite. An unsat mathematical obligation is not a proof of unmodeled replay, quota or reload semantics.

Cache proof/fact results by semantic inputs. Position-only changes may reuse mathematical evidence while regenerating source mappings. Changed callee bodies invalidate inlined facts even if interfaces stay unchanged; unchanged unrelated bodies should not require a global reproof.

A persistent-cache invalidation rule does not solve live reload by itself. A namespace epoch check at function entry is insufficient when the baseline observes binding changes during its loop. Either preserve those live reads, use truly captured/stable local code, or establish a compatible version/pinning contract before hoisting them. Never silently freeze a live var to save lookups.

Bound solver time, analysis rounds, variant count and emitted code size. Timeout, unknown, missing solver or unsupported theory must preserve valid compilation via baseline fallback. The bootstrap floor must be able to rebuild without depending circularly on the not-yet-built analyzer or prover; supply raw-ANF analysis interfaces, keep the boot pass lightweight, and stage richer proof support separately.

Memory savings naturally alter resource use, but public quota/counter APIs and deterministic budget refusal can be observable. Before transparent lazy allocation elimination, specify whether budget refusal is an implementation resource limit that optimization may avoid, or whether a logical charge/refusal must be preserved. Keep native accounting and shared-cell publication guarantees untouched until that contract is established. Error reasons/source positions must remain useful; intentional implementation-frame changes and debugger behavior also need explicit policy.

## Namespaces affected

### Direct implementation changes

| Area | Namespaces / files | Responsibility |
|---|---|---|
| Public semantics and kernels | `core`, `rt` | Single reduction path, callback-mode selection, guarded kernels, sequence contracts |
| Compiler and emission | `compiler`, `anf`, `lower`; proposed `optimize` | Retain facts, automatic recognition, checked rewrite, direct calls, bounded private variants |
| Shared analysis | `system.ir`, `system.analyze`, `system.summary`, `system.arity`, `typed`, `system.typecheck`, `system.footprint`, `system.incr` | Canonical input, precise callable/domain/effect facts and dependency-aware reuse |
| New ownership capability | proposed `system.ownership` | Escape, alias, use and demand/replay obligations |
| Numeric and lazy boundaries | `host.num`, `host.lazy-seq`, `host.lazy-memo`, and the existing cursor implementation | Numeric-domain equivalence, private versus shared producers, replay/publication and resource policy; not all require initial source changes |
| Build/reload | `host.aot`, `host.aot-cache`, `host.env`, `host.loader`, `host.tiers`, `ns-interface`, `source-graph`, `seed`, `selfbuild` | Cache/body dependencies, live binding validity, source inventory, coherent floor regeneration and package publication |
| Proof and regression tooling | `system.smt`, `oracle`, `z3`, `self.anf`, `host.anf-interpreter`, `system.linear`, `veritas`, `codebase`, `lsp` | Rule obligations, differential/property testing, code-size gates, optimized/refused explanations |

Host namespace files maintain their exact existing host-module interfaces. These are design surfaces, not a claim that every listed file must change for the first reducer/direct-call integration. Rust/NIF changes are not required for the first three mechanisms or BEAM-only closed pipeline fusion.

### Downstream beneficiaries, not bespoke rewrite targets

The prelude's map/filter/map-indexed/keep/mapcat/take/reduce/transduce/into/sequence and short-circuit consumers are primary opportunities. Application namespaces using those operations receive the optimization centrally.

Compiler/build data traversal, codebase/analysis tools, datom query and projection code, live/UI rendering and user libraries are candidates for reduced dispatcher/allocation overhead. Their total speedups remain unmeasured; I/O, database algorithms, scheduling and other costs may dominate. Do not hand-edit every application namespace or claim all namespace families are covered by the single sequence benchmark.

## More prototypes: yes, but integration prototypes

The ideal machine kernels have already been measured. Three remaining experiments close different untested assumptions:

### A. Real-source automatic lowering

Use the normal compiler, not hand-built Core images or a plan DSL. Compile ordinary reductions, anonymous callbacks, captured values, lexical aliases, helpers and cross-namespace callbacks. Verify optimization without user assertions and refusal for shadowed/unresolved names.

Acceptance: optimized versus baseline results/effects/errors match; disassembly demonstrates the intended inner direct calls/BIFs and eliminated adapters; behavior remains valid on zero/tiny and mixed-domain inputs; compile time and module size stay bounded; same-input comparisons retain work/allocation evidence. This first vertical slice should include ordinary core/+ as a value, the untested bridge from the prototype's immutable adder.

### B. Observable lazy and effect semantics

Exercise two consumers, escape through returns/containers/closures, partial realization, chunk boundaries, infinite sources with finite consumers, early Reduced, producer failures, mutable reads, callback effects and a midstream type mismatch. Include budget refusal, rooted replay and concurrent shared realization tests.

Acceptance: eligible private pipelines automatically fuse; unsafe cases either stay baseline or satisfy an explicit stronger rule. Compare traces and force/replay behavior, not only final sums. No prefix replay or unmodeled dropped exception is acceptable.

### C. Open-world build and reload validity

Change/rebind a callback before execution and during a traversal; edit a helper body without changing its signature; introduce opaque foreign/protocol calls; remove or time-limit proof support. Rebuild the self-hosted compiler, reload affected namespaces and test a fresh packaged VM outside the repository.

Acceptance: stale evidence cannot authorize a rewrite; supported live reads are preserved; only actual proof/body dependents are invalidated; unknown/timeout cases compile via fallback; deterministic output and coherent source-free seed/package audits remain green.

These are targeted tests of automatic recognition, observational semantics and deployment validity, not three repetitions of the existing throughput test. Implement and test the low-risk single reducer and guarded direct-call cutover while pursuing stronger fusion evidence. Do not wait for a universal theorem prover to fix the demonstrated dispatcher overhead.

## Additional capabilities

With validated shared facts and proof-to-lowering in place, the same infrastructure could support:

- Specialized comparators/predicates and higher-order combinators beyond reduce.
- Local scalar replacement: eliminate private tuples/vectors/maps/closures that are constructed only to be immediately consumed, preserving metadata/hash/error semantics.
- One-pass search/count/aggregation and output builders. Materialized outputs still allocate their required storage; the goal is removal of intermediates, not zero allocation for every result.
- Better finite loops: guarded private recursion rather than unnecessary self-application plumbing, with source positions and recur semantics preserved.
- Algebraic strength reduction or closed-form traversal elimination for proven domains, with no claim of automatic derivation for every algorithm.
- Stable-read common-subexpression elimination, unreachable branch removal and bounds-check elimination only when the required stability/domain/termination facts are established.
- Cost/size diagnostics and an explain view naming the rule, guards, dependency evidence or refusal reason. Such facts should improve tooling as well as generated code.
- Later, independently verified query pushdown, batching, parallel folds or native offload. These need separate laws for ordering, effects, null/duplicate/numeric semantics, scheduling and bounded work. Current `native.eligible` is an analysis verdict, not demonstrated end-to-end native code generation or a sufficient optimizer certificate; its argument-domain and work/resource obligations require further validation.

The recommendation is an automatic, conservative optimizer over the language's existing IR, not a bag of benchmark-specific fast APIs. Start with the two source-visible dispatch defects, then carry trusted operation and ownership facts far enough to make ordinary programs receive the proven lowerings.
