# Finding 8 repairs — all-clause `system.analyze` and domain-preserving Veritas shrink

Scope: `performance-review.md` §8 ("P2: the native logic analyses have coverage
limits that cannot justify a clean performance bill"), PLAN-154 cluster **F**.
Two production files, two new tests, this artifact. No global build, no seed,
no native compilation, no org/memory housekeeping. Uncommitted foundation
changes elsewhere were left untouched.

Status: production change + tests written; **not executed by this worker** (see
"Verification" — worker ran reader/static checks only, by instruction). Live
native BL runs are the orchestrator's gate.

---

## 1. Observed defects (evidence, from the review)

**a. `system.analyze` parsed only the first clause of a `defn`.**

`priv/lib/system/analyze.bl` `fn-bodies` did:

```clojure
parsed (nth (typed/defn-clauses items) 2)
c0 (first parsed)          ; <-- ONE clause
```

Executed counterexample from the review:

```clojure
(defn overloaded ([x] x) ([x y] (File/read! x)))
```

`system.analyze` returned an empty call set, an empty footprint and
`terminates true`: the second clause's `File/read!` was never compiled into the
analysis. Its docstring even claimed the opposite ("Multi-clause and
higher-arity are summarized on their last clause body"), which the code did not
honour. This is not adequate as whole-host assurance after a multi-arity ABI
migration. Same first-clause-only shape existed in `system.model`,
`veritas.property`, `system.smt` (out of scope here; noted in §6).

**b. Veritas shrinking left the supplied generator's domain.**

`priv/lib/veritas.bl` `shrink-fail` branched only on tuple shape:

```clojure
(defn- shrink-fail [gen fail? v]
  (if (= :tuple (gen-tag gen)) (shrink-coords fail? v) (shrink fail? v 200)))
```

and both branches used the value-directed ladder (`shrink-candidates`, "walk
toward 0"), which is generator-blind. The review observed, with finite
enumeration over `one-of 1 31 32 33`:

- `:witness 1` — the valid, violating counterexample;
- `:shrunk 0` — **outside the supplied set**, i.e. not a counterexample of the
  query that was asked.

## 2. Changes

### 2.1 `priv/lib/system/analyze.bl`

- `ns`: add `[system.footprint :as fp]` (already a dependency of
  `system.summary`; no new cycle).
- New `clause-body` — compiles one parsed clause `(fn [params] body…)` and
  peels it back to `{:params [names] :body anf}`. Carries the existing
  peel-miss `throw` (BUG-054 guard) so a vacuous body still fails loud.
- `fn-bodies` now maps `clause-body` over **every** parsed clause
  (`(nth (typed/defn-clauses items) 2)`) and returns
  `{name → {:params :body :clauses [{:params :body} …]}}`. `:params`/`:body`
  are the **first clause**, kept verbatim for the two existing consumers that
  read a single body (`system.incr` body hashing, `system.linear` walkers) —
  no interface change for them.
- New private helpers:
  - `all-bodies` — every clause body (or the single `:body` for `<top>`);
  - `params-for` — the param names of the clause whose arity matches the call's
    actual count (multi-arity 0-CFA binding), else the primary params;
  - `join-summaries` — union of two clause summaries: `:footprint` via
    `fp/join-fp` (mode lattice), `:terminates` by **conjunction** (a fn halts
    only if every clause halts), `:returns`/`:calls` by set union;
  - `summarize-all` — reduce `join-summaries` over `all-bodies`.
- `flow-facts` folds `flow-step` over **all** clause bodies of every fn.
- `flow-step` binds a callee's actuals against `(params-for gdef (count
  actuals))` instead of the first clause's params.
- `analyze`'s fixpoint now summarises with `summarize-all returns fp-resolve d`.

Soundness direction: every union is monotone over-approximation. A later
arity's calls/effects can only **grow** a summary; a missing clause can never
read as an absence. `terminates false` in any clause makes the fn
non-terminating (the honest, conservative direction).

### 2.2 `priv/lib/veritas.bl`

- New optional protocol `GenShrink` (`gen-domain?`, `gen-shrink`) — the
  generator's *domain* half, implemented beside each `Gen` rung. The
  codebase's own idiom for an optional protocol capability (`datom.blob`'s
  `BlobStream`/`BlobUrl` + `satisfies?`) rather than a second shrink engine.
- `value-size`/`sized-smaller?` — a coarse order for `one-of` members, whose
  domain has no numeric ladder. Equal sizes are never "simpler", so a walk over
  them terminates.
- `in-domain?` / `gen-candidates` — dispatch through `satisfies?`; a `Gen` with
  no `GenShrink` admits everything and falls back to the plain ladder (honest
  for an unknown domain).
- One `extend-type … GenShrink` per rung:
  | rung | `gen-domain?` | `gen-shrink` |
  |---|---|---|
  | `IntGen` | int within `[lo,hi]` | ladder filtered to bounds |
  | `RealGen` | number within `[lo,hi]` | `{0.0, lo, v/2}` filtered, strictly smaller |
  | `BoolGen` | `true`/`false` | none (already minimal) |
  | `AnyGen` | universal | plain ladder |
  | `OneOf` | member of `:values` | set members strictly smaller by `value-size` |
  | `StringGen` | prefix honoured, length in `[minlen,maxlen]` | ladder filtered to prefix+length domain |
  | `EnumGen` | keyword tag, or `{tag payload}` with one known tag | ladder filtered to the tag set |
  | `CollGen` | vector with length in `[minlen,maxlen]` | ladder filtered to the length domain |
  | `TupleGen` | vector of child arity, each coord in its child | coordinate-wise, arity kept, per-child domain |
- `shrink-fail` now walks `gen-candidates` (domain-preserving) instead of
  branching on tuple shape; `shrink-coords` was deleted (single-implementation
  cutover — it had no other caller in the repo).
- `shrink` and `shrink-candidates` are unchanged and remain the public
  generator-blind ladder for `veritas.property` / `veritas.model`.
- `run-sample` is unchanged: it still returns both `:witness` (the original,
  always preserved) and `:shrunk`.

**Why `:shrunk` is now domain-valid and still a counterexample.** The walk
starts at `cex` (in-domain: it was sampled/enumerated from the gen, and
`fails?` holds). Each accepted step is a `gen-shrink` candidate — in-domain and
strictly simpler by construction — gated by `fails?`. So the fixed point is in
the domain and violating. Termination needs no fuel guarantee because every
candidate is strictly simpler.

## 3. Acceptance mapping

| requirement | where |
|---|---|
| later-arity I/O not omitted | `fn-bodies`/`clause-body` over all clauses; `summarize-all` union |
| all clauses contribute call/effect/termination | `join-summaries` (`fp/join-fp`, `and`, `into`) |
| unknown/coverage explicit, no false absence | union is monotone (grow-only); unresolved calls stay `:opaque-world`/`any` exactly as before |
| `witness 1` from `one-of 1 31 32 33` never `:shrunk 0` | `OneOf` `gen-domain?`/`gen-shrink` |
| numeric negative/positive bounds | `IntGen`/`RealGen` domain = `[lo,hi]` |
| shaped tuples/collections | `TupleGen` per-child, `CollGen` length bounds |
| original witness preserved | `run-sample` unchanged; `:witness` still emitted beside `:shrunk` |
| existing return fields preserved | verdict keys, `fn-bodies` `:params`/`:body`, `shrink`/`shrink-candidates` untouched |

## 4. Tests added

- `test/bl/system/analyze_multi_arity_test.bl` (`system.analyze-multi-arity-test`)
  - `later-arity-io-is-not-omitted` — the review's exact counterexample: the
    second clause's `[:Elixir.File :read!]` is in `:calls`, `:footprint`
    non-empty, `:terminates true`.
  - `first-clause-effects-are-kept-too` — union, not replacement: clause 1's
    `"acc"` resource survives clause 2's `File/write!`.
  - `later-arity-call-edge-is-recorded` — a call only in the second clause
    becomes an `:edges` entry.
  - `returns-union-across-clauses` — `([x] 1) ([x y] "s")` returns `#{:int
    :string}`, never narrowed to one clause.
  - `recursive-overloaded-still-summarized` — recursive overloaded fn
    terminates and self-call is an edge.
  - `docstring-does-not-shift-clause-parsing` — docstring before the clauses
    does not hide the later arity.
- `test/bl/veritas/shrink_domain_test.bl` (`veritas.shrink-domain-test`)
  - `one-of-shrink-stays-in-the-set` — `:witness 1` preserved, `:shrunk` a set
    member, `≠ 0`.
  - `one-of-shrink-walks-to-a-smaller-member` — sample order `31 1 32 33`
    shrinks to the smaller member `1`.
  - `int-shrink-respects-its-bounds` — `int-of 50 100000`, `:shrunk ∈ [50,
    100000]`.
  - `tuple-shrink-stays-in-child-domains` — arity kept, each coordinate in its
    child's `[0,9]`.
  - `coll-shrink-keeps-its-length-bounds` — `coll-of 2 6`, length in `[2,6]`,
    the failing element still present.

Predicates use `includes?`/`str` on purpose: outside the SMT fragment, so the
query takes the enumerate/sample+shrink rung the finding was observed on (a
translatable predicate would be answered symbolically, which emits no
`:shrunk`).

## 5. Verification

**Run by this worker (allowed reader/static checks only):**

- Token-level balance check (comments and string literals skipped) over all
  four touched `.bl` files — all balanced.
- Grep audit: `shrink-coords` has zero remaining references; `GenShrink`
  implementations cover all nine generator records
  (`IntGen RealGen BoolGen AnyGen OneOf StringGen EnumGen CollGen TupleGen`).
- `find` outline of both production files after edit — structure intact.

**Not run by this worker (orchestrator gate):** no VM was started, so no
runtime proof of the two fixes exists in this artifact. The warm harness MCP
(`beam-lisp-harness/eval`) was unreachable (`Unable to connect`).

**Exact commands for the orchestrator** (bounded, fresh VM; worker did not run
these — they may trigger image repair/compile and are the orchestrator's call):

```sh
# focused, the two new suites
bin/bl test test/bl/system/analyze_multi_arity_test.bl test/bl/veritas/shrink_domain_test.bl

# the pre-existing suites that share these surfaces (regression)
bin/bl test test/bl/system/analyze_test.bl test/bl/veritas
bin/bl test test/bl/system
```

Under a memory-bounded scope as the review used:

```sh
systemd-run --user --scope --collect -p MemoryMax=4G -p MemorySwapMax=1G \
  env ELIXIR_ERL_OPTIONS='+S 8:8 +SDio 8' \
  bin/bl test test/bl/system/analyze_multi_arity_test.bl test/bl/veritas/shrink_domain_test.bl
```

**Expected observations (falsifiable):**

- `(an/analyze "(defn overloaded ([x] x) ([x y] (File/read! x)))")` →
  `"overloaded"` has `[:Elixir.File :read!] ∈ :calls`, non-empty `:footprint`,
  `:terminates true`.
- `(v/for-all port "n" (v/one-of 1 31 32 33) '(not (includes? (str n) "1")))`
  → `:refuted`, `:witness 1`, `:shrunk ∈ {1 31 32 33}` and `≠ 0`.

**Regression risk to watch:**

- `test/bl/veritas/shrink_test.bl`, `theories_test.bl`, `ledger_test.bl`,
  `tuple_positional_test.bl` exercise `for-all`. Shrink results for bounded
  generators are now *different values* (in-domain instead of past-the-edge);
  `shrink_test`'s `tuple-witness-keeps-its-arity` asserts only arity, and the
  others assert modality/witness, not `:shrunk` values — but this is the band to
  re-run first.
- `system.incr` / `system.linear` read `fn-bodies` `:body`; it is still the
  first clause, so their behaviour is byte-identical. The later clauses remain
  invisible to those two (pre-existing; see §6).

## 6. Honest remaining precision limits

These were **not** fixed and must not be read as covered:

1. **`system.incr` / `system.linear` are still first-clause-only.** They
   consume `fn-bodies`'s `:body` (first clause). A multi-arity fn's later
   clauses do not invalidate its incremental summary or feed linearity
   placement. The fix is to iterate `:clauses` there too; those files were
   outside this task's scope.
2. **`veritas.property`'s own shrink is still generator-blind.**
   `priv/lib/veritas/property.bl` `shrink`/`smaller` use `v/shrink-candidates`
   (no generator in scope). `v/hypothesis` over `int-of 5 100` can therefore
   still shrink below `lo`. The extension point is `GenShrink`
   (`gen-domain?`/`gen-shrink`, currently private to `veritas.bl`); adopting it
   in `property.bl` requires threading `gen` into its `shrink` and is a
   follow-up file change.
3. **`system.model`, `system.smt`, `lsp`, `lsp.rpc` also read only the first
   clause** (`(nth (typed/defn-clauses …) 2)` then `first`). Same class of
   finding-8 bug on other surfaces; out of scope here.
4. **Indexing by function-and-arity is only partial.** The union gives the
   *function* one summary; `flow-step` picks the matching-arity clause's params
   for 0-CFA binding, but summaries are not keyed per arity, so a caller never
   sees "which arity" in the result. That is the review's stronger suggestion
   ("index summaries by function-and-arity and propagate their union at
   callers") and remains future work.
5. **Foreign/host/NIF effect and loop-cost precision is unchanged.** The
   analyzer still over-approximates unknown host ops as `:opaque-world`/`any`
   and has no interprocedural loop-cost facts; helper-mediated and foreign
   `Enum` iteration still report syntactic (zero) loop depth. Nothing here
   claims otherwise.
6. **Symbolic-rung verdicts carry no `:shrunk`.** Trivially-safe (no bad
   shrink) but also no domain-validated minimal witness on the z3 path; z3's
   model is projected through `project-witness` and is in-domain by
   construction.
7. **`CollGen`'s element domain is length-only** (the symbolic rung abstracts a
   collection to its length), so element-wise shrinking is unconstrained beyond
   the length bounds — consistent with the existing generator's own contract.

## 7. Scope / risk

- Files written: `priv/lib/system/analyze.bl`, `priv/lib/veritas.bl`,
  `test/bl/system/analyze_multi_arity_test.bl`,
  `test/bl/veritas/shrink_domain_test.bl`, this artifact. Nothing else touched;
  the uncommitted foundation edits (`priv/build`, `priv/host`, etc.) are
  untouched.
- Deleted public symbol: `veritas/shrink-coords` (no in-repo callers; superseded
  by `TupleGen`'s `gen-shrink`). If a source-free external caller holds it, this
  is the one ABI surface that shrank — flagging it explicitly.
- No new dependency, no build-system change, no seed/AOT/codegen change. The
  `GenShrink` protocol is new but additive (a `Gen` without it still works).
- Linked org item: `PLAN-154-complete-clustered-performance-repairs-w`
  (lineage only, non-gating).
