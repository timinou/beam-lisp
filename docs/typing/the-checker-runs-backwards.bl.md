# The checker runs backwards

Verification asks a yes/no question: *does this guard preserve the invariant?*
The machinery that answers it is a relation between a guard and a proof, and a
relation runs both ways. Read forward it checks a guard. Read backward it
**synthesizes** one — the guard a broken transition needs to become correct.

## Repair is abduction with a preference

A transition breaks an invariant when it can move from a good state to a bad one.
The fix is a guard that rules out exactly the moves that break it. Asking *which
guard does that* is abduction: search the candidate predicates for the ones that
close the Hoare triple

```
Inv ∧ guard ∧ (s' = next)  ⊢  Inv(s')
```

Several guards usually qualify. For an unguarded `withdraw` under `balance ≥ 0`,
both `(<= amt balance)` and `(<= amt 0)` are sound — but `(<= amt 0)` forbids the
whole point (withdrawing a positive amount). The right repair is the **weakest**
sound guard: the one that admits the most behaviour while still preserving the
invariant.

## Weakest is an implication order

One guard is weaker than another when it permits more. Under the invariant,
`g1` is weaker than `g2` exactly when `g2 ⇒ g1` — every state `g2` allows, `g1`
allows too. z3 decides the implication:

```clojure
;; g1 weaker than g2?  →  is (inv ∧ g2 ∧ ¬g1) unsatisfiable?
```

The repair is the maximal element of this order: the guard implied by every
other sound candidate. It forbids the least while still being correct.

## Synthesize backward, verify forward

A synthesized guard is only trusted when it survives the forward check. Repair
finds the weakest sound guard by running the preservation query backward, then
**inserts it and re-runs the same forward checker**. A repair that does not make
the machine verify is not offered. The two directions of the one relation check
each other.

```clojure
(repair-process port node)
;; → {:name … :holds false
;;    :repairs [{:label :withdraw :guard "(<= amt balance)"}]}
;; splice that guard into :withdraw and (verify-process port fixed) holds.
```

## As expressive as its vocabulary

Repair proposes guards from a candidate vocabulary — relational predicates
`(op a b)` over the state variables and inputs. A property whose fix needs a
compound term it cannot form (say `(<= (+ reserved amt) balance)`) has no repair
in that vocabulary, and repair says so rather than guessing. Widening the
vocabulary widens what can be repaired; the mechanism is unchanged.

## Where it lives

- `system.core/repair-transition` — the weakest sound guard for one transition,
  with all sound alternatives.
- `system.core/repair-process` — every broken transition of a process, each with
  its synthesized guard, round-tripped through the forward checker.
- built on the shipped `abduce` / `candidates` (the miniKanren candidate
  relation) and the same `preserves-joint?` obligation the forward checker uses.
