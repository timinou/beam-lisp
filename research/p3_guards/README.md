# P3 — guards/clauses over the real corpus: findings

Run:
```
elixir $(for d in _build/test/lib/*/ebin; do echo -pa $d; done) \
  -e 'BeamLisp.init()
      BeamLisp.Env.push_load_path("priv")
      BeamLisp.Env.push_load_path("examples")
      BeamLisp.Env.push_load_path("research/p1_lattice")
      BeamLisp.Env.push_load_path("research/p2_positions")
      BeamLisp.run_file("research/p3_guards/run.bl")'
```

## The question

Zero false positives on existing examples? Checker over
`examples/guards.bl` (204 lines: multi-clause defn with `:when` guards,
`defn-`, docstrings, `doseq`) and `examples/destructuring.bl` (map
destructuring params with `:keys`/`:or`/`:as`, nested patterns).

## Answer: yes — 0 warnings on both, and the reachability rule fires

- `guards.bl`: **0 warnings**. Every warning the checker COULD have
  emitted would have been a false positive; hand-audit below.
- `destructuring.bl`: **0 warnings**.
- Positive control: a synthetic `([x] 1) ([x] :when (int? x) 2)` warns
  `2:22 f: clause unreachable — earlier clauses already cover every tag`.

## FP audit (why each potential warning correctly did NOT fire)

| shape | why silent is CORRECT |
|---|---|
| `(describe 7 -7 "hello" :keyword)` via doseq | `describe` unannotated → unknown → silent (contract) |
| clause 2 `(int? n)` after clause 1 `(and (int? n) (pos? n))` | `and` claims NOTHING (matches an unknown subset of the meet) → coverage not claimed → no unreachable warning |
| clause 4 bare after 1–3 | bare claims all-tags, but no clause FOLLOWS it → nothing to flag |
| `(- 66 (count title))` | both meet `number` via seeds → no disjoint meet |
| destructured params `(connect {})` | patterns bind targets to `any` — sound, silent |
| `(doc (quote connect))` | unknown callee → silent |

## Reachability/narrowing rules (the artifact)

1. **guard-claim** (coverage, for reachability): exact whitelisted
   predicate → its tags; `(or …)` of exact predicates → union;
   `(and …)` → ∅ (it matches an unknown SUBSET); missing guard →
   all-tags. Clause i with `claimed-union ⊇ all-tags` → unreachable.
2. **guard-narrow** (inside the body): meet over and-conjuncts, union
   over or-disjuncts, exact for a bare predicate. Different function
   from guard-claim: narrowing optimizes the BODY, claims protect
   LATER clauses — and `and` is sound for the first, unsound for the
   second.
3. Multi-param clauses claim nothing (product coverage not computed at
   this tier).
4. `pos?`/`neg?`/`zero?` narrow to `#{:int :float}` — they throw on
   non-numbers, so the assertion is sound.

## Bugs the corpus exposed in the walker (all fixed)

- Meta-transparent accessors: `walk-if` tests and `->>` steps arrive
  meta-wrapped (fixed in P2 pass).
- `guard-narrow` returns a TYPE; first integration used it as the ENV
  ("assoc not supported on a set") — the kind of error the type checker
  itself will catch once fn columns land (noted for P8/Typst).
- `destructuring.bl` has NO `(ns …)` form — the loader requires one;
  loaded via `BeamLisp/run_file` instead.

## Consequence

P1+P2+P3 complete ⇒ **MVP-A (the checker) graduates**: lattice +
poswalk promote to `priv/typed.bl`, demo in `examples/typing/`.
