# Checked optimizer + BEAM-backed namespace definitions

## Integration

The requested `ns-defs-beam` branch (tip `6c077732`) is integrated with the default strict lexical fusion in `optimize-2` (`1c4208b7`). Namespace source changes are in `priv/host/aot.bl`, `env.bl` and `link.bl`; the current main `callers_of` correction (`maps/remove`) is preserved. The merge favors the current floor during conflicts; the branch's old96-beam seed, including its automatic Rt-init deletion, is not accepted as combined-generation authority. The complete verified promotion floor is retained through the official seed writer during bootstrap, then replaced by the newly built combined generation. No hand-edited manifest or mixture of branch binaries authorizes the result.

AOT shims export `__bl_ns_defs__/0` returning a shared literal. Env stores `{$beam, Module}` and resolves it at lookup, while source/live edits use whole-map snapshots. Link materializes every environment reference before replacing a shim; overlays and inherited removals remain local. This is representation/storage optimization, not permission to freeze a live helper or derive proof from its name/signature.

## Verified cold initializer repair

Independent source review247 identified a concrete ordering risk; a retained cold test reproduces it. Compile a namespace whose value initializer defines `late` in the same namespace, retain the writer's exact BEAM module identities, clear its environment bindings, purge/reload those artifacts, and replay initialization once. Under the branch ordering the canonical `alpha` declaration and the new `late` disappear, the table becomes a dangling reference, and `alpha/1` is undefined (3failed assertions/1error).

The repair links canonical declarations after existing namespace/native/function replay and before value initializers. Live self-definition can then materialize the complete table before shim replacement. No relink after user replay overwrites the overlay. Initializer order and final `mark_loaded` remain unchanged. The exact regression now passes, along with parent/child/sibling reference materialization, unchanged map overlays, undefine/empty shadowing, callers lookup, source-loaded maps and missing-export fallback:13tests/55assertions. Original6tests are retained; seven lifecycle tests are added. Source-only reviewer249 accepted the repair (confidence0.95).

## Combined generation acceptance

- Official full keyed build:317sources compiled, errors[], native errors[]. Source-free inventory remains repository-authored `.bl`/literate source; no authored `.ex`/`.exs` is introduced.
- Official seed:97modules /67pinned hosts /12boot namespaces; errors[], oktrue.
- Compiler key: `4a49e648b36416fc95f66451e600ff00e5082f2fd92482630bdd1a6ebf8cb03d`.
- Build key: `42dfc0c941c7463dcd13a530a7606446f81c98585d88b683793e4ecb49dd3876`.
- Strict fresh VM: zero previous-generation staging exemptions; reports optimize-2/arithmetic3/strict-fold992/currentkey. Combined22-file bundle:203tests /4216assertions /0failures /0errors. Covers namespace tables, Link/Env/forks/callers/memo, cold shims, incremental AOT and protocol replay, host helpers, cache/drift, all optimizer/open-world/mode/law/call-shape/pinned-lowering/reduction tests.
- The earlier mixed pre-build generation failed46assertions in that same203-test bundle. Most were child VMs falling back to source with an uninitialized compiler (`compiler/special-forms`); coherent combined floor installation removes those failures. A preserved host-helper literal expectation additionally needed the existing `:require_specs` field to match current require intent; the fixture now asserts the exact alias/refer/bare specification instead of omitting it.
- The accepted floor is written by the official writer into the merged checkout. A separate checkout-root strict cold smoke verifies its actual root/source configuration:44tests/560assertions,0failures/0errors, same compiler key and zero staging exemptions.

These are targeted integration/build/cold gates, not whole-repository green. No regenerated self-extracting package is published or claimed accepted.

## Observed storage and coverage

`optimizer-coverage-scan.bl` reads each actual namespace definition table once, groups executable ANF clauses by their real body module, and calls the central `optimize/explain` with a100000node budget. It never publishes transformed descriptors or authorizes rewrites. Six representative namespaces:compiler/core/rt/build/system.analyze/datom.index,884definitions, no scan limited.

Each namespace stores a24-byte flat-size reference payload. Their tables' flat-size byte counts sum to5,946,944; the six reference payloads sum to144bytes. Keys/ETS overhead, literal storage, code memory and total RSS are not included: this demonstrates the stored representation, not a whole-VM memory-saving figure or timed lookup claim. Branch historical lookup/ETS measurements are not substituted for this generation's observations.

Central diagnostic counts across those original stored ANF bodies:

| Verdict | Count |
|---|---:|
| Applied native-call rules |46|
| Unknown or mismatched native arity refusals |666|
| Live-provider or observable lazy-demand refusals |86|
| Unproven strict domain/callback refusals |2|

No strict fusion is recognized in these six inspected bodies. The ordinary-source150sample promotion harness establishes profitable eligible fusion, but not namespace-wide benefit. Counts describe candidates/refusals, not dynamic call frequency or proven hidden optimization opportunities. Some mismatches are intentional and must remain baseline.

## Further optimization priorities

1. **Bounded callable-shape flow and numeric-domain propagation.** Inspect the666native-arity refusals, profile actual hot callers, and propagate internally checked local/argument facts where a native-call law already exists. Representation/arity does not establish purity, arithmetic identity or helper-body stability. Keep ordered packed arguments and unknown/mismatched fallback; helper-dependent facts need body-change validity/invalidation.
2. **Public reduction/provider costs.** Profile the86live-provider/lazy barriers and the measured public `+`/compatibility paths. Preserve live `reduced?` and binding reads before/mid/terminal; optimize their lookup mechanics or prove exact captured callable identity, not removal of required observations. Any midstream fallback continues the current suffix; it never replays an effected prefix.
3. **Immutable scalar captures and binder-aware use/escape facts.** These widen ordinary-source strict fusion without immediately requiring a shared-lazy theorem. Definition-time capture identity, supported integer domains, evaluation order, shadowing and bounded analysis are prerequisites.
4. **Strict map chains and filter/fold.** Add per-stage totality/domain/order laws and counterexample tests after the preceding facts. Preserve noncommutative reducers and callback frequency. No floating-point reassociation or blanket purity tags.
5. **Live namespace overlay costs.** Profile editor/reload workloads after shared literal tables; consider point lookup/batching or sparse snapshots only with tombstones, explicit-empty inheritance, immutable generation backing and bounded lifetime/reclamation. Do not make a delta follow a mutable module reference.
6. **Indexed/transducer/lazy/resource domains.** Keep experimental until index/demand/init/complete/halt/output/metadata and sharing/replay/publication/retry/quota/concurrency contracts are explicit and verified. Formula elimination, scalar replacement and offload need their own laws and a real profile.

The failed generic-wrapper hoisting approach stays experimental: bytecode guard removal did not materially reduce native work and wrapping added generic work. Further effort needs a different mechanism and positive matched-work evidence, not more optimistic labels.

Every deferred domain has rationale, concrete failure modes, integration homes, dependencies and revisit/promotion gates in `research/optimizer-integration/README.md` (§5.1–5.10). Current behavior is taught in `docs/compiler/optimizer.bl.md` and `docs/namespace-loading.md`. Prior prototype and promotion records retain their own generations. All uncertain programs keep the baseline path; wider automatic optimization means more provable eligibility, not a promise to speed up every program.
