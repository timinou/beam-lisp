# P13d — SMT-verified deodorant rules: findings

Run: `elixir research/p13d_rule_proofs/rules.exs` (requires z3 on PATH)

## Results

| rule | verdict | ms |
|---|---|---|
| `(if p true false) → (boolean p)` | PROVEN ∀p | 7 |
| `(not (nil? x)) → (some? x)` | PROVEN ∀x | 5 |
| `(= x 0) → (zero? x)` | COUNTEREXAMPLE: `tag_x=3` (a string) | 4 |
| same, under discharged `x : int` | PROVEN — auto-promoted to SAFE | 2 |
| `(= x 1) → (zero? x)` (broken on purpose) | COUNTEREXAMPLE (`tag_x=5`: raise asymmetry) | 3 |

## Answers

**(a) Can the solver PROVE safe rules?** Yes — soundness is encoded as
"same result AND same raised-ness for all inputs"; asserting its negation
and getting `unsat` is a proof. Single-digit milliseconds per rule.

**(b) Can it DERIVE an idiomatic rule's assumption?** Yes, and this is
the demo that matters: the counterexample to `(= x 0) → (zero? x)` is
`tag_x = 3` — a string. `=` is total (returns false across types);
`zero?` raises on non-numbers. The solver *found the exact boundary* of
soundness: the rule holds iff `x : int`. That is precisely the fact the
checker's tag lattice can discharge per call site — and when discharged
(fourth row), the same rule proves. Type-directed promotion of IDIOMATIC
rules to SAFE, end to end.

**(c) Does it catch broken rules?** Yes — the planted-broken rule yields
a counterexample instantly. (Note: the solver picked the raise-asymmetry
counterexample; pinning `tag_x = int` would surface the value-level one,
`x = 1`. A rule can be unsound for several independent reasons — the
verifier should enumerate counterexamples until unsat, not stop at one.)

## Protocol lessons (for the future smt library)

1. `(reset)` before every independent query — a persistent solver
   accumulates declarations; query 3 collided with query 2's consts.
2. Read answers line-wise and SCAN for the answer token: `(error …)`
   lines can precede it.
3. `(get-model)` bytes may arrive in the same chunk as the `sat` line —
   never discard buffered input when switching read modes.
4. z3 4.16 `-in` does NOT echo input; P13a's latency numbers stand.

## Consequence for the design

The "self-proving fixer" (seven-yields #5) needs no new machinery beyond
the P13a encoding + this soundness harness. Deodorant's honest contract
upgrades from "a reviewer checks each rule by eye" to "the solver checks
each rule, and tells you the precondition when it can't."
