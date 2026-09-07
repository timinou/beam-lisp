# PLAN-090 / PLAN-091 final verification

## Delivered architecture

The public `compiler` namespace contains the compiler implementation. `compiler2.bl`, the quoted ANF normalizer/reverse bridge, mixed definition builders, host BootstrapAdapter, experimental quoted lowerers, and Elixir-emitter compiler options are removed. `lower/eval-anf` constructs a complete ANF module descriptor and uses the same descriptor emitter as live definitions, AOT bodies/shims/initializers/provenance, servers, records, and native host modules. Expression struct keys are ANF nodes; struct-pattern keys are literal data.

Finite compiler traversals use eager helpers. Deferred input is refused without forcing it. Shared user laziness uses native GC-owned memo resources, explicit failed-attempt retry, terminal owner loss, and cycle refusal. Loaded BEAM code has a separate lifetime and is not reclaimed by term GC.

The source-only editing companion has immutable plans, explicit hash authorization, persisted verification evidence and receipts, guarded inverses, symlink refusal, serialized application, recovery checks, and bounded systemd verification. Spell exposes explicit change tools; source proposals are not automatically applied by ordinary transcript rendering. Its real MCP lifecycle test uses the default host, including failed verification and a verified inverse.

## Verified gates

- Full runtime suite: **1,485 passed**, seed **151300**, after fixing the order-sensitive Clojure set dependency. Command: `MIX_ENV=test mix test --no-compile --seed 151300`, under a 10G MemoryMax / 1G MemorySwapMax scope. Evidence: `final-regression-result.log`. The preceding direct `mix compile.beam_lisp --force` in that combined command produced no observable build; it is not claimed as the uncached-build proof.
- Actual uncached build: **141 sources**, result `{:ok, []}`. Command: `MIX_ENV=test BEAM_LISP_AOT_CACHE=off mix run --no-compile --no-start -e 'result = Mix.Tasks.Compile.BeamLisp.run(["--force", "--source-dir", "priv", "--out", "/tmp/bl-plan091-uncached-explicit"]); IO.inspect(result, label: "UNCACHED_BUILD_RESULT"); unless match?({:ok, _}, result), do: System.halt(1)'`. Evidence: `final-uncached-build-result.log`.
- Compiler cutover: 89 host tests and 29 language tests / 110 assertions pass. Explicit `Elixir.String/...` qualification and capability enforcement pass a later 72-test focused gate. The runtime suite includes the added regression.
- Eager traversal: three same-VM batches of ten small and ten 64-binding units. Baseline registrations are 1,630 / 13,910 per batch; eager registrations are zero in every batch. Emitted hashes match across generations and repetitions. Loaded-module delta is zero. Evidence: `compiler-retention-comparison.log`; the comparison sub-gates pass even though that earlier combined run subsequently found a missing newly added corpus fixture. The completed corpus gate is recorded separately in `eager-gate-result.log`.
- Published bootstrap seed: **30 modules**, key `241722a693aad77d629802c4ad8acc7552104846d5acc60892ceab5ac3e0d450`. A fresh VM with stale namespace beams excluded boots, evaluates canonical code, and confirms that Compiler2 and retired ANF/lowerer exports are absent. A second independent VM rebuild produces byte-identical binaries for all 30 modules.
- Executable documentation: 9 native-ownership cells, 4 finite-data cells, 3 generation cells, 3 IR cells, 1 change-guide cell, and 1 conversation cell all execute with zero errors. Both change documents are byte-identical on replay. Evidence: `final-docs-result.log`.
- Spell MCP: **18 passed**, including actual plan/preview/verify/apply/receipt/inverse and failed-verification response serialization. Command from `spell/apps/spell`: `MIX_ENV=test mix run --no-start -e '{:ok, _} = Application.ensure_all_started(:beam_lisp); Mix.Task.run("test", ["--no-start", "test/mcp_test.exs"])'`. Evidence: `final-spell-mcp-result.log`. Spell commit `8baa5f0` stages only the editing integration; unrelated Loop work remains untouched.
- Research clients: canonical benchmark executes; census compiles 8,297 traversed forms with zero compile failures; all six value-oracle result maps report zero failures/errors.
- Native safety review: reviewer `26-NativeFinalReview` reports no material lifetime/concurrency defect, confidence 0.88, across native cells, LazySeq, and their regression tests. This is supporting review evidence, not a universal proof.

## Pre-existing failures corrected

1. A reused `_build` could preserve a newer generation while an old-host upgrade driver assumed the committed seed. Verification now uses explicit isolated seed staging.
2. AOT return order was incorrectly treated as namespace identity by a native replay test. It selects the namespace explicitly and verifies replay from emitted bytes.
3. Generated records had runtime constructors but lacked Elixir compile-time struct metadata. Canonical `__info__` clauses now support literals/patterns and invalidate metadata fingerprints on redefinition.
4. Explicit `Elixir.` module prefixes were doubled. Module identity normalization is shared with slash resolution and still capability-gated.
5. Consumer compiler tasks copied bootstrap namespaces into the consuming app directory, shadowing the dependency compiler. The compiler floor now belongs to the beam_lisp dependency's artifact directory.
6. Spell called nonexistent `File.realpath/1`; it now reuses the companion's guarded workspace validation. Tuple-valued verifier failures are serialized as diagnostics rather than crashing JSON encoding.
7. The companion relied on an undeclared Jason dependency. It uses the JSON module supported by the project's Elixir baseline.
8. `clojure.set` relied on ambient installation of variadic `conj`. Its namespace explicitly requires and refers the compatibility operation; vendored function bodies remain unchanged. A regression resets the core root to the native fixed-arity function and verifies variadic union.

## Resource evidence and limits

All risky gates run asynchronously in named systemd scopes. Observed peaks: full order-stable suite 850M; explicit uncached build 615.8M; independent seed rebuild 521.6M; real MCP lifecycle 204M; documentation 144.1M. These runs have no OOM indication and leave no listed plan09 scopes. Limits are containment, not filesystem/network isolation.

The example corpus retains nine documented interactive/environment skips: desktop windows, long-running servers, unavailable Bandit, a live embeddings API key, nested ward use, a global-authority teaching example, and the compiler-wide impact-query example. Spell's separate external Spacetime/verse rendering rungs are not claimed verified; that external binary is unavailable under its configured legacy path. None of the 18 MCP tests is presented as proof of those rendering rungs.

Deferred user-approved work remains outside this convergence plan: PLAN-087 SIMD probing, native-memory JIT/defnative work, and PLAN-042.

## Milestones

- `7d1571b`: guarded Org editing host and documents.
- `3f0db2d`: canonical generated-module emitter cutover.
- `fba3291`: eager compiler traversal and canonical corpus oracles.
- `d785007`: integrated native shared lazy ownership.
- Spell `8baa5f0`: selectively committed Loop/MCP editing integration.

Final compiler/seed/documentation commit follows this verification record. Unrelated project, journal, and concurrent plan files are preserved rather than swept into the milestone.
