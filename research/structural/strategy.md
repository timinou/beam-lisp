# Structural efficiency: production implementation strategy

This is the final strategy from the five executable spikes. It is not a claim that the prototypes have already changed Beam Lisp defaults or made Knowledger faster. The branch contains research modules/tests/notes only. `results.json` is the canonical measured record; README names exact verification commands and evidence.

## Decision

Promote four mechanisms after their production integration obligations are discharged: dependency-certified projections, admitted ordered/authorized reads, checked private-consumer fusion, and realm-local AOT. **Do not ship the additional lookup-cache wrapper:** it reduced generic refreshes from 4,000 to one but took 3.09–3.39 times more reductions than the already-memoized authoritative Env path. Reuse its parity/model tests while improving that existing path.

“Impossible by design” means **an inadmissible operation cannot enter the optimized/bounded path**. It does not mean all arbitrary programs or all queries can be fast. Exact counting, common-term search, unknown effects, arbitrary providers and historical reads can intrinsically require more work. The API must preserve an authoritative fallback or return an explicit refusal/incomplete result, never silently substitute a stale, partial or unauthorized answer.

A model theorem is not a production certificate. These spikes combine finite exhaustive `veritas` checks, explicit SMT obligations and actual runtime differential/counter tests. The finite bounds and trusted declaration/epoch assumptions are recorded in the individual notes and results. Unknown solver outcomes are not proofs. Huge finite Cartesian generators are not symbolic proofs: the initial experiment exposed this mistake; symbolic integer obligations now go directly through `smt`/`z3` rather than accidentally allocating/enumerating enormous domains. Production proof/check APIs also need admission before enumeration.

## 1. Shared foundations: make dependencies and stamps authoritative

### Targets

- `priv/lib/datom/db.bl`, `attr-basis.bl`, `derived.bl`, `watch.bl`, query relation/planner/engine.
- `priv/host/env.bl`, and its namespace/provider initialization and purge callers.
- Existing canonical `system.ir`, `system.footprint`, optimizer fact/law/refusal machinery. No competing analyzer or cache registry.

### Contracts

A projection's reusable answer is a value plus a certificate containing store identity, input/plan identity, the data snapshots used, semantic read dependencies, provider/schema/definition generations and exact expiration. Store identity must be an actual identity, not a short hash that can alias another store. Reads that return no rows still record a dependency. Time/basis observations, raw/escaping db values, unsupported providers and foreign effects broaden or invalidate the certificate.

Do not accept a caller's attribute subset as evidence that an arbitrary function reads only those attributes. First support a **closed generated read-plan domain**, where execution and footprint share one representation. The spike's generated column projection is such a domain; its standalone declaration capture is not automatic proof of arbitrary code. Extend actual datom read-funnel instrumentation and existing provider contracts, conservatively treating unknowns as whole-world dependencies. Compiler proof can extend coverage through the existing IR, not a second walker.

Pin each input store value. Capture stamps consistently before/after construction; do not stamp historical rows with latest-store marks. Historical/since/valid-time views need their own value-keyed semantics or uncached fallback. Cross-store projections must bind every store/policy input: a library basis alone is insufficient for rights from the control and sync stores. Historical *content* must not automatically grant historical *permissions*.

A live lookup guard is valid only if **every completed relevant mutation changes its stamp**. BUG-115 is the observed prerequisite: `Env.match_delete_own` removes a binding without advancing the epoch; in a disposable environment both the existing cached fetch and new wrapper returned their prior binding while exact lookup found the row missing. Audit all bulk/direct mutations and their callers; some higher-level callers may already issue a subsequent bump. Establish one mutation/stamp primitive with a documented linearization point, not independent epoch bumps scattered through APIs. Include env-chain switches, provider initialization, definition replacement and generation/reference resets; make ABA/code-generation assumptions explicit.

### Gates

Empty-read insertion, changed projection plan, same transaction numbers across different stores, nested ACL expiry, relevant/unrelated updates, schema/provider change, historical/racing capture and permission revocation. Mutation-family tests must include bulk deletion, provider init, errors, chain switching, midfold/predicate/terminal rebinding. A missed event must invalidate, not quietly authorize a hit.

## 2. Dependency-certified projections and live rendering

### Integration

Expose one datom projection/memo facility built on attribute marks and derived artifacts; move application `basis-memo` behavior into that affordance, then cut callers over and remove redundant storage logic. Cache independent columns, build ID indexes once and assemble against pinned snapshots. Apply first to Knowledger Knowledge, mirrored source access, library/count projections, Needs and Team/grants. Request-local reuse should share expensive search/access derivations without requiring cross-request caching.

For `live.socket`, certificate-aware relevance must replace the current unconditional policy only for admitted views. The spike proves why checking just the **last** commit in a burst is unsafe. Production state needs a sticky dirty flag/union of relevant commit dependencies until a successful render/flush, not a mailbox peek that forgets earlier relevance. Unknown payloads/certificates force rendering. Preserve detach/attach, navigate/assign, CSS shipping and event-order behavior. Specify a bounded flush/fairness policy so continuous ingest cannot indefinitely suppress the final render.

Exact expiration requires a scheduled invalidation/deadline when appropriate, not merely detecting expiry if another commit happens. Cached answers used for new operations must always revalidate their policy interval.

### Production proof boundary

The current spike is single-store with explicit supported read descriptors; general provider/cross-store composition and actual socket wiring are not implemented. Expand the state model to the real actor protocol before replacing `listen-options`' conservative refusal. Keep that refusal until a trustworthy complete certificate exists.

### Acceptance

An unrelated write reads zero projection rows; a relevant write updates only dependent projections; a relevant commit followed by irrelevant commits still flushes. Revocation/expiry without a library write cannot reuse a permissive result. Measure per-socket render counts and click latency during ingestion, not only per-render reductions.

## 3. Admitted data work: authorized ranking, pages and counts

### Integration

Use existing `PageScan`, `Count`, `MultiScan`, `pull-many`, relation joins and derived/reconciliation infrastructure. Add a typed execution result (`exact`, `refused`, `incomplete`) and an internal work-budget/capability contract. A request promising a bound must prove the substrate and access path can honor it **before materialization**. Count admission measures physical key work, not logical user-visible totals.

The spike demonstrates an indexed posting restriction, an ordered single-term rank projection, real Fjall paging, and safe Count admission on ETS. General multikey scoring still reads/sorts all matching postings. To bound that case, maintain ordered contribution streams and use a checked upper-bound/threshold merge, or refuse it under a insufficient budget. Do not relabel candidate restriction as page-bounded work. Common terms and sparse permissions still have meaningful worst cases.

Apply authorization while selecting/ranking candidates, not after a fixed `6*k` global window. The negative control shows that window can miss allowed matches. Production must bind the current permission descriptor (control/sync revisions, principal, mode, expiration), not merely the library snapshot. Native/vector search requires a corresponding filtered-candidate capability or an explicitly bounded fallback. Do not weaken egress authorization or retention policy to gain throughput.

Cursor identity includes store, pinned data value, query/plan/order version, principal and **permission context**, not just an entity/score or raw key. Reject mismatched cursors. A physical page's final key cannot skip unexamined hit candidates; an incomplete retry must retain accumulated state or restart the original ranking position. The spike uses restart-on-retry. It bounds raw page size by remaining hit slots to avoid losing rows from a fetched page.

Retraction visibility needs a complete semantic scope: filtering one physical page alone can split assertion/retraction pairs and resurrect data. The spike resolves membership against complete EAVT rank reads. Production should reuse/extend the canonical read funnel with pairing state/current-value materialization, while accounting for the additional point/history reads. A two-row rank scan is not a proof of two total database reads or a CPU/byte bound.

A rank index is a maintained projection, not a one-off initializer. Validate/update it atomically or version it and refuse stale generations. The fixture's fixed-width string encoding is deliberately bounded and rejects overflow; production should use a typed composite order codec and prove encoding/order equivalence, not adopt the hand-coded width blindly. Term prefixes must not alias. Keep work counters internal: exposing denied-candidate counts can leak information even when hits are filtered.

Counts must describe the same authorized/live set as lists at the same snapshots; page length is not a total. Uncomputed totals remain absent, not fabricated zeroes.

### Acceptance

Native paging exercised; candidate work independent of unrelated corpus; sparse ACL top-k parity; no skipped/duplicated pages; split retraction boundaries; cursor/policy invalidation; stale index refusal; exact totals; unknown-capability/budget refusal before a wide fallback. Measure rows, seeks, decoded bytes, native work and memory separately.

## 4. Checked private-consumer fusion

### Integration

Add a `strict-first-filter` checked law beside `strict-map-fold` in `priv/host/optimize.bl`; reuse the existing `system.ir` self-scaffold recognition, canonical facts and footprint/refusal vocabulary. Boot facade/lowering remains the single shared hook. The research adapter's declared `resolved?` flag must **not** become a production certificate.

Admission requires exact callee/definition identity, stable binding, private ownership, materialized source, and a total effect-free predicate over a proved domain. A pure predicate alone does not permit changing effects or demand in an unknown lazy source. Purity also does not imply totality: strict Erlang not/and/or can raise on a non-boolean tail after a valid first match, so the adapter refuses those primitives without a boolean operand proof. On failed/unknown proofs leave the original lazy spelling untouched. Respect callback/output-node/compile-time budgets and never replay an effected prefix after a guard fails.

Lower to the existing halting kernel fold. Return the original matching element: `some` returns a selector result and loses a matched false with the tempting `when` transformation. A matched nil must also halt even though the final value equals the no-match result. Predicate chunk overscan is observable when callbacks effect/throw, so the negative cases remain refused.

Resource/cycle/admission behavior is a separate obligation from result algebra. Do not omit dependency walks because captures look like plain data. Compiler capture summaries must prove reachability and preserve memo cycle edges; no capture-descriptor or general lazy-engine cutover is implemented here. The current closed literal/range experiment proves no general shared/escaping lazy-value optimization.

### Acceptance

On/off parity for values, raised-ness, forcing/callback prefixes, false/nil, shadowing/rebinding, source effects, shared/escaping values, resource/failure behavior and budgets. Inspect generated work and compile/output size. The measured fixture saved 17.39 times caller reductions; do not extrapolate that ratio to Knowledger until real admission coverage and a render measurement exist.

## 5. Realm-local AOT (FUP-155 first step)

### Integration

- `aot_cache.bl`: address by compiler key, resolved closure (including macro/provider dependencies), and realm segment.
- `aot.bl`: compile/publish/replay into the **target env**, not hard-coded global.
- `loader.bl`: admitted local homes select `aot-realm`, preserving existing authoritative source fallback.
- Realm manager owns unique active segments, initialization generation, loaded module inventory and close/purge lifecycle.

The adapter compiled real BEAM artifacts and reused existing cache hashing/store/fetch/init operations. It refuses compiler/closure changes inside an open generation, prevents two independent owners of one live segment and restores the namespace marker on replay. Initialization is once per exact compiler/entry/open generation. Delete current code before purging old code; protect real leases and active users in production rather than force-purge shared modules.

First ship per-segment content addressing; cross-realm canonical relocation is deferred. Account for the env's resolved shadow/uses closure, not global dependency lookup. Arbitrary compile-time macro effects or ambient config are not validated by the literal descriptor fixture; hash their actual dependencies or refuse cache admission. Verify atomic publication and module identity as well as manifest digests; the current fixture covers ordinary corruption/partial publication, not hostile coordinated rewrites.

The real manager must serialize/reserve concurrent loads and recover initialization failure. Bound retained entries/modules and realm identities; purging code does not reclaim Erlang atoms. The fixture's reopening/name stability does not prove arbitrary project churn has bounded atom growth.

### Acceptance

Full real namespace load in two realms, edited shadow/provider/compiler invalidation, per-env effect-once initialization, missing/corrupt cache fallback, failed/concurrent initialization, close/reopen, shared leases, module/atom/cache growth, and cold/warm project startup. Keep startup gains separate from warm UI latency.

## Delivery order

1. **Foundations:** close the epoch mutation invariant; establish generated read certificates, exact policy validity and admitted work results. Add proof-engine exploration/resource admission before large generator products.
2. **Knowledger-facing data/projections:** mirrored-rights batching, incremental Knowledge/Needs/library/Team projections, ordered pages/counts and a maintained local lexical index. Reuse existing affordances and cut over rather than accumulating parallel app caches.
3. **Live relevance:** integrate only certified views; expand/check the actor/flush model first. This compounds saved work across sockets.
4. **Compiler fusion:** implement the small checked domain in the central pass, then expand from observed coverage/refusals.
5. **Realm AOT in parallel:** startup/DX track with independent loader/isolation gates.
6. **Lookup implementation:** optimize the existing Env/kernel fast path with an internal guarded tuple/closure or generated code after mutation coverage is sound; retain baseline if matched reductions do not improve. Do not promote this extra cache layer.

Before production integration, rebase from the pinned research base onto current main and re-run the focused gates, then rebuild the toolchain coherently if host/boot changes land. New application baselines must include searching/empty frames, product/mirror rights, relevant/unrelated commits, Team and active ingestion. Record CPU reductions plus native/provider work, bytes/memory and browser click-to-patch latency. No current Knowledger render speedup or deployment equivalence is established by this research branch.
