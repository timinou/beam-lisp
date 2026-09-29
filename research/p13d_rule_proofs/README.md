# P13d — SMT-verified deodorant rules: findings

Run: `bin/bl run research/p13d_rule_proofs/rules.bl` (uses the repo's pinned z3, `priv/z3/bin/z3`)

## Results

| rule | verdict |
|---|---|
| `(if p true false) → (boolean p)` | PROVEN ∀p |
| `(not (nil? x)) → (some? x)` | PROVEN ∀x |
| `(= x 0) → (zero? x)` | COUNTEREXAMPLE: `tag_x=3` (a string) |
| same, under discharged `x : int` | PROVEN — auto-promoted to SAFE |
| `(= x 1) → (zero? x)` (broken on purpose) | COUNTEREXAMPLE (`tag_x=5`: raise asymmetry) |

`rules.bl` prints a per-rule millisecond figure beside each verdict; it tracks
machine load, not solver behavior.

## Porting note

`rules.bl` builds the negated-soundness assertion itself and drives the pinned
solver through `BeamLisp.Z3Port`. It does not use `z3/prove-equiv`: that function
renders each term separately with `smt/emit` and then embeds the resulting TEXT
into a form, so `smt/emit` quotes it — z3 is asked `(= "p" "(ite p true false)")`
and compares the strings, not the terms. Identical sides then "prove" and
differing sides "refute", whatever they mean. Verified against the pinned
solver; the fix belongs in `priv/lib/z3.bl`, a shared file this port does not
touch.

## Answers

**(a) Can the solver PROVE safe rules?** Yes — soundness is encoded as
"same result AND same raised-ness for all inputs"; asserting its negation
and getting `unsat` is a proof. Milliseconds per rule.

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

## Protocol lessons (they inform priv/lib/z3.bl)

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
