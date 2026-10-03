# 08 — Proven or refused: the upgrade the node holds

A hot upgrade ships only when z3 proves that the state migration preserves the
service invariant **and** that the new handler simulates the old — otherwise the
node refuses it with a distinct, named reason and keeps serving the old code.

## The claim

This spike proves the claim in `docs/design/vps/zero-downtime.md` §L1 ("hot
reload is the default"): *"The reconciler loads the new code beside the old
(`reload/ward`), proves the new contract or produces an explanation of how it
changed (`z3`), migrates state (`reload/migrate`), and cuts over."* The proof
half splits into two obligations, and this spike makes them explicit and
refusable: a **data migration** must preserve the invariant the service is
supposed to hold (`system.core/migration-preserves?`), and a **message
migration** must let a message queued under the old contract be fulfilled under
the new one with no observable divergence (`system.core/simulates?`).
`the-reconciler.md` §Failure posture supplies the posture: *"a delta it cannot
prove safe (z3 says no, or times out) is transacted as a refusal with the
counter-example — it errs toward stillness."* The spike's thesis line names the
outcome: **proven or held — never half-shipped.**

## The idea

A deploy is two changes wearing one name. There is the code swap — which on this
platform is an atomic hot reload of a `defn`, cheap and near-universally safe
(see `04-hot-reload.md`). And there is the *state* and *traffic* the new code
suddenly has to understand: the bytes already at rest under the old schema, and
the messages already in flight under the old handler's contract.

Most systems ship the code and discover the other two halves in production — a
migration script that quietly drove one row negative, a handler that added one
to a running total that should not have moved. The failure is not that the code
is wrong; it is that nobody *asked* whether it was, because the question cannot
be answered by a linter or a test that only runs one example.

The answer here is to make each half a **proof obligation** handed to a solver
before the swap:

- **Data.** Take the state as it is (`balance ≥ 0`, the invariant the service
  holds), apply the migration, and ask: *can the result violate the invariant?*
  If z3 says the violation is unreachable (`unsat`), the migration is safe for
  **every** starting state, not just the one you tested. If z3 finds a witness
  (`sat`), the migration is refused — and the witness is the counter-example.
- **Messages.** Two handlers, old and new, both observe the same state and both
  permit the same observable outcome. Model "observable" as a relation `R` over
  states; assert that old and new agree now (`R(b1, b2)`), let each take its
  step for the same message, and ask: *can the observables diverge after the
  step?* `unsat` ⟹ the new handler **simulates** the old — any message the old
  contract accepted is fulfilled identically by the new code.

Two independent facts, two solver questions, four possible ways to fail (each
migration can be *lacking* or *unsafe*). The node acts only when both proofs
land. Otherwise it holds: no swap, no half-deploy, old code still answering.
This is the design's "safety is structural" claim at the deploy boundary — a
wrong upgrade is not caught at runtime, it is *refused before it runs*.

## Walkthrough

### Stage 0 — one solver, one service model

```clojure
(def port (z3/open))
(defn inv [v] (str "(>= " v " 0)"))                 ; the service invariant: balance ≥ 0
(def decls "(declare-const b1 Int)\n(declare-const b2 Int)\n(declare-const amt Int)\n")
(def R (fn [a c] (str "(= " a " " c ")")))          ; observable equality
```

The whole service is modelled as **one integer** — a balance — in two copies:
`b1` is the state before the swap, `b2` the state after the migration; `amt` is
a message input carried by the handler. `z3/open` returns the oracle's handle
(a supervised solver pool; the handle is opaque and ignored by the proof calls
below). `inv` is a *function from a variable name to an SMT-LIB term*, so the
one invariant text is instantiated for whichever state copy the proof is about
(`inv "b1"` → `(>= b1 0)`). `R` is the observation relation: two states are
observably equal iff their balances are equal.

### Stage 1 — the gate: two proofs, four refusals

```clojure
(defn admit-upgrade
  [data-migrate msg-v2]
  (let [data-ok (and data-migrate
                     (sys/migration-preserves? port inv decls "b1" "b2" data-migrate))
        msg-ok  (and msg-v2
                     (sys/simulates? port R decls "b1" "b2" "(- b1 amt)" msg-v2
                                     "(assert (>= b1 amt))\n(assert (>= amt 0))"))]
    (cond
      (not data-migrate) {:verdict :refused :why :data-migration-lacking}
      (not data-ok)      {:verdict :refused :why :data-migration-unsafe}
      (not msg-v2)       {:verdict :refused :why :message-migration-lacking}
      (not msg-ok)       {:verdict :refused :why :message-migration-unsafe}
      :else              {:verdict :applied :why :proven})))
```

`data-migrate` is the SMT expression for the new state in terms of the old
(`b1 → b2`); `msg-v2` is the new handler's transition on the balance. `nil` for
either means the migration is **lacking**.

The `and` guard is load-bearing: a *lacking* migration is a structural fact, and
the gate records it without consulting the solver at all. An *unsafe* migration
is a semantic fact, and only that path asks z3. Note both `data-ok` and `msg-ok`
are computed (the `let` is eager), so a missing data migration still leaves a
fully-proven message migration in hand — `cond` simply reports the first failing
obligation, data before message. The returned map is the design's "refusal datum
with a reason": `{:verdict :applied|:refused :why …}`.

### Stage 2 — the data obligation

The real body of `migration-preserves?` asserts exactly this and asks z3:

```
inv(v1) ∧ v2 = migrate ∧ ¬inv(v2)      ; unsat ⟹ the migration is safe
```

In the spike's terms: assume the balance is non-negative now, set `b2` to the
migration expression, and ask whether `b2 ≥ 0` can fail. The `good` migration is
`"b1"` — a pure carry, so `b2 = b1 ≥ 0` and the violation is *unreachable*
(`unsat`) ⟹ proven. The `bad-data` migration `"(- b1 100)"` deducts 100: pick
`b1 = 0` and `b2 = -100 < 0`, so z3 finds the violation (`sat`) ⟹ **unsafe**,
refused. The proof is over *every* integer state, not a sample.

### Stage 3 — the message obligation

`simulates?` asserts the refinement condition and asks z3:

```
R(a, c) ∧ extra ∧ a' = a-next ∧ c' = c-next ∧ ¬R(a', c')   ; unsat ⟹ C simulates A
```

where `A` is the old handler's transition (`a-next`, here `"(- b1 amt)"`) and
`C` the new one (`c-next`, here `msg-v2`). `R` says their observables agree
before the step; `extra` is the old contract's precondition —

```
(assert (>= b1 amt))
(assert (>= amt 0))
```

— i.e. "the old handler accepts this withdrawal and the amount is
non-negative." z3 then hunts for a single `amt` (and a state) for which the two
handlers' balances diverge after the step. For the `good` handler `"(- b2 amt)"`,
`R` gives `b1 = b2`, so `b1 - amt = b2 - amt` and the divergence is unreachable
⟹ proven. For the `bad-msg` handler `"(+ (- b2 amt) 1)"` the new balance is one
higher, so the divergence is reachable (`sat`) ⟹ **unsafe**. Because `amt` is a
free `Int`, the solver quantifies over *all* amounts satisfying the old
contract — one proof covers every queued message the old handler would have
accepted.

### Stage 4 — four upgrades presented to the gate

```clojure
(def good      (admit-upgrade "b1"        "(- b2 amt)"))          ; carry state, simulate
(def no-data   (admit-upgrade nil         "(- b2 amt)"))          ; data migration MISSING
(def bad-data  (admit-upgrade "(- b1 100)" "(- b2 amt)"))         ; migration breaks inv
(def no-msg    (admit-upgrade "b1"         nil))                   ; message migration MISSING
(def bad-msg   (admit-upgrade "b1"        "(+ (- b2 amt) 1)"))    ; handler diverges
```

Five cases, one per path through the gate plus the happy path:

| upgrade | data migration | message migration | verdict |
|---|---|---|---|
| `good` | `"b1"` — proven | `"(- b2 amt)"` — proven | `applied` / `proven` |
| `no-data` | `nil` | `"(- b2 amt)"` | `refused` / `data-migration-lacking` |
| `bad-data` | `"(- b1 100)"` — refuted | `"(- b2 amt)"` | `refused` / `data-migration-unsafe` |
| `no-msg` | `"b1"` | `nil` | `refused` / `message-migration-lacking` |
| `bad-msg` | `"b1"` | `"(+ (- b2 amt) 1)"` — refuted | `refused` / `message-migration-unsafe` |

Note `no-data` and `no-msg` are the *structural* refusals — the solver never
runs; the gate already knows a migration is missing. `bad-data` and `bad-msg` are
the *semantic* refusals — z3 ran, found a counter-example, and the upgrade is
held. That is the "never half-shipped" edge: `good` is the only deploy that
reaches the swap.

### Stage 5 — the print

```clojure
(defn show [label r] (println (str "  " label "  → " (name (:verdict r)) " (" (name (:why r)) ")")))
(println "── the deploy gate ──")
(show "carry state + simulate " good)
(show "data migration LACKING " no-data)
(show "data migration UNSAFE  " bad-data)
(show "msg  migration LACKING " no-msg)
(show "msg  migration UNSAFE  " bad-msg)
```

`show` strips the colons off the two keywords (`(name :applied)` → `"applied"`)
and prints the verdict beside its reason — the whole point of the spike, tabulated:

```
── the deploy gate ──
  carry state + simulate   → applied (proven)
  data migration LACKING   → refused (data-migration-lacking)
  data migration UNSAFE    → refused (data-migration-unsafe)
  msg  migration LACKING   → refused (message-migration-lacking)
  msg  migration UNSAFE    → refused (message-migration-unsafe)
```

### Stage 6 — the assertions

```clojure
(def ok (and (= :applied (:verdict good))
             (= :refused (:verdict no-data))  (= :data-migration-lacking   (:why no-data))
             (= :refused (:verdict bad-data)) (= :data-migration-unsafe    (:why bad-data))
             (= :refused (:verdict no-msg))   (= :message-migration-lacking (:why no-msg))
             (= :refused (:verdict bad-msg))  (= :message-migration-unsafe  (:why bad-msg))))
```

`ok` pins four things at once: the good upgrade applies; each of the four bad
ones is refused; each refusal carries the **right distinct reason**; and the
reasons are not interchangeable (a `data-migration-lacking` that came back as
`data-migration-unsafe` fails the assertion). A machine that refused everything
for one generic reason would not pass. Then:

```clojure
(println (str (if ok "PASS" "FAIL") " 08_upgrade_refusal  (proven or held — never half-shipped)"))
```

## What's real vs modelled

This section is the honest boundary; it is the one to read carefully.

**Exercised as-is, the real organs:**

- **`system.core/migration-preserves?`** — the real function from
  `priv/lib/system/core.bl`, not a re-implementation. It builds and asks the
  genuine obligation `inv(v1) ∧ v2 = migrate ∧ ¬inv(v2)`; `unsat ⟹ preserved`.
- **`system.core/simulates?`** — the real refinement prover. It builds the real
  one-step simulation obligation `R(a,c) ∧ extra ∧ a' = a-next ∧ c' = c-next ∧
  ¬R(a',c')`, declares the primed state vars itself, and proves via `unsat`.
- **`z3/open` and the `oracle` machinery** — `z3/open` returns the supervised
  solver pool's handle; both calls go through `oracle/ask` and read the verdict
  with **`oracle/proven?`**, which is the real `(= :unsat (:status v))`. Real z3
  processes decide these questions; the answers are not simulated.
- **The legacy-text edge.** The spike passes SMT-LIB as *strings* — `decls`,
  `inv`, `R`, the next-state exprs, and the `extra` premises — exactly the shape
  `system.core`'s `as-cmds` / `asserted` / `eq-asserted` / `neg-asserted`
  helpers exist to read at the boundary ("legacy TEXT is read at the edge"). So
  the spike is exercising the real proof functions with the real string forms,
  not a toy API.

**Modelled in miniature / simplified for the probe:**

- **The service is one integer.** The "state at rest" is a single `Int` (a
  balance), and the invariant is the one-line `(>= v 0)`. There is no service
  tree, no env, no owner registry, and no durable store — the real L1 state
  migration runs over the owner registry's durable state, which this spike does
  not model.
- **The data migration is an SMT expression, not a function over real state.**
  `"b1"` and `"(- b1 100)"` are arithmetic terms relating old to new, standing
  in for `reload/migrate`'s map rewrite. The obligation proved is the arithmetic
  relation `b2 = expr(b1)`, not a migration over a live state shape.
- **The message handler is a single transition.** `simulates?` is applied to one
  step of one message, with the "old contract" written by hand as the premise
  `(>= b1 amt) ∧ (>= amt 0)`. This is one-step simulation under the invariant,
  not a full behavioural refinement over message *sequences* or all reachable
  states; the real guarantee would need the observable contract of the handler,
  not a single `amt`. `R` is likewise modelled as equality of the single
  observable (the balance) — a deliberate abstraction to exactly one observable.
- **The gate is a local pure function; the verdict is not transacted.** The
  docstring says "the reconciler transacts this", but this spike holds **no
  datom connection** — `{:verdict … :why …}` is a returned map, printed and
  asserted over. "Refusal-as-datum" is demonstrated *by shape*; the actual
  transacting of a refusal (and of drift/proof choices) is `01-reconciler.md`
  and `13-drift-and-proof.md`.
- **No reload happens at all.** There is no `reload/stage`/`commit`/`ward`/
  `migrate`, no old code kept loaded, no cutover pointer, and no live process.
  "Held, old code still serving" is modelled as a returned keyword — the *gate's*
  decision, not the swap it gates. The real reload machinery and its `:held`
  status are driven by `04-hot-reload.md`; this spike is the proof each swap
  must pass first.
- **One reason per refusal, by fixed priority.** `cond` is a chain: data before
  message, lacking before unsafe. A doubly-broken upgrade reports only the first
  failing obligation (e.g. `(admit-upgrade nil nil)` reports
  `:data-migration-lacking`, not "both lacking"). The reasons are *distinct* and
  machine-comparable, but not a full diagnosis list.
- **`unsafe` conflates refuted with undecided.** `oracle/proven?` is true only
  on `:unsat`; a `:sat` (refuted) and an `:unknown` (solver gave up) both fail
  `proven?` and both fall into `:…unsafe`. That matches the design's fail-closed
  posture ("z3 says no, *or times out*"), but the reason keyword does not
  distinguish "the solver found a counter-example" from "the solver could not
  decide". No timeout/`unknown` path is actually triggered in this run.

In short: the *proofs* — data-invariant preservation and one-step simulation —
are real z3 obligations through the real `system.core` functions; the *service,
the migration, the handler, the swap, and the transacted refusal record* are
modelled down to the least structure that lets the solver decide.

## Run it

```
./blx run research/vps_spike/08_upgrade_refusal.bl
```

Expect the five-line deploy-gate table above and the final line:

```
PASS 08_upgrade_refusal  (proven or held — never half-shipped)
```

`blx` runs the checkout-matched `bl-v2026.4` drop with this worktree's stdlib
and a `z3` for the verifier tiers; the first run pays ~10-15s of cold-start
(solver/JIT boot), not work. `08` is also one of the in-process bl spikes that
`research/vps_spike/run.sh` (no flags) runs — the loop covers `0*.bl`, so it and
`01`–`07` report together. A `FAIL` line means one of the eight `ok` checks came
back false; the printed table above it tells you which verdict drifted.

## Exercises

1. **Make the state migration lossy.** Change `good`'s data migration from
   `"b1"` to `"(- b1 10)"` — a migration that charges a fee on the way across.
   Predict: `good` flips to `refused (data-migration-unsafe)` (pick `b1 = 0` →
   `b2 = -10 < 0`), the message handler is irrelevant to that verdict, and the
   run prints `FAIL`. The lesson is the L1 posture exactly: a state migration
   that does not preserve the invariant is held *before* it ships, even though
   the code swap itself would have been safe.

2. **Make the divergent handler agree on every branch.** Change `bad-msg`'s
   handler from `"(+ (- b2 amt) 1)"` to `"(ite (= amt 0) b2 (- b2 amt))"`.
   Predict: for `amt = 0` the new balance is `b2 = b1` (unchanged) and the old is
   `b1 - 0 = b1`, so the observables agree; for `amt > 0` both subtract `amt`.
   z3 now finds no divergence ⟹ `bad-msg` flips to `applied (proven)`, and the
   run prints `FAIL` (the assertion still expects `:message-migration-unsafe`).
   A conditional is still a simulation when every branch agrees with the old
   handler — the prover checks branches, not syntax.

3. **Add an input the old contract never saw.** Add `(declare-const fee Int)` to
   `decls` and change `good`'s handler to `"(- (- b2 amt) fee)"`. Predict: `good`
   flips to `refused (message-migration-unsafe)` — z3 is free to pick `fee ≠ 0`,
   so the new handler's observable diverges by exactly `fee`, and the run prints
   `FAIL`. This is the proof quantifying over every declared input: a new handler
   that reads state the old one did not is not a simulation of it.

4. **Reorder the gate's priorities.** Swap the four `cond` clauses so the two
   message checks come before the two data checks, then feed a doubly-lacking
   upgrade — add `(admit-upgrade nil nil)` and print it. Predict: with the
   original order its reason is `:data-migration-lacking`; after the reorder it
   becomes `:message-migration-lacking`. The gate reports **one** reason, chosen
   by branch order — "distinct reason" means a stable, machine-comparable
   priority, not a complete diagnosis of everything wrong at once.
