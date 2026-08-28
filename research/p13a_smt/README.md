# P13a — SMT encoding spike: findings

Run: `elixir research/p13a_smt/encode.exs` (requires z3 on PATH; tested 4.16.0)

## Questions and answers

**Q: Can beam-lisp guard expressions be mechanically encoded to SMT-LIB
with correct dynamic-value semantics?**
YES. Two encodings, both proven against z3:

- `direct` — vars whose tag the lattice layer has proven numeric become
  SMT Ints; tag predicates resolve statically against the tag env.
- `tagged` — every var becomes `tag_x : Int` + `x_i : Int` payload; tag
  predicates are runtime assertions. This is the honest model of a
  dynamically-typed value.

Both proved: `(and (> x 3) (< x 3))` unsat, `(and (int? y) (string? y))`
unsat (tag contradiction — the type_safety.bl bug class), and the
two-variable datom-style bound check `(and (>= i n) (< i n))` unsat.

**Q: graceful degradation?**
Verified by accident and then on purpose: a conjunct outside the grammar
(`(> x (+ y 3))` — arithmetic in operand position) is dropped from the
`and`, weakening the query to the encodable subset — which correctly
answers `sat` (no false "unreachable"). Sound-warnings-only holds at the
encoding layer. Note: SMT-LIB speaks LIA natively, so extending the
operand grammar with `+`/`-` is a small, safe v0.1 extension that turns
that case into a proof.

**Q: latency?**
100 queries, tagged encoding:

| mode | p50 | p99 | max |
|---|---|---|---|
| fresh `z3 -smt2` process | 10 ms | 13 ms | 13 ms |
| persistent `z3 -in` port | 2 ms | 3 ms | 3 ms |

At 2 ms/query, every guard in the repo (dozens) costs well under 100 ms,
once, and FEAT-002-style caching (queries are pure functions of source)
amortizes repeats to ~0. Latency is a non-issue; no NIF needed.

## Surprise finding

Elixir 1.20's own type checker flagged a genuinely dead branch in this
spike mid-run (`is_integer(x)` under an `is_atom(x)` guard). Inference
catching bugs in the inference prototype: the strongest possible argument
for the feature, delivered live.

## Architecture conclusions (input to the backend decision gate)

1. Port driver (`z3 -in`), not NIF: 2 ms p50 removes the performance
   motive for vendoring C++.
2. The tag lattice and the solver COMPOSE, neither replaces the other:
   tags discharge solver preconditions (a comparison only encodes when
   the var is provably numeric); the solver handles what tags can't
   (arithmetic, cross-variable relations like `i < n`).
3. Encoding belongs at the source level, pre-codegen, over reader forms
   with FormMeta positions — the spike's sexp DSL maps 1:1 onto reader
   output (atoms = symbols, lists = lists).
4. "Vendoring z3 into beam-lisp" is viable only as a *baby SMT*:
   CDCL SAT (~200 LOC) + difference logic (Bellman-Ford over x−y≤c
   constraints, ~50 LOC) covers every guard shape seen in the wild here.
   Full SMT (EUF, arrays, quantifiers) in bl is research-grade — the
   literature agrees (no pure-Clojure SMT exists; Clojure binds Z3).

## Landscape (from the research sweep)

- **Formulog** (Bembenek, Madsen, Chong — OOPSLA 2020; arXiv:2009.08361;
  fast variant arXiv:2408.14017): Datalog + ML + SMT in one language,
  explicitly for refinement type checking and symbolic execution.
  Bimodal type system for terms inside SMT formulas. The architectural
  north star for "bake it in deeply".
- **core.logic** (Clojure): miniKanren + CLP(FD) — pure-lisp constraint
  logic WITH integer arithmetic; answers the "miniKanren has no
  arithmetic" objection for P13b.
- **webyrd/TAPL-in-miniKanren-cKanren-core.logic**: Pierce's TAPL type
  checkers translated to relations — the backwards-running checker
  literature, directly applicable to P13b.
- **Flix** (Madsen et al. — OOPSLA 2020) and **Datafun** (Arntzenius &
  Krishnaswami 2016): first-class datalog constraints inside a typed
  functional language; Datafun tracks monotonicity WITH TYPES — direct
  inspiration for embedding logic queries as first-class beam-lisp
  values, typed.
- No pure-Clojure SMT solver exists; the ecosystem binds Z3 (Java
  interop). Validates port-driver-first, baby-SMT-as-vendoring-option.
