# References — type system / logic-layer design research

Local copies in this folder; links for everything else. Feeds PLAN-047
and the final Typst writeup.

## Local copies

1. **Formulog: Datalog for SMT-Based Static Analysis** — Bembenek, Madsen,
   Chong (OOPSLA 2020, extended version).
   `formulog-datalog-for-smt-arxiv-2009.08361v2.html`
   https://arxiv.org/abs/2009.08361
   Datalog + ML + SMT in one language, for refinement type checking /
   symbolic execution. Bimodal type system; formulas as reified terms;
   magic-set speedups. The architectural north star.

2. **Making Formulog Fast: An Argument for Unconventional Datalog
   Evaluation** — Bembenek (2024, extended version).
   `formulog-fast-arxiv-2408.14017.pdf`
   https://arxiv.org/abs/2408.14017
   Evaluation strategy for Formulog-scale analyses.

3. **Fixpoints for the Masses: Programming with First-Class Datalog
   Constraints** — Madsen, Lhoták (OOPSLA 2020; UW tech report CS-2020-05).
   `flix-fixpoints-for-the-masses-cs-2020-05.pdf`
   https://plg.uwaterloo.ca/~olhotak/pubs/cs-2020-05.pdf
   First-class datalog constraint values in a typed functional language;
   row polymorphism over predicate symbols; compile-time stratification.

4. **Datafun: a Functional Datalog** — Arntzenius, Krishnaswami
   (ICFP 2016).
   `datafun-arntzenius-krishnaswami-icfp2016.pdf`
   https://www.cl.cam.ac.uk/~nk480/datafun.pdf
   Types track monotonicity (tones); semilattice types; well-typed
   fixpoints. Basis for typed live/incremental queries.

## Online / not vendored

- **core.logic** (Clojure): miniKanren + CLP(FD) — pure-lisp constraint
  logic with finite-domain integer arithmetic.
  https://github.com/clojure/core.logic
- **TAPL in miniKanren/cKanren/core.logic** — Webyrd: Pierce's type
  checkers as relations (runs backwards → synthesis).
  https://github.com/webyrd/TAPL-in-miniKanren-cKanren-core.logic
- **faster-miniKanren / miniKanren-with-symbolic-constraints** — Webyrd,
  Ballantyne et al.: constraint representations, quines.
  https://github.com/miniKanren/miniKanren
  https://github.com/michaelballantyne/faster-minikanren
- **Barliman** — Byrd et al.: relational interpreter program synthesis.
  https://github.com/webyrd/Barliman
- **miniKanren.org** — family site, talks, papers. http://minikanren.org/
- **Z3** — de Moura, Bjørner. https://github.com/Z3Prover/z3
  (vendoring note: no pure-Clojure SMT exists; ecosystems bind Z3.)
- **SMT-LIB standard** — Barrett, Fontaine, Tinelli.
  http://smtlib.cs.uiowa.edu/
- **Liquid Haskell** — Vazou et al.: refinement types via SMT, the
  escalation architecture precedent (types structural, SMT arithmetic).
- **Typed Racket / Typed Clojure** — gradual typing precedents.
- **Cousot & Cousot** — abstract interpretation (1976–77): composable
  abstract domains; intervals as the classic cheap domain.
- **Soufflé** — Scholz et al.: high-performance datalog.
  https://souffle-lang.github.io/
- **Doop** — Bravenboer, Smaragdakis: datalog points-to analysis.
- **CodeQL** — Semmle/GitHub: datalog-derived code querying at
  industrial scale.
- **KLEE** — Cadar et al.: symbolic execution (Formulog's comparison
  point; magic sets beat it 12×).

## In-repo native assets the design leans on (not citations, but the
other half of the story)

- `priv/datom/query/` — datalog engine: fixpoint, rules, magic sets
- `priv/rewrite.bl` — tree unification + fixed-point rewriting; rules
  as data
- `priv/deodorant.bl` — tiered rule-set composition (SAFE/IDIOMATIC)
- `priv/specter/`, `priv/optics.bl` — composable navigation/traversal
- `examples/type_safety.bl` — the runtime value-tag taxonomy the
  lattice is designed from
