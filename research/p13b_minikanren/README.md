# P13b — miniKanren in pure beam-lisp: findings

Run:
```
elixir -pa _build/test/lib/beam_lisp/ebin $(for d in deps/*/ebin; do echo -pa $d; done) \
  -e 'BeamLisp.init()
      BeamLisp.Env.push_load_path("priv")
      BeamLisp.Env.push_load_path("research/p13b_minikanren")
      BeamLisp.run_file("research/p13b_minikanren/types.bl")'
```

## What was built

- `minikanren.bl` — a complete µKanren kernel in ~190 LOC of pure
  beam-lisp: logic vars, unification (lists + vectors), streams with
  fair interleaving, disj/conj/fresh, run/reify, and predicate goals
  (numbero/stringo/booleo/symbolo) with Barliman-style
  succeed-as-a-hole semantics on unbound vars.
- `types.bl` — a featherweight RELATIONAL type checker (`typeo`) for a
  mini beam-lisp (literals, vars, if, fn, app).

## Results (all three directions from ONE relation)

Forwards (checking):
```
(if true 1 2)   → int
((fn [y] y) 5)  → int
(fn [x] x)      → (fn _4 _4)     ← polymorphic identity, α→α
```
Sideways (diagnostics): `(if true 1 "s")` → NO answer — the relation
proves untypeability by emptiness.

Backwards (synthesis, holes are templates):
```
run 1 bool : _0                       ← "any bool literal"
run 3 bool : _0, (if _1 _2 _3), ((fn (_4) _5) _2)
fn int→bool : (fn (_1) _2)            ← a function template
```
All answers in 1–4 ms.

## Language-level lessons (these shape the real implementation)

1. **No improper lists.** bl `cons` requires a proper-list tail, so the
   canonical `(state . thunk)` stream pair and env spines use tagged
   vectors (`[:cons h t]`, `[:thunk f]`, `[binding rest]`). Unify was
   extended to vectors pairwise.
2. **Recursion needs explicit delay + an immature stream.** Two failure
   modes found the hard way: constructing a recursive relation eagerly
   loops at goal-CONSTRUCTION time (fixed by η-expansion), and even
   delayed goals get forced eagerly by `bind` unless the delayed goal
   yields a THUNK stream (canonical `Zzz`). Consequence: the production
   miniKanren must provide `conde`/`fresh` as MACROS that delay
   automatically — the fn-spelling is workable but error-prone.
3. **Holes-as-templates work.** Predicate goals succeeding on unbound
   vars turn "run backwards" into program synthesis with holes — the
   Barliman design point, confirmed cheap in our setting.

## Chooser verdict (miniKanren vs z3 vs baby-SMT)

Division of labor confirmed with no overlap:

- **z3 owns DECISIONS** — sat/validity/models, arithmetic, rule proofs
  (P13a: port p50=2 ms; P13d: proofs in single-digit ms). Integration:
  port driver first; the `z3` Rust crate (prove-rs/z3.rs, mature,
  requires z3 ≥4.13.3, host has 4.16) makes a defnative-style NIF a
  straight upgrade path if profiling ever demands in-VM latency.
- **miniKanren owns RELATIONS** — the checker-as-relation, forwards /
  sideways / backwards, synthesis. Pure bl, no deps, this file is the
  proof. No arithmetic in v1 (that would overlap z3).
- **baby-SMT: not built.** Reconsidered only if z3-as-native fails
  feasibility; then it takes z3's whole job, not a subset.
