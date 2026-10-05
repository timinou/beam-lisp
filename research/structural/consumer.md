> **Final verified record:** 88 assurance assertions plus the shared metrics gate passed. For 200 runs of the declared literal/range fixture, total caller reductions were 1,289,037 baseline versus 74,146 lowered (17.39x). Both values are 4; false/nil and effect/demand negative controls are checked. This is a declared closed-domain adapter using existing IR/footprint/lowering, not a shipped central optimizer law or a proof of live callee identity. Earlier Reader API-drift speculation was wrong: a test passed an already-compiled node to a source-string helper; the diagnostic confirmed read_one accepts source strings.
>
> See [results.json](results.json), [strategy.md](strategy.md), and [README](README.md). Source-only authoring expectations below are historical and superseded by this final record where they disagree.


# Spike: a consumer lowering `(first (filter pred coll))` to the existing halting fold

Status: **research prototype. UNRUN.** Every execution result below is a
prediction from source inspection; the orchestrator runs one capped VM and
replaces the UNRUN markers with observed values. Nothing here is a production
cutover claim, and nothing is wired into the compiler.

This revision repairs the first draft against the compiler's ACTUAL output:
the predicate operand is the self-application scaffold (not a bare `:fn`, so
`fn-value-node` unwraps it via `system.ir`); `(lists/seq i j)` is admitted only
for `i =< j` (a backwards range raises and is refused as
`:collection-range-not-total`); and the test reads sources through the
self-hosted reader's own `BeamLisp.Ns.Reader/read_string` + `first` (the host
`read_one/1` facade raised a `FunctionClauseError` on a binary source against
the staged seed); and `consumer/report` is the exported orchestrator entry for
the admission/negative-witness/metrics run.

Files:

- `research/structural/consumer.bl` — ns `research.structural.consumer`
- `research/structural/consumer_test.bl` — ns `research.structural.consumer-test`

Proposed exact test command (the batch runs all five spikes in one capped VM;
this file is the consumer entry):

```sh
systemd-run --user --collect --wait --pipe --working-directory="$PWD" \
  --setenv=BL_DAEMON=off \
  --property=MemoryMax=8G --property=MemorySwapMax=2G \
  --property=RuntimeMaxSec=1200 \
  ./bin/bl --cold test -p . research/structural/consumer_test.bl
```

(In isolation, `./bin/bl --cold test -p . research/structural/consumer_test.bl`
is the same run without the memory cap; do not loop it — one cold VM is
~150–400 MB. Never stop unrelated VMs.)

---

## 1. The mechanism and the closed declared domain

`(first (filter pred coll))` is evaluated through the chunked lazy engine. One
`first` forces one `filter` cell, and `lazy-filter-realise` / `filter-chunk`
(priv/boot/rt.bl) scan up to `LazySeq/chunk_size` = 32 **input** elements,
running `pred` on every one of them, regardless of where the first match sits.
For a pure predicate this overscan is unobservable; for an effectful or raising
predicate it is an observable effect count and a possible raise.

The candidate replaces the pair with the runtime's **existing** halting fold
`rt/k-reduce` + `rt/reduced` (the same mechanism `core/some` uses), with the
step testing the predicate for the HALT decision and carrying the **element** as
the payload:

```clojure
(rt/k-reduce (fn [acc el] (if (pred el) (rt/reduced el) acc)) nil coll)
```

The declared, closed supported domain (checked structurally on the candidate's
own expression and its immediate operands — this is not a general walker):

| part | admitted | refused |
|---|---|---|
| shape | `(rt/first (rt/filter p c))` or `(rt/first (rt/invoke (global "filter") [p c]))` | anything else |
| collection | a quoted literal list of simple literals, a `cons`/`enil` chain of those, or `(lists/seq i j)` on integer literals **with `i =< j`** (a forward literal range is total and non-raising) | vars, unknown globals, lazy providers (`range`, `map`, …), calls that could force/effect, and a **backwards literal range** (`i > j`, where `lists:seq/2` raises) → `:collection-range-not-total` |
| predicate | a literal single-clause `(fn [p] body)`, body total and effect-free: `if`/`and`/`or`/`not` over `:arith` comparisons (`< > <= >= ==`) whose operands are simple literals or the parameter | effectful bodies, raising ops (`/`, `odd?`), globals/captures, keyword/map/native predicates, non-literal (alias/var) predicates |
| resolution | `:resolved? true` supplied by the caller, or a direct `rt/filter` call | the ordinary `RT.invoke(…"filter"…)` spelling without that declaration |

Why these boundaries are sound:

- **`rt/k-reduce` semantics.** A 2-arity single-clause BL `(fn [acc el] …)`
  compiles to a raw Erlang fun, which `k-reduce`'s `step` applies directly; a
  step returning `%BeamLisp.Reduced{}` stops the fold with **no further callback
  and no further force**, and `k-reduce` unwraps the payload (rt.bl `k-reduce`
  / `reduce-reduced`). So the scan visits exactly elements `0..j` where `j` is
  the first matching index, or all of them.
- **Total predicate.** `BeamLisp.Num`'s ordering ops (`lt/gt/le/ge`,
  priv/host/num.bl "ordering") are, and stay, TOTAL Erlang term order for
  non-decimal operand pairs. `simple-lit?` excludes decimals, so every admitted
  comparison is total and cannot raise. `if`/`and`/`or`/`not` are total over the
  same. Hence lowering cannot change *which* error is raised or *whether* one is.
- **Effect-free predicate.** `system.footprint/pure?` over
  `fp-fn-body` is a second, independent check (the same engine the central pass
  consumes). A grammar proof and an effect proof must both hold.

## 1a. The actual compiled shape (source-verified, not guessed)

The adapter matches the compiler's REAL output, read from `priv/boot/compiler.bl`
and `priv/boot/anf.bl` — the first revision guessed a bare `:fn` and refused every
predicate:

- `first` has a `:both` link row (`core/first → BeamLisp.Ns.Rt:first`), so
  `(first …)` compiles to a direct `:remote :Elixir.BeamLisp.Ns.Rt :first [inner]`.
- `filter` has a **value-only** row (no link), so `(filter p c)` compiles to
  `RT.invoke(fetch "filter", [p c])`: a `:remote … :invoke` whose first argument
  is `(:global "user" "filter")` and whose second is a `:cons`/`:enil` list of
  the two argument nodes.
- `lists/seq` is a lowercase qualified head → an Erlang `:remote :lists :seq`.
- `>`/`<`/`>=`/`<=`/`==` are 2-arity numeric links → an `:arith` node
  (`:fun :gt`, `:bif :>`), not a `:remote`.
- **every fn VALUE is the self-application scaffold**
  `(let self (fn [self] INNER) (self self))` (`compiler.bl` `self-apply`), so a
  source `(fn [x] …)` reaches the adapter as a `:let`, NOT a bare `:fn`.
  `fn-value-node` unwraps it via `system.ir/self-scaffold?` / `scaffold-inner`;
  a `$blfn` dispatch tuple (multi-arity/variadic) is still refused.
- `and`/`or` are core macros; they expand to `(let [tmp a] (if tmp … tmp))`, so
  the total grammar reads `:let`/`:if`/`:var`, which is why it handles those and
  not just `:erlang :and`/`:or`.

`fp-fn-body` is likewise fed the UNWRAPPED inner `:fn`; passing the scaffold
would read no clauses and silently under-report.

## 2. The law

For every materialized finite list `xs` and every total, effect-free, stable
predicate `p` over its elements:

```
(first (filter p xs))
  ==
(rt/k-reduce (fn [acc el] (if (p el) (rt/reduced el) acc)) nil xs)
```

The right side returns the FIRST element `xs_j` with `(p xs_j)` truthy, else
`nil` — the same element, including `false` and `nil`. It is **not** `some`:
`some` returns its SELECTOR's result and treats a false/nil result as no match,
so `(some (fn [e] (if (p e) e nil)) xs)` returns `nil` when the first matching
element is `false`. That is the negative control this spike exhibits.

## 3. Proof scope and the model/runtime boundary

What the logic backs, and what it does **not**:

| obligation | tool | scope / bound | boundary |
|---|---|---|---|
| emitted halting-scan shape = first-match spec, N=3 | z3 (`z3/check`, UNSAT) | symbolic `P : Int → Bool`, `x0..x2` | **encoding-level**: it proves the unrolled shape, not the runtime `k-fold` walk |
| naive selector fold loses a `false` match | z3 (SAT + model) | witness `x0 = 1` (the false encoding) | the false/nil boundary is exactly where the two differ |
| on truthy matched elements naive ≡ correct | z3 (UNSAT) | same encoding, `x0 ∉ {nil,false}` | pins the bug to the false/nil boundary |
| parity of `first(filter)` vs the halting fold | veritas `for-all`, `:enumerate` → `:proven` | exhaustive over lists of length ≤ 2 over `{0,1,2,3,false,nil}` × 4 declared predicates (≈ 172 pairs) | **finite declared bound**; `:proven` is a complete enumeration *within that bound*, not over all programs |
| naive `some` lowering refuted | veritas `for-all`, `:enumerate` → `:refuted` (+ witness) | same finite domain | sampled bound is exhaustive, so the refutation is a real counterexample |
| ANF parity of the emitted node | differential `lower/eval-anf` baseline vs lowered | the test table | the one check that runs the **real** lowering path |

The central optimizer is used only through its **accessible** API
(`opt/explain`, `opt/node`); the research adapter does not call any private
fact function.

Key boundary statement: the z3 obligations are over a **model** of the fold
(nested `ite`), and the veritas obligation is over a **finite list domain**.
Neither is a proof about the compiled runtime. The runtime-tie is the
`lower/eval-anf` differential parity test plus the work experiment; the
`k-reduce`/`reduced` contract is read from source and not separately
model-checked.

## 4. What the central optimizer does today — the integration gap

Accessible-API observations the test asserts (UNRUN):

1. **It owns the fold machinery.** `opt/explain` on the strict
   `(let [xs (lists/map …)] (lists/foldl …))` shape reports rule
   `:strict-map-fold`. The callback grammar, integer-domain facts, ownership
   proof and inlining budget already exist there.
2. **It has no `first`/`filter` law.** `opt/explain` on
   `(first (filter (fn [x] (> x 3)) (lists/seq 0 8)))` reports **no evidence**
   and a refusal with reason `:unknown-or-mismatched-native-arity` — the inner
   `RT.invoke(core/filter, …)` reaches the pass as an unresolved `:global`; the
   outer `rt/first` is untouched. So the element-consumer is neither fused nor
   refused *as a unit*.
3. **Our output is a legal fixed point.** `(opt/node lowered)` returns `lowered`
   unchanged — the lowered node is accepted by the central node pass and is not
   counter-rewritten.

### The gap

The adapter had to **re-derive** two facts the central pass owns but does not
expose:

- the **collection's materialized-finite domain** (the central `fact` computes
  `:integer-list` for exactly these shapes, but `fact` is private);
- the **callable resolution** of a value-only link name (`filter`), which a
  central rule would take from Env/link facts.

`system.footprint/pure?` *is* public and is reused; nothing else is.

### Smallest proposed central extension

1. Add a `:strict-first-filter` rule beside `:strict-map-fold` in
   `priv/host/optimize.bl::rewrite`, matching
   `:remote rt :first [ :remote rt :invoke [:global ?ns "filter" [p c]] ]` (and
   the direct `:remote rt :filter` form).
2. Add a `closed-pred?` sibling of `closed-int?`/`int-callback`: the total,
   effect-free comparison grammar over a closed integer/term domain, with the
   same definition-scope binding rule.
3. Add a `materialized-coll?` fact (literal list, cons/enil chain, `lists:seq`)
   reusing the existing `fact`; expose the fact read via a public accessor so
   consumers do not duplicate it.
4. Bind the `filter`/`first` callee by **exact resolved identity** (Env/link),
   and add `filter`/`first` to the `:live-provider-or-observable-lazy-demand`
   refusal list so an unproven site is refused rather than silently kept.
5. Emit the same `rt/k-reduce` + `rt/reduced` fold; reuse
   `checked-fold-result`'s bounded materialization for the callback if it ever
   inlines a body (this lowering does not copy the predicate node).

This is additive and stays inside the one optimizer; it introduces no second
pass and no application-level hook (consistent with
`research/optimizer-integration/README.md` §7).

## 5. Fallback and refusal conditions

`consumer/lower` returns `{:refused reason}` and the caller keeps the untouched
lazy spelling for every out-of-domain case. Reasons, and the edge each one
answers:

| reason | trigger |
|---|---|
| `:not-a-first-of-filter` | the expression is not the recognized pair (e.g. `take`/`some` wrapper) |
| `:filter-resolution-unproven` | the `RT.invoke` spelling without `:resolved? true` (shadow/rebind safety) |
| `:collection-not-materialized` | var, unknown global, `range`/`map`/provider, any non-literal source (lazy demand could change) |
| `:collection-range-not-total` | a `(lists/seq i j)` with integer literals but `i > j` — Erlang's `lists:seq/2` raises for a backwards range, so it is not a value list |
| `:predicate-not-total-effect-free` | effect (`println`, `swap!`), raising op (`/`, `odd?`), capture (`k`), keyword/map/native predicate, alias/var predicate |

**Capture policy.** The lowering reuses the predicate `:fn` NODE directly; it
never closure-converts, copies captures, or rematerializes a body. So captured
bindings, sharing and any cycle edges in the capture graph are preserved
untouched, and there is no cycle-edge pruning to justify. Predicates that
actually *use* a capture are still refused, because the adapter has no lexical
domain fact for the captured value — the same boundary the central optimizer
records under "immutable captures" (§5.2 of the revisit ledger). This is a
deliberate refusal, not an ownership claim.

## 6. Expected negative witnesses and metrics (UNRUN)

- **Naive lowering witness.** `(first (filter (fn [x] (== x false)) '(1 2 false 4)))`
  → baseline `false`; `consumer/naive-lower` → `nil`; correct lowering → `false`.
- **Totality / domain controls (new).**
  `(first (filter (fn [x] (> x 1)) (lists/seq 8 0)))` →
  `{:refused :collection-range-not-total}`; `(lists/seq 0 n)` (non-literal
  bound) → `:collection-not-materialized`; `(lists/seq 0 8)` → lowers. A
  boolean/nil domain `'(0 false nil 4)` preserves a matched `false`/`nil`
  exactly in both the baseline and the lowered form. Effect / `throw` /
  division bodies (`println`, `throw`, `swap!`, `/`) all refuse with
  `:predicate-not-total-effect-free`.
- **Report (new).** `consumer/report` (default 5 runs) on the
  `(> x 3)` / `(lists/seq 0 8)` case → `:eligible true`,
  `:rule :first-filter-halting-fold`, `:metrics.baseline.value 4`,
  `:metrics.lowered-run.value 4`, a non-nil `:naive`, `:authority
  :research-adapter`; on `(… xs)` → `:refused :collection-not-materialized`
  and `:lowered nil`.
- **Chunk overscan witness.** Source-level instrument on `(lists/seq 0 1000)`
  with a first match at index 4: baseline predicate calls = **32** (a whole
  chunk); the halting fold's calls = **5**. This is why an effectful predicate
  must be refused — the lowered form is *not* effect-equivalent.
- **Veritas.** parity property `:proven` / `:enumerate`; naive property
  `:refuted` with a `[xs idx]` witness whose first match is `false`.
- **z3.** O1 UNSAT (shape contract), O2 SAT (false-match witness), O3 UNSAT
  (truthy boundary).
- **Report entry.** `consumer/report` (arity 1 and 2) is the exported
  orchestrator entry: it returns `{:eligible :refused :rule :conditions :lowered
  :naive :metrics :authority :version}`. `:metrics` holds the matched baseline
  and lowered runs for `n` iterations (default 5); `:naive` is the executable
  negative witness; `:authority` is `:research-adapter`, never a shipped rule.
- **Work.** `consumer/measure` on
  `(first (filter (fn [x] (> x 3)) (lists/seq 0 1000)))` × 5: both values `4`;
  expected `:reductions` baseline > lowered. Reductions are the process counter
  around one pre-compiled `run/0`, so they exclude compilation; treat them as
  indicative, and the callback count above as the clean metric.

## 7. Source integration paths (if promoted)

- rule + facts: `priv/host/optimize.bl` (`rewrite`, `fact`, `closed-pred?`,
  `materialized-coll?`, `rules`), facade unchanged (`priv/boot/optimize.bl`).
- footprint reuse: `priv/lib/system/footprint.bl` (`pure?`, `fp-fn-body`) — no
  change.
- runtime: none. The halting fold is `priv/boot/rt.bl`'s existing
  `k-reduce`/`reduced`; this is not a new runtime primitive.
- tests to extend: `test/bl/optimizer_lexical_prototype_test.bl` (parity /
  refusal / budget) and `test/bl/system/optimizer_laws_test.bl` (algebra).

## 8. Logic query scopes

- veritas: finite generator `ListGen` (lists up to length 2 over
  `{0 1 2 3 false nil}`) × `one-of 0 1 2 3` (predicate ids), exhaustive
  enumeration, modality `:proven`/`:refuted`. Declared bound is the list length.
- z3: two sorts/encodings — symbolic `P : Int → Bool` with explicit
  `x0..x2` for the shape contract; a concrete false/nil encoding (`1` = false,
  `0` = nil, truthy otherwise) for the counterexample and its boundary. The
  oracle is the pooled `z3` surface (README: a supervised handle, not a private
  OS port; there is no `z3/close` to fabricate). A one-shot `z3/check` leases a
  solver and returns the lease in its own `finally`; the pool is VM-owned and
  terminates with the verification process.

## 9. What remains unverified

- The **runtime** `k-reduce`/`reduced` walk is not model-checked; only read
  from source and exercised by the differential parity test.
- The veritas proof is finite (length ≤ 2); longer lists, duplicate matches,
  and predicate interactions beyond the four declared predicates are outside
  the bound.
- The `filter` resolution is **declared**, not proven by the adapter; the
  central extension in §4 is the missing mechanism.
- A **backwards literal range** `(lists/seq i j)` with `i > j` is refused before
  lowering (`:collection-range-not-total`); the forward range `i =< j` is the
  admitted shape. Erlang's `lists:seq/2` error behaviour on equal/adjacent
  bounds is not model-checked beyond this structural admission.
- Reduction/timing numbers are host-dependent and were not run.
- Cells are **not** separately counted: the callback count (32 vs 5) stands in
  for the removed lazy-chunk work; no allocation claim is made.
- No package/seed/deployment implication: this is a research prototype in
  `research/structural/`, not on any default path.
