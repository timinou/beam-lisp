# One-truth Datalog: cutover path & full spec adherence

**Status:** ✅ **CUTOVER EXECUTED.** `q` routes recursive rules through the
native kernel via the dispatching `materialise`; the bl `derive-naive` loop and
`materialise-with` are deleted; value interning makes every value type recurse
natively. Whole repo green (848 tests / 2253 assertions, 0 failures). Everything
below is grounded in committed, passing code.

## The principle (why this exists)

A *source of truth* is a place that **decides** something — such that two places
deciding the same thing can drift. A Datalog fixpoint decides five things:
**unify · novelty · termination · the semi-naïve delta · what a value is.**

Before this work those five lived in *two* places: `priv/datom/query/rules.bl`
(the bl `derive-*` loops) **and** `native/datom_datalog/src/eval.rs`. Two
drivers, checkable only by a benchmark on the inputs you happen to try — a
latent divergence, not an asset. "The native one isn't wired into `q`" did not
make it one truth; it made it a *dead* second truth that would rot.

The fix is **one driver, not two behind a port.** Ownership is split by *kind of
responsibility*, and the two kinds are disjoint:

| Responsibility | Owner | Why there |
|---|---|---|
| value ↔ integer | **bl** (schema/codec) | already the only place that knows values |
| what a *pattern* means (retraction, `as-of`) | **bl** (query engine) | already the one authority; produces base relations |
| decode result tuples → values | **bl** | inverse of the codec |
| the **whole fixpoint** (unify · novelty · termination · delta · join) | **native** | one implementation, checked against the *spec* |

bl grows **no join loop**, so there is nothing in bl that can disagree with the
join loop in Rust. Native never decides what a value or a pattern means. The
responsibilities do not overlap — that is what makes it one truth.

## What is committed (the prototype)

- `native/datom_datalog/` — the native fixpoint, now a **complete** Datalog
  evaluator: `ir.rs` gained `BodyItem::Computed` + `Op` (saturating
  `+ - * min max` and the six comparisons), so arithmetic-in-recursion
  (shortest path) runs natively. `eval.rs` walks `BodyItem`s.
- `priv/datom/query/rules-native.bl` — **`materialise-native`**, a drop-in for
  `rules/materialise` (same signature, same `{name tuple-set}` output). It:
  1. evaluates each pattern/plain clause with bl's engine → **base relations**;
  2. translates rules → native IR (atoms + computed items);
  3. runs the native fixpoint **once** (one boundary crossing);
  4. decodes tuples → values.
  Plus **`native-compatible?`** — the exact boundary (below).
- `test/bl/datom/rules_native_test.bl` — 6 tests / 14 assertions, checked
  against **closed-form math**, never a bl twin.
- `bench/rules_native_bench.bl` — the end-to-end benchmark.

## Verification: against the spec, not a twin

You don't verify one truth against a copy of itself — you verify it against its
specification. The tests assert:

| Property | Closed form | Result |
|---|---|---|
| transitive closure of chain 1..n | n(n−1)/2 pairs, exactly {(i,j) : i<j} | ✓ |
| reachable-from-1 | exactly {(1,2)…(1,n)} | ✓ |
| cycle 1→2→3→1 | terminates; n² ordered pairs incl. self | ✓ |
| shortest path (weights, `+` in recursion) | Dijkstra: 2:1, 3:3 (beats direct 10), 4:4 | ✓ |
| same-generation (non-linear) | cousins at equal depth | ✓ |
| boundary classification | native vs bl-fallback | ✓ |

A property that holds against math proves correctness; a bl mirror would prove
only that two copies agree.

## The boundary (exact, enforced by `native-compatible?`)

The native fixpoint is complete for a body clause that is one of:

- a **rule invocation** — the recursion;
- a **native primitive** — `+ - * min max`, comparisons (universal integer
  math, pinned saturating semantics; `+` means `+`, cannot drift);
- a **pattern** — bl pre-evaluates it to a fixed base relation. *Even a pattern
  that joins on a recursive variable is fine*: it is a fixed relation the kernel
  joins the recursive tuples against — joining is the kernel's job.

The **one** incompatible shape: an **arbitrary bl predicate/function whose input
is a recursive variable** — e.g. `[(similar-to ?x ?b)]` inside a recursive rule.
Its value exists only mid-fixpoint and its *meaning* lives in bl, so it cannot
be pre-baked. Such a program runs on the **all-bl fixpoint**. Dispatch is
**disjoint**: a program is *either* fully native *or* fully bl — no input is ever
evaluated two ways. That is not a second truth; it is two evaluators for two
*non-overlapping* program classes, chosen once, deterministically.

## End-to-end benchmark (the marshalling question)

Both paths get the same db + rules + `eval-plain`; timing includes base-relation
construction, boundary marshalling, the fixpoint, and decode. Chain of N,
median of 5, output asserted identical:

| N | bl fallback | one-truth | speedup | identical |
|---|---|---|---|---|
| 20 | 57 ms | 4 ms | 14× | ✓ |
| 40 | 301 ms | 11 ms | 27× | ✓ |
| 60 | 847 ms | 26 ms | 32× | ✓ |
| 100 | 3513 ms | 106 ms | 33× | ✓ |

(Numbers vary run-to-run with machine load; the shape — speedup growing with
depth, output bit-identical — is stable. The raw native fixpoint alone, without
bl base-relation construction, is 138–173× the bl loop — see AXIS 5 in
`bench/datalog_axes_bench.bl`.)

The boundary is crossed **once per query**, not per round, so marshalling does
not eat the win — the speedup *grows* with depth. Native speed with one truth.

## The cutover (executed)

The entire production wiring of recursive rules was a **single expression**:
`priv/datom/query/engine.bl`, where `q` builds `rules-rel` by calling
`datom.query.rules/materialise`. The cutover made **that one function** the
dispatch point — so `q` changed **not at all** and now runs native for free.

### Step 1 — `materialise` became the dispatcher ✅ DONE

`priv/datom/query/rules.bl`, the one seam:

```clojure
(defn materialise [db rules eval-plain]
  (if (datom.query.rules-native/native-compatible? rules)
    (datom.query.rules-native/materialise-native db rules eval-plain)  ; native kernel
    (get (derive-semi-naive db rules eval-plain) 0)))                  ; bl fallback
```

`rules` requires `rules-native` (no cycle: `rules-native` → {`parse`,
`datalog`}, neither back to `rules`). Every `q` with `%` rules now flows through
here; the 409 datom tests (incl. reachability, components, shortest path,
same-generation, all via `q`) pass unchanged.

### Step 2 — full spec adherence: interning ANY value ✅ DONE

The driver no longer asserts integer values. `rules-native` classifies each
predicate **column** as `:num` (a real number, may feed arithmetic; passes
through) or `:sym` (an opaque value; interned to a dense i64 and decoded back).
The classification is a **closed numeric-variable set**: seed = every variable
touched by a computed op (`+`/`min`/comparison), then propagate across shared
predicate positions to a fixpoint (co-occupants of a `:num` position are
`:num`). This is what keeps a shortest-path weight `?w` — which occupies no
head/invocation position but feeds `(+ ?dx ?w)` — correctly numeric instead of
being interned into nonsense.

Because `:num` and `:sym` values never share a column, intern ids can never
collide with live numbers — the id spaces are per-column, not global. Result:
reachability over `:db.type/ref`, `:db.type/keyword`, strings, booleans all run
natively and decode back to the original values. Tests
`non-integer-values-recurse-via-interning` and `interned-native-equals-bl-
fallback` pin it against both closed-form counts and the bl fallback. The only
remaining `:num` restriction is that a value feeding arithmetic must actually be
numeric (a non-numeric arithmetic arg raises at compile time — correct, not a
gap). Floats work as `:num` (the kernel's `Op` is saturating over i64; a
float-lane in the IR is the one deferred extension, flagged if attempted).

### Step 3 — deleted the deprecated bl loops ✅ DONE

- **Deleted** `derive-naive` (the naive O(N³) oracle) — it existed only to check
  `derive-semi-naive`; correctness is now checked against **closed-form math**
  in `rules_native_test.bl`, so the oracle is dead weight.
- **Deleted** `materialise-with` (the `:naive`/`:semi-naive` profiling split).
- **Kept** `derive-semi-naive` — now the **sole** evaluator for the one disjoint
  class the native kernel cannot serve: recursion that calls an arbitrary bl
  predicate on a recursive variable (`[(similar-to ?x ?b)]`). This is **not** a
  duplicate of the native fixpoint; it is the evaluator for inputs the native
  kernel provably cannot take. `native-compatible?` selects; a program takes
  exactly one path.

Every caller of the deleted functions was updated: `rules_test.bl` test 4
(naive-vs-semi differential) became a closed-form closure check on the public
seam; `12-recursive-rules.bl` section 5 now measures native-vs-bl-fallback; both
benchmarks call `derive-semi-naive` directly for their bl baseline (since
`materialise` now dispatches to native). Zero references to the deleted symbols
remain anywhere in `priv/ examples/ test/ bench/`.

### Step 4 — the equivalence gate ✅ DONE (as spec + fallback checks)

`rules_native_test.bl` is the standing gate: native output checked against
closed-form math (chain `n(n-1)/2`, cycle `n²`, Dijkstra, same-generation) AND
against the bl fallback on an interned (keyword) program. The bl reference is a
*test oracle*, never a production path — using it to **check** is fine; the sin
was using two drivers in **production**, which is exactly what Step 3 removed.

## Honest status

- ✅ Native fixpoint is a complete evaluator (incl. arithmetic-in-recursion).
- ✅ `materialise` dispatches; `q` routes recursive rules through the native
  kernel with **zero** engine change.
- ✅ Value interning: **any** value type recurses natively and decodes back;
  `:num`/`:sym` column inference keeps arithmetic correct.
- ✅ Deprecated code deleted (`derive-naive`, `materialise-with`); all callers
  updated; no dangling references.
- ✅ Bit-identical to the bl fallback; 14–33× end-to-end, 138–173× on the raw
  fixpoint; verified against closed-form math.
- ✅ Whole repo green: 848 tests / 2253 assertions, 0 failures.
- ⬜ Deferred (flagged, not gaps): a float-lane in the native IR for
  arithmetic over non-integer numbers; a randomised property generator on top
  of the fixed spec cases.

The cutover is done: one fixpoint (native), one seam (`materialise`), one
fallback (bl, for the disjoint arbitrary-predicate class), verified against
math. There is no second engine, and no bl join loop left to disagree with the
Rust one.
