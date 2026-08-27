# One-truth Datalog: cutover path & full spec adherence

**Status:** prototype landed and verified; cutover not yet executed (this doc is
the plan). Everything below is grounded in committed, passing code.

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

| N | all-bl | one-truth | speedup | identical |
|---|---|---|---|---|
| 20 | 129 ms | 7 ms | 18× | ✓ |
| 40 | 694 ms | 15 ms | 46× | ✓ |
| 60 | 2031 ms | 35 ms | 58× | ✓ |
| 100 | 8936 ms | 119 ms | 75× | ✓ |

The boundary is crossed **once per query**, not per round, so marshalling does
not eat the win — the speedup *grows* with depth. Native speed with one truth.

## The cutover (one seam)

The entire production wiring of recursive rules is a **single expression**:
`priv/datom/query/engine.bl` ~line 588, where `q` builds `rules-rel`:

```clojure
rules-rel (if (some? rules-arg)
            (datom.query.rules/materialise            ; ← the one seam
              db rules-arg
              (fn [d b clause] (eval-clause d b clause default-resolve {})))
            {})
```

### Step 1 — introduce the dispatch (non-breaking, reversible)

Add to `rules.bl` (or a thin `rules-dispatch.bl` to avoid a require cycle):

```clojure
(defn materialise-dispatch [db rules eval-plain]
  (if (datom.query.rules-native/native-compatible? rules)
    (datom.query.rules-native/materialise-native db rules eval-plain)  ; native
    (materialise db rules eval-plain)))                                 ; bl fallback
```

Point the `q` seam at `materialise-dispatch`. **Verified working**: routing a
reachability program through the dispatch yields output `= bl` (checked this
session). Native-incompatible programs transparently keep the bl path.

### Step 2 — full spec adherence (widen the value domain)

The prototype asserts **integer values** (graph programs are integer-valued:
entity ids + weights). Full adherence generalises the value↔integer step to
*all* values, and this is the ONLY addition needed — the fixpoint does not
change:

1. **Intern arbitrary values.** bl already has the order-preserving codec
   (`value-codec.bl`). Add a per-query bijection `value ↔ i64` (a dense id
   table). Constants and base-relation tuples are interned on the way in;
   result tuples are un-interned on the way out. Arithmetic still requires
   *genuine* integers (a computed arg that isn't numeric is a compile error, as
   now) — but equality/join over interned ids is exact, so reachability over
   `:db.type/ref`, keywords, strings all work.
2. **Booleans / instants / keywords** map through the same intern table (they
   are already codec-encodable). Floats used in arithmetic need an explicit
   fixed-point or a float-lane in the IR — deferred, flagged at compile time.

Nothing about unify/novelty/termination changes; only the marshalling widens.
This keeps the one-truth property intact — the intern table lives in bl (the
value authority), the fixpoint stays native.

### Step 3 — delete the bl fixpoint loops (the actual cutover)

Once the dispatch covers every program a query can present (native for the
compatible class, bl for the `similar-to`-in-recursion class), the bl
`derive-naive` / `derive-semi-naive` loops in `rules.bl` are **only** reachable
for the incompatible class. At that point:

- **Keep** `rules.bl`'s `eval-body-with-relations` + a *single* fixpoint loop —
  but ONLY for the bl-fallback class (arbitrary predicates in recursion). This
  is not a duplicate of the native fixpoint; it is the evaluator for a
  *different program class* the native kernel provably cannot serve.
- **Delete** the `:naive` / `:semi-naive` strategy split and `materialise-with`
  (profiling scaffolding). One bl loop remains, for one purpose.

The end state: **native fixpoint for pure-relational-plus-arithmetic recursion
(the overwhelming common case, 75× faster); one bl fixpoint for recursion that
calls back into arbitrary bl semantics.** Two evaluators, disjoint domains,
selected by `native-compatible?` — never two evaluations of one program.

### Step 4 — the equivalence gate (make it un-rottable)

Add to CI a property test: for random *native-compatible* programs over random
graphs, `materialise-native ≡ <bl reference>` **and** `≡ <closed form where
known>`. This is the standing gate that keeps the boundary honest — if a future
edit makes native diverge on the compatible class, CI fails. The bl reference
here is a *test oracle*, not a production path; using it to *check* is fine, the
sin was using two drivers in *production*.

## Honest status

- ✅ Native fixpoint is a complete evaluator (incl. arithmetic-in-recursion).
- ✅ One-truth driver produces bit-identical output to bl, 18–75× faster
  end-to-end, verified against closed-form math.
- ✅ The boundary is exact and enforced; dispatch is disjoint.
- ⬜ Not yet wired into `q` (Step 1 is a one-line change, demonstrated working).
- ⬜ Value interning for non-integer domains (Step 2) — mechanism identical,
  scope widened.
- ⬜ bl loop reduction to the fallback-only role (Step 3).
- ⬜ CI equivalence gate (Step 4).

The prototype proves the architecture and the speed. The remaining steps are
marshalling breadth and a wiring flip — not new semantics, and not a second
engine.
