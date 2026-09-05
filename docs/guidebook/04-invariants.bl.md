# 04 — The invariant: prove it never goes wrong

*Guidebook chapter 4. Reads after [02 — the verbs](02-the-verbs.bl.md). New to
beam-lisp assumed.*

---

## The problem this solves

Every server so far has been a promise you *hope* is kept. "Balance never goes
negative" — you wrote the `if`, you tested it twice, and you hope. Chapters
03's fence catches crashes and 07's supervisor regrows the dead, but neither
answers the quieter question: **can this process ever reach a bad state at
all?**

The invariant bundle makes the promise *checkable*. You write the rule once,
inside the server, and a verifier reads your source and proves — with a
theorem prover, not a test — that no message in any order can break it.

## Writing one

```clojure
(defserver account
  (invariant [s] (>= (:balance s) 0))   ; the rule: one line, one name for state
  (init [opening] (ok {:balance opening}))
  (handle-call [:withdraw n] :when (<= n (:balance s)) [_from s]
    (reply :ok {:balance (- (:balance s) n)})))
```

The clause names the state (`s`) and states the rule (`balance ≥ 0`). That's
the whole API. (The same promise can be written as metadata on the name —
`^{:invariant …}` — same engine, two spellings; the clause reads better.)

## Checking it

```clojure
(system/verify 'my-app/account)   ; → :ok | {:unsafe [warnings]} | :unchecked
```

One quoted name. The verifier finds the file, reads the source, opens a fresh
z3 process, and tries to prove two things:

- **Establish**: the state `init` returns already satisfies the rule.
- **Preserve**: every handler that *keeps* the rule going in *keeps* it going
  out — for all messages, all inputs the guards allow.

`{:unsafe …}` comes with rendered warnings — file, line, a caret under the
offending handler — like every other beam-lisp checker. This is a **pre-boot
gate**: run it before the process ever exists. It opens a prover per call, so
it belongs in your build or your CI, not your hot loop.

## What a proof costs you

The prover is not magic; it proves what it can *see*. The honest boundaries:

- **Guard your arithmetic.** The withdraw above is provable *because* the
  `:when` guard is the rule's own shape: the prover assumes the guard, does
  the subtraction, and the rule follows. Hide the check in a helper function
  and the proof may come back `:unchecked` — the verifier stays silent on what
  it cannot model rather than pretend.
- **`:unchecked` is not `:ok`.** No invariant, an invariant it can't parse, a
  name it can't find — all `:unchecked`, never a silent pass. (Run
  `examples/system/28_invariant_clause.bl` to see each case, including a buggy
  wallet that is *caught*.)
- **State shape matters.** The clause form understands a single-field state.
  If your state is a record of many fields, name them in the `^{:invariant}`
  meta spelling instead — the clause will honestly refuse rather than guess.

## How it composes

- **With the supervisor (07):** `(system/verify 'my-app/shop)` on a
  `defsupervisor` verifies every child and answers `:ok` only when *all* of
  them hold. The tree is only as true as its leaves.
- **With restart:** a supervisor restarts a child into its *init* state. The
  Establish half of the proof is exactly the statement that the regrown state
  is a good one — the invariant is what makes "let it crash" safe.
- **With the fence (03):** the fence is for what crosses your boundary; the
  invariant is for what stays inside. Belt and braces, each where it belongs.

## What an invariant is NOT

- **Not a test.** It proves the rule for *all* inputs the guards allow, not
  the three you tried. It also proves nothing about liveness — "the balance is
  right" is provable, "the reply eventually arrives" is a different question
  (that's the lasso tooling in `system/core.bl`, a later chapter).
- **Not a type system.** It doesn't run as you write; you ask it, at the gate.
- **Not optional once written.** If the clause is there, `defserver` compiles
  it into the module as `__invariant__/1` — the promise travels with the code,
  so anything (the verifier today, a runtime checker tomorrow) can ask for it.

## Exercises

1. Add `(invariant [s] (>= (:jobs s) 0))` to chapter 07's `worker` and verify
   it. Then remove the `inc` from the job handler and verify again — what does
   the warning point at?
2. Write a `thermostat` server whose rule is `low ≤ current ≤ high`, with a
   `:set` handler. Get it to `:ok`. Now delete the guard on `:set` — which
   verdict do you get, and why is it the *honest* one?
3. `(system/verify 'examples.guards/account)` answers `:ok`. Open
   `examples/guards.bl`, find the handler that keeps the rule, and mark the
   exact sub-expression the prover leaned on.

---

*Next: [05 — the registry](05-the-registry.bl.md): find a process by what it
is, not by its address.*
