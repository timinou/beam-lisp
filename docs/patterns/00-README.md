# Patterns as values — the capsule set

*One idea, many consequences. Each file below is a self-contained capsule:
what it is, why, a walkthrough with real beam-lisp, and the architectural
sketch. Read `01` and `02` first; everything after builds on them.*

The idea: **a destructuring pattern is a value** — data the language can
inspect — and **its lowering is chosen by what is provable about it**. The
same value then has six faces: matcher, constructor, generator, type, SMT
constraint, navigator. Every capsule is one face, or one construct that
turns out to be a pattern.

## Foundations

| # | capsule | one line |
|---|---|---|
| 01 | `01-one-value-model.md` | the representation quirks today (17 observed), and the one-model unification that removes them |
| 02 | `02-pattern-as-value.md` | the pattern value: shape, identity, hygiene, normal form |
| 03 | `03-obligation-gated-lowering.md` | why silent tightening is impossible by construction: every lowering carries an equivalence obligation |

## Same semantics, better code

| # | capsule | one line |
|---|---|---|
| 10 | `10-rigid-lenient-split.md` | native `c_case` for the provable part, steps for the rest |
| 11 | `11-leniency-as-guards.md` | `:or` defaults and absence as guard-safe BIF clauses — no allocation |
| 12 | `12-decision-trees.md` | multi-clause heads → one tree, clause selection in the VM |
| 13 | `13-proof-directed-representation.md` | proven shapes choose tuples, unboxed args, dropped `match_fail`, static realize depth, selective receive |

## New semantics

| # | capsule | one line |
|---|---|---|
| 20 | `20-pattern-algebra.md` | `and`/`or`/`not`/`guard`/view patterns, first-class match & `explain` |
| 21 | `21-pattern-is-optic.md` | destructure = select + bind; one vocabulary for let / heads / case / for / specter / datalog |
| 22 | `22-pattern-inverses.md` | constructor and generator from the same value: lenses, records, property domains |
| 23 | `23-pattern-is-type-and-constraint.md` | head patterns as fn domains; patterns as SMT datatypes; counterexamples as values |
| 24 | `24-dispatch-unified.md` | multimethods, protocols, typed catch, and `match` are one mechanism |
| 25 | `25-messages-are-patterns.md` | receive sets as protocols; send/receive subsumption; request/response completeness; code_change totality |
| 26 | `26-boundaries-and-absence.md` | inbound contracts that are also atom guards; absence ≠ nil; strict mode as a proof report |

## The principle, applied elsewhere

| # | capsule | one line |
|---|---|---|
| 30 | `30-make-it-a-value-lower-by-proof.md` | the same move on guards, loop measures, arities, effects, namespaces, errors, time, build |

## Ground truth

Everything in `01` was observed on `main` @ `698225c` via `./bl run`; the
Core lowering facts come from `research/ce1_core_erlang/`. Sketches are
designs — marked as such — and name the existing module each would extend.
