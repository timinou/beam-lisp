# Callable and analysis continuation

## Verified checkpoint

The fresh staged continuation gate recorded **125 tests / 312 assertions**, zero failures/errors, for the new callable, analysis, SMT, LSP, host-effect, loop-cost and generator-domain features plus existing analysis compatibility suites. The fresh memo/cursor/replay bundle recorded **107 tests / 1103 assertions**, zero failures/errors, with the rebuilt native library. Native Rust tests independently recorded **29 passed** after formatting and release compilation. These overlapping bundles are not a unique test total and do not establish the repository-wide suite.

Evidence: `/tmp/bl-performance-final-continuation-gates-158e8a77.log`, `/tmp/bl-performance-analysis-final-gates-158e8a77.log` and the native build tool artifact. The final real published gate passes all 19 files, and the final package matches the floor/NIF and passes cold/strict smoke. Full evidence is in performance-postfix-results.md; an authorized staged boot warning is not a public cold-boot acceptance result.

## Plain function invocation

`rt.call-invoke` checks `erlang:is_function/1` before the general kind classifier. A plain function is an immutable value; the classifier's scalar/container branches cannot change its kind. Non-functions still use the existing classifier and call protocol. Argument-list length remains eagerly validated, then the existing `erlang:apply/2` performs the call. No namespace binding, environment value or host capability is cached or bypassed.

`callable_kernel_test.bl` checks arity/error/exit behavior, improper arguments, external functions, multi-functions, collection callables, struct refusal, capabilities and live rebinding. A calibrated process-local trace proves that plain-function invocation skips `kind-kind`; non-function controls still reach it. This is a structural optimization claim, not a wall-time claim.

## Every function clause

`system.analyze` compiles every clause, preserves source guards, and joins calls/effects/returns over the clauses. Consumers now walk every clause in incremental analysis, linearity/affine checks, type checking and LSP position/reference analysis. Each clause retains its own parameters. The incremental hash includes clause order, arity and parameter positions; renaming remains equivalent, but selecting a different parameter is not.

SMT helper inlining selects an exact fixed arity. Variadic, guarded, ambiguous or missing clauses refuse translation. A repeated test exposed a second shape: the compiler can resolve a previously declared helper to a direct remote call rather than `RT.invoke`. Both shapes now use one inline implementation, and the direct route is restricted to the analysis module's own source-defined helpers. Unsupported actual arguments are checked even when a constant helper ignores its parameter; recursion is explicitly refused instead of recursing indefinitely in the translator.

## Host effects are evidence, not a module label

`system.footprint` certifies exact `[module function arity]` primitive signatures. Being in `erlang`, `lists`, Core or RT does not prove purity. Process state, indirect apply, higher-order callbacks, lazy forcing, native counters and unknown instructions stay opaque without specific evidence. Arithmetic propagates argument effects; custom struct hooks remain conservative.

Namespace readiness guards can initialize providers, so their effects are not erased from analysis. A collection count can force a producer. Existing footprint tests retain named resource effects while acknowledging these additional unknowns; exact immutable BIF and macro-expansion controls remain exact.

## Local loop context

`codebase` retains syntactic `:call/loop-depth` and adds `:call/effective-loop-depth` plus `:call/cost-coverage`. Local call edges propagate possible enclosing loop context through helpers. Known foreign iterator callback positions distinguish `Enum.map`'s second argument from BL map's first; referenced callbacks produce edges as well as literal function bodies.

Propagation is bounded by the local function inventory. Recursive functions and their reachable helpers are marked `recursive` without a finite effective-depth claim. External/dynamic callers remain outside this local analysis. `nplus1` queries both inherited and legacy syntactic facts and deduplicates sites at their greatest known depth. The fact schema version is bumped so cached source analyses acquire the new columns.

## Generator domains and public compatibility

Both `veritas` and `veritas.property` use generator-aware candidates when the generator supplies them. A shrunk witness must remain in the generator's domain and still fail the property. Unsupported custom generators retain their original witness. Multi-argument properties without a tuple-domain generator do not fabricate per-coordinate domains.

The public `shrink-coords(fail?, witness)` API is retained for compatibility. It remains explicitly generator-blind and is not used by generator-aware checking. `shrink-in-domain(gen, fail?, witness)` is the shared domain-preserving path. Original and shrunk witnesses remain separately available.

## Boundaries

These repairs do not turn all-types returns or opaque footprints into proof. They do not add a universal interprocedural cost model, cross-source loop propagation, epoch-cached namespace dispatch, general beta reduction or exported recursive scaffold lifting. Native graph-lock scope remains unchanged: cycle reachability and edge insertion retain their existing atomic safety boundary. Unsupported optimization proposals are rejected rather than enabled behind an unsafe fallback.
