# Automatic optimizer: remaining coverage and next integration prototypes

## Current plan and status

PLAN-160 promotes the P1 subset (callback facts and private strict map/fold fusion, default and bounded) into the central optimizer; the experimental lexical option is retired and standalone alias rematerialization is refused as unprofitable. The current-source pre-merge promotion is accepted:317sources built without errors,105tests/3680assertions plus strict cold acceptance and150checked normal-source samples. See `optimizer-promotion-delivery.md`; the requested namespace-table branch merge requires its own combined-generation gate. P2 (callable mode) was measured as a negative result and stays baseline. P3 to Later remain deferred. The reasoning, evidence, counterexamples, promotion gates and review milestones for each deferral are in **`research/optimizer-integration/README.md`** (the revisit ledger); the historical measurements in this file and in `optimizer-prototypes-delivery.md` are retained unchanged. Current design: `docs/compiler/optimizer.bl.md`.

## Decision

Extend the existing implementation, not individual application namespaces. Every descriptor already passes through `BeamLisp.Optimize/module`; automatic entry coverage is complete, but rewrite eligibility is deliberately narrow. The next useful work is **lexical callback identity and private strict intermediate uses**, followed by a **measured per-traversal callable-mode experiment**. Broader strict composition can follow those facts. Ordinary public arithmetic values, indexed/lazy pipelines, transducers and algebraic traversal elimination need separate obligations; none is authorized by the existing map/fold law alone.

This roadmap follows implementation commit `9f76122a`. It reuses the accepted four-priority prototype, `sequence-prototype/generalization.md`, the production delivery report and the90 checked ordinary-source timing samples. It does not rerun those experiments or claim the following extensions are implemented. Source inspections: `agent://236-CurrentCoverage`, `agent://237-SequenceDomains`; their recommendations are inputs, not proof authority.

## Present coverage

| Mechanism | What is automatic now | Remaining boundary |
|---|---|---|
| Common compilation | `lower/module->core` calls the pinned optimizer; AOT, host emission, eval and descriptor reload share it | No separate application-specific passes are needed |
| Own-module identity | Literal closure module identity folds to the emitting module | `node` API lacks module identity; arbitrary closure identity is not inferred |
| Callable invocation | Literal native fn, lexical arity alias or dominating exact `is_function` guard permits native apply | Tagged multi-arity/variadic values, unknown callees or nonliteral packed argument chains remain dispatcher calls |
| Numeric dispatch | Established integer/float/number operand facts permit the existing Erlang numeric operation | Maps/decimals/unknowns preserve numeric-tower handling; no floating-point reassociation |
| Integer callback | Literal single-clause unguarded closed total integer callback over proven integer list and initial accumulator | Callback aliases are not resolved by `int-callback`; unknown captures, `_`, partial operations and guards are barriers |
| Strict map/fold | Syntactically immediate `lists:map` consumed by sequential `lists:foldl`; both callbacks closed total integer, source/initial domain proved | Let-bound intermediates, filter/indexed/xform regions, public Core/RT providers, shared or escaping lazy values are not covered by this rule |
| Public reduction | Core's3-arity boundary delegates to the authoritative RT storage walk, including the live-predicate compatibility adapter | This runtime cutover is separate from fusion eligibility. Native invocation rewrites can still benefit code inside those kernels; public-reducer fusion refusal does not mean zero optimizer benefit |
| Analysis consistency | `system.ir/call-site` describes invoke/apply/remote uniformly; summary, flow and footprint consume it | Descriptive analyses do not authorize new rewrites; no interprocedural proof flow is currently consumed |

Exact eligibility lives in `priv/host/optimize.bl`: `literal-fn`, `native-arity`, `int-callback`, `fact`, `refine`, `integer-fold`, `fuse-fold`, `ordered-apply`, `rewrite`, `walk` and `run`. `native-arity` accepts literal clauses of the same fixed parameter count; the stricter single-clause/plain-parameter restriction belongs to the integer callback rule, not every native invocation.

The existing pass preserves the backend's observed tail-before-head packed-cons argument evaluation with ordered temporary bindings. New eligibility must preserve that order and positional arguments, including callee evaluation, errors and effect count. Do not substitute an assumed language-standard order.

## Namespace map: ownership versus beneficiaries

| Surface | Existing namespaces / paths | Responsibility for further coverage |
|---|---|---|
| Algorithm home | `BeamLisp.Optimize`, `priv/host/optimize.bl` | Own checked facts, candidate recognition, laws, guards, refusals, hygiene and budgets. Keep new lexical-use/ownership facts here initially; do not add a competing rule engine |
| Public API | `optimize`, `priv/boot/optimize.bl` | Thin facade for module/node/run/explain/rules/version; do not duplicate eligibility or rewrite logic |
| Executable IR/emission | `compiler`, `anf`, `lower`, `BeamLisp.Emit` | Preserve useful resolved facts until canonical ANF; reuse apply/arith/let/fn. Emit remains an ABI adapter. Only add an IR opcode if existing forms genuinely cannot express the semantics, then update every reader/interpreter/validator together |
| Runtime callable/reducer semantics | `core`, `rt`, `BeamLisp.Num`, `BeamLisp.Reduced` | Authoritative storage walks, callable ABI, numeric domains, initial/terminal Reduced policy. Runtime helpers may implement mechanics; optimizer authorization stays central |
| Indexed/lazy/xform semantics | Core chunked engine, `map-indexed`, `keep-indexed`, `for`, `transduce`, `into`, `sequence`; RT lazy generators/xforms | Supply the actual order, demand, index, initialization/completion and output contracts to be proved, not bespoke fast APIs |
| Shared lazy/resource boundary | `BeamLisp.LazySeq`, `BeamLisp.LazyMemo`, `BeamLisp.SeqCursor` | Shared realization, immutable cursors, ownership/claim/retry, replay and native admission authority. No NIF or ABI change is required for the next lexical/strict extensions |
| Descriptive analysis | `system.ir`, `system.summary`, `system.analyze`, `system.footprint`, `system.arity`, `typed`, `system.typecheck`, `system.incr` | Shared call shapes and eventual descriptor-based facts. Diagnostic tags/coarse flow/read footprints are not optimizer certificates |
| Proof/oracles/tooling | `system.smt`, `oracle`, `z3`, `self.anf`, `host.anf-interpreter`, `system.linear`, `veritas`, `codebase`, `lsp` | Offline law/negative-control checks, differential/property tests, code-growth gates, evidence explanations and source positions |
| Build/reload/release | `BeamLisp.AOT`, `BeamLisp.AOTCache`, `BeamLisp.Env`, `BeamLisp.Loader`, `ns-interface`, `source-graph`, `seed`, `selfbuild`, `drop` | Semantic dependency invalidation, live-provider validity, source inventory, coherent seed and packaged cold acceptance |
| Beneficiaries, not rewrite homes | Compiler/build traversals; analysis/codebase tools; datom/query/projection libraries; UI/live rendering; application and user namespaces | Central eligibility determines benefits. Profile real workloads before claiming namespace-wide improvement; I/O/algorithms/scheduling may dominate |

A listed surface is an audit/dependency surface, not a mandate to edit every file. In particular, the next strict lexical extension need not change lazy hosts, native code, the entire type system or every application namespace.

## Priority and dependency order

### P0 — Preserve acceptance and explainability

Before enabling any new domain, retain baseline emission (`:enabled? false`), internally checked conditions, explicit refusals, deterministic fresh names, validated output and a bounded pass. The current node budget bounds visited optimization regions; it is not a guarantee that whole-descriptor validation or downstream compilation takes constant time. Measure compile time, output node/BEAM growth and evidence storage as well as execution work.

Release distinction: the new optimizer seed has strict fresh-floor proof and normal CLI gates. The previously accepted self-extracting package contains the previous floor; a regenerated package audit/outside-tree smoke remains a release gate before describing a new distributable as accepted. Do not treat old package evidence as proof of the new optimizer release.

### P1 — Lexical callback identity and private strict uses (recommended next implementation)

**Home:** `Optimize/fact`, callback recognition, lexical traversal and fusion matching.

**Narrow scope:** let-bound aliases of an already eligible literal callback; immutable captured scalar facts only where their domains are proved; a let-bound strict mapped list with exactly one eligible consumer and no escape. Reject globals, opaque helper calls, unknown captures, closures/containers/returns carrying the intermediate, multiple uses, recursion knots and unsupported binders.

**Why first:** reuse the existing integer and map/fold laws; improve ordinary source matching without a new lazy/resource theorem. `fact` already follows lexical arity aliases, but `int-callback` currently reads only literal callback nodes. Single-use recognition must establish dominance and preserve binding evaluation order, not simply replace every matching variable name.

**Required proof facts:** lexical binding identity, capture environment, shadowing and direct-use count; callback totality over the established domain; no intervening effect/read/error dependency moved by removing the strict intermediate. Private-use facts are not a blanket ownership theorem for arbitrary objects or lazy producers.

**Prototype acceptance:** compile normal source with a callback alias and private mapped-list alias; `explain` reports the existing rule; disassembly shows one fold/no map; equal results/effect/error traces versus disabled optimization. Negative controls: shadowed names, aliases used twice, returned/container/closure escapes, effectful or partial mapper, unsupported pattern and mismatched domain. Include generated-name collisions, wildcard binding ABI, complex argument evaluation and budget exhaustion. Bound analysis and generated variants; no source recompilation from an analyzer.

### P2 — Per-traversal callable-mode selection (parallel investigation, performance-gated)

**Mechanism surface:** RT `step`, `k-fold`, representation walks and `k-reduce` compatibility adapter. **Authorization:** one central structural rule or explicitly checked mechanics, not duplicated application rules.

`step` currently checks raw2-arity native representation per element. Experiment with choosing native-versus-generic mode once for the same immutable callable value and carrying that mode through the existing storage walk. Do not create a second public reducer. A generic wrapper that adds another callback frame may erase the gain: compare bounded variants/shared loop mechanics and do not ship merely because a check moved.

For nonlazy public reduction, distinguish the compatibility envelope callback from the user's underlying callback: proving the wrapper native does not prove the user callback native. Preserve current live `core/reduced?` fetches after callbacks and at exhaustion, initial empty behavior, intrinsic root-lazy behavior, one sentinel peel and improper-tail errors. Do not eagerly reject an invalid callable on an empty input where baseline never invokes it.

**Prototype acceptance:** every callable shape (native, tagged fixed/variadic, keyword/map/set/opaque), arity mismatch, supported collection kind, nested Reduced and before/mid/terminal predicate rebinding. Test empty/no-init, chunks31/32/33/63/64/65, early halt and improper tails. Show actual lower dispatch work by disassembly/profile and matched VM reductions; collect allocation evidence if claiming allocation reduction. Compiler/BEAM growth must remain bounded.

### P3 — Broader strict total composition

AfterP1, extend strict foreign-list matching to supported map chains and filter/fold, with explicit predicate domains (e.g. total integer comparisons) and sequential fold order. The baseline strict pipeline performs whole stages before the fold; interleaving is justified only when those callbacks are total, stable and effect-free over the accepted inputs. Merely having a read-only footprint is insufficient.

**Acceptance:** mapper/predicate/reducer each run at their specified frequency; preserve list order and fold argument orientation; test negative/zero/bignum values, all/none filters, noncommutative sequential reducers where admitted, and refusal for exceptions/effects/unknown domains. Add a law and a counterexample negative control for each new composition. Expand facts conservatively rather than declaring all foreign functions pure.

### P4 — Ordinary public arithmetic values and helper flow

The isolated immutable adder is not the production `+` VALUE. RT seed rows distinguish linked Num operations from a tagged variadic callable value. Native arity alone does not identify the operation, and the name `+` can be shadowed/rebound.

First prove exact captured callable/body identity, numeric-domain equivalence and dependency validity for the binary reducer case. Preserve the original arithmetic sequence, initialization and full fallback behavior for floats/decimals/mixed domains/errors; no blanket rule for `-`, `*`, division or associativity. General helper-parameter flow requires lexical/function/arity identities and explicit unknown/widening behavior; bounded coarse0-CFA is not enough by itself.

**Acceptance:** ordinary `(reduce + 0 coll)` and lexical/helper aliases; zero/one/many inputs; bignums, floats/decimals/mixed values; shadowing and rebinding before/during traversal; exact errors and no prefix replay. Helper body-only edits must invalidate facts even with unchanged signatures. Entry epoch checks do not justify dropping live reads later in a traversal. Use a guarded suffix continuation only if it preserves baseline state; never restart an effected prefix.

### P5 — Indexed and short-circuit consumers, then transducers/output builders

Core `map-indexed`/`keep-indexed`/`for` use the chunked lazy engine, not `lists:map`. Index-before-filter is not index-after-filter; rejected inputs still consume the appropriate index. Start with entry-proven closed finite sources and a scalar consumer, after provider validity and demand/resource obligations are established. Early-halt consumers need an explicit halt model and must not suppress baseline chunk lookahead/errors without a stronger theorem.

Transducers then need the0/1/2-arity init/complete/step protocol, correct early Reduced completion, stateful take/filter ordering, output representation, transient/persistent boundaries and metadata. `reduce-kv` is a distinct contract that does not simply inherit reduce's halt policy. `into`, `sequence`, `mapv` and `filterv` may share verified builder mechanics; required result storage still allocates.

**Acceptance:** index order and sparse filters; no extra demand after the contract's halt; finite consumer over infinite input; stateful xform init/completion counts and errors; metadata/type/ordering; empty and transient-threshold cases. Trace forcing/chunk publication in addition to sums. No claim of eligible lazy fusion untilP6 obligations apply.

### P6 — Private lazy eligibility, shared replay and resource policy

This is the highest-risk expansion. Syntactic single use alone does not prove a LazySeq is private: aliasing, captures, saved sources, shared memo cells and concurrent consumers matter. Central ownership/use/demand facts must distinguish construction, realization, published/replayed prefixes, producer failure/retry and immutable cursor roots. Never confuse `system.linear`'s emission-size check with ownership.

Resolve the observable resource policy first: native admission/quota refusal can be seen by programs. Either preserve required logical charges/refusals or establish an explicit supported policy under which eliminating private allocation may avoid them. Solver arithmetic proofs do not answer that policy question. Do not silently bypass native admission authority or alter shared-cell publication.

**Acceptance:** two consumers; escapes via return/container/closure; partial realization and replay; chunk boundaries; infinite sources with finite consumers; effects/mutable reads; early halt; midstream domain mismatch; producer failure/retry; quota refusal; concurrent realization and collector/root behavior. Unsafe cases must report refusal, not approximate ownership. Existing lazy/fold regression tests remain the base, not a forked engine.

### Later — Closed forms, scalar replacement and query/native domains

Closed-form traversal elimination needs arithmetic, termination and observational/resource obligations beyond fusion. The prior formula prototype remains evidence only for its closed DSL, not an ordinary-source optimizer rule. Private tuple/vector/map/closure scalar replacement needs construction/access/metadata/error contracts. Query pushdown/batching/parallel/native offload need separate null/duplicate/order/effect/scheduling/domain laws. Prioritize only after profiling identifies a real remaining cost; do not infer these capabilities from current eligibility verdicts.

## Three integration experiments, not more benchmark-only kernels

1. **Recognition:** ordinary source aliases/private strict intermediates through the normal compiler, with on/off equivalence and disassembly. Extend `optimize_test.bl`, call-shape tests and existing measurement harness; no new hand-built Core DSL.
2. **Observable semantics:** targeted callable-mode/live-predicate and pipeline demand/ownership adversaries. Extend `reduce_kernel_cutover_test.bl` and lazy/xform suites. Results/effects/errors/force traces must agree, not only final sums.
3. **Open-world deployment:** body-only provider changes, pre/midfold rebinding, opaque foreign/protocol operations, unknown analysis and absent/timed-out optional solver. Coherent source-free seed; independent fresh files for foundation-mutating tests; rebuilt package audit and strict outside-tree smoke for the new floor.

Offline SMT may validate new parametric laws and reject negative controls. Missing/timeout/unknown must retain baseline compilation, not become trusted evidence or a mandatory startup dependency.

## Evidence and exit criteria

Shipped ordinary-source measurements at16000: guarded native loop1263→1054µs and144380→80279 VM reductions; strict map/fold2036→619µs and119585→53226; integer fold536→582µs and54229→55530 (no observed improvement). These are contended-host observations; do not reuse them as expected gains for proposed domains. No separate allocation profile exists for that run.

A next domain is complete only when normal source triggers it without annotations, baseline parity and negative controls pass, explanations name internally established conditions/refusals, emitted work changes as intended, compile/output budgets stay bounded, and dependency/reload/seed/package gates appropriate to that change pass. All uncertain cases remain baseline. Full automation means automatic safe eligibility, not a promise that every program can be optimized.
