# A contract is a mock

Write down the laws a response must obey. Run those laws backwards through the
same solver that would *check* a real implementation, and the solver hands you a
response that obeys them. That response is your mock. You never wrote it; it
fell out of the contract.

This is one idea with a lot of consequences. The idea first, then everything it
unlocks.

## The one idea

beam-lisp already proves things about state machines with z3: *does this
transition preserve the invariant?* Every such question is asked as **UNSAT** —
"prove no counterexample exists." That is the checker running **forward**.

A postcondition is a predicate the response must satisfy. Ask the solver the
**other** direction — *does some response satisfy it?* — a **SAT** query. z3 does
not merely answer "yes": its **model is a concrete response value**.

```
verify :  ∀ resp. ensures(resp)   → UNSAT ⟹ the property holds        (check a real impl)
mock   :  ∃ resp. ensures(resp)   → SAT   ⟹ the model IS the response (derive a mock)
```

Same predicate. Two directions. Forward it verifies the real implementation;
backward it synthesizes a stand-in. Because both answer to *one* contract, a
mock that drifts from the contract is impossible — there is only the contract.

Nobody in the tree had ever asked z3 the SAT direction. Every existing caller
proves; this one *builds*.

## The smallest example

A weather endpoint's laws, as ordinary beam-lisp predicates over the response
fields:

```clojure
(def weather
  (mock/contract-from
    [["temp" "Int"] ["humidity" "Int"] ["code" "Int"]]
    ["(>= temp -90)" "(<= temp 60)"
     "(>= humidity 0)" "(<= humidity 100)"
     "(>= code 200)" "(<= code 599)"]))

(mock/synth port weather "")
;; → {:temp 0 :humidity 0 :code 200}   — a valid response, from the laws alone
```

Nothing there says "mock." Those are the API's laws. The mock is what you get by
reading them backward.

## What "a bit more in the contract" buys you

Everything below is unlocked by *stating more in the contract*. Each law you add
is honoured by the mock, enforced by the checker, and shared by the real impl —
one clause, three payoffs.

### 1. A real mock server: deterministic, pure

Seed the synthesis by something request-derived and the same request always
yields the same response. That is a mock *server* — a pure function from input
to response, with no hidden state:

```clojure
(defn serve [city]
  (mock/synth-seeded port weather "temp" (erlang/rem (erlang/phash2 city) 60)))

(serve "paris")  ;; → always the same response for "paris"
```

Pure means safe to run where the real impl cannot: a sandbox with no network.
(Section 6.)

### 2. Edge cases, generated — not remembered

The boundary values a hand-written mock always forgets. z3's optimizer finds the
coldest and hottest response the contract still admits:

```clojure
(mock/synth-boundary port weather "temp" :min)  ;; → {:temp -90 …}  the exact edge
(mock/synth-boundary port weather "temp" :max)  ;; → {:temp  60 …}
```

Add a law, and its two edges come with it, for free.

### 3. Adversarial responses — hostile *by construction*

Assert the **negation** of the contract and every value the solver returns is,
by definition, a violation:

```clojure
(mock/synth-invalid port weather)
;; → {:temp 61 :humidity 101 :code 0}   — every field out of contract
```

This is fault injection whose *fault type is derived from the contract itself*.
You cannot inject a "failure" the contract actually permits and mistake it for a
violation — the solver would refuse to produce one. Your negative tests can
never accidentally test a valid case.

### 4. A contradictory spec is caught before any code exists

Ask whether the contract is satisfiable at all. A law set no value can satisfy
is a broken **spec** — found with no implementation, no mock, nothing:

```clojure
(mock/contract-from [["temp" "Int"]] ["(> temp 60)" "(< temp -90)"])
(mock/satisfiable-status port that)   ;; → "unsat"  — the spec is impossible
```

The moment you can *state* a contract, you can ask if it is *realizable*. A spec
review becomes a solver query.

### 5. The reach: strings with structure, reals, and relations between fields

The mock's ceiling is the solver's expressiveness, and that is high.

**Strings with structure** — a token that is *prefixed* and *bounded*, not a
random blob:

```clojure
{:fields  [["token" "String"] ["kind" "String"]]
 :ensures ["(str.prefixof \"sk_\" token)" "(>= (str.len token) 8)"
           "(or (= kind \"bearer\") (= kind \"basic\"))"]}
;; → {:token "sk_ABCED…" :kind "bearer"}
```

**Reals** — fractional values, returned as exact rationals:

```clojure
{:fields [["rate" "Real"]] :ensures ["(> rate 0.0)" "(< rate 1.0)"]}
;; → {:rate 1/2}
```

**Relations between fields** — the law a hand-written mock cannot keep straight:
`total = subtotal + tax`. The solver returns a response where the fields
*mutually agree*, because the relation is part of the contract, so the real API
and the mock are both held to it:

```clojure
{:fields  [["subtotal" "Int"] ["tax" "Int"] ["total" "Int"]]
 :ensures ["(>= subtotal 100)" "(<= subtotal 1000)"
           "(>= tax 0)" "(<= tax 200)"
           "(= total (+ subtotal tax))"]}    ;; the cross-field invariant
;; → {:subtotal 250 :tax 8 :total 258}       — consistent, always
```

A mock that returns a `total` inconsistent with its `subtotal` and `tax` is now
*impossible to synthesize* while passing the contract.

### 6. The sandbox picks the mock — with no `if` in your code

This is the use case the whole thing was built for. An API call that, when the
sandbox forbids the capability the real impl needs, transparently resolves to
the pure mock — with **no `if sandbox` branch anywhere**:

```clojure
(defn current [city]
  (if (env/allowed? EGRESS-CAP)   ;; a question about the WORLD, not the request
    (real-current city)           ;; granted → the network impl
    (mock-current city)))         ;; withheld → the contract-derived mock
```

Run it at `:global` and it reaches the network. Run the *same call* inside a
fork that does not grant the capability, and it gets the mock — deterministic
and contract-valid — because in that world the real impl's module is
**unspeakable**: an ungranted module is a *compile* error, not a runtime check.
Fail-closed becomes fall-back-to-mock. The caller wrote `current`, never `mock`;
the environment chose.

And the swap is *safe* because the mock answers to the very contract the real
endpoint is held to: anything the caller may assume of a real response holds of
the mock too.

## The guarantee: synthesize backward, verify forward

A synthesized response is trusted only when it survives the **forward** check —
the same solver, the same predicate, run the other way. Pin the value into the
ensures and ask whether they can be violated; UNSAT means it holds:

```clojure
(mock/check port weather (mock/synth port weather ""))  ;; → true
(mock/check port weather (mock/synth-invalid port weather))  ;; → false
```

The two directions verify each other. This is the same discipline the state-
machine repairer uses: it synthesizes a guard backward, then re-runs the forward
checker and only offers a repair that makes the machine verify. A mock is a
repair for a missing server.

## The honest edge: undecidability, surfaced not hidden

Nonlinear integer arithmetic — `total = price × qty` — is undecidable. z3 will
still **synthesize** a valid one (SAT is fast), but *proving* a contradictory
nonlinear spec unsatisfiable can spin forever. So the engine bounds every query
with a solver timeout and treats the result honestly:

```clojure
(mock/satisfiable-status port nonlinear-impossible-contract)  ;; → "unknown"
```

`"unknown"` is never mistaken for `"sat"` or `"unsat"`. The engine will not
hang, and it will not claim a proof it does not have — the same
sound-warnings-only discipline the rest of the checker follows. Linear
constraints are decided both ways; nonlinear ones synthesize but may not prove.

## How it works, in one breath

- **A contract** is `{:fields [[name sort]…] :ensures [smt-string…]}`. The sorts
  are z3 theories (`Int`, `Real`, `Bool`, `String`); the ensures are beam-lisp
  prefix predicates, which are already valid SMT-LIB. `contract-from` translates
  written bl predicates through `system.smt` — the *same* translator the
  verifier uses, so mock and checker can never disagree about what a law means.
- **Synthesis** asserts the ensures (or their negation, or an optimization
  objective) and reads z3's model. The model text is valid s-expression; the
  beam-lisp reader parses it, and each `(define-fun name () Sort value)` becomes
  one field of the response map.
- **Selection** is `env/allowed?` over the impl's capability. No branch in the
  contract; the world decides.

## Where it lives

- `priv/mock.bl` — the engine: `synth`, `synth-seeded`, `synth-boundary`,
  `synth-invalid`, `satisfiable-status`, `check`, `contract-from`.
- `examples/mock/00-a-contract-is-a-mock.bl` — the core loop on integer fields.
- `examples/mock/01-how-far-it-reaches.bl` — strings, reals, relations, and the
  honest `unknown`.
- `examples/mock/02-the-sandbox-picks-the-mock.bl` — the world chooses real vs
  mock, with no branch in the caller.

## What is proven, and what is next

Proven, running against z3 4.16: all six synthesis modes, the forward round-trip,
the string/real/relational reach, deterministic seeding, and capability-driven
selection.

The natural next steps, each a real extension rather than a rewrite:

- **Contracts on `defprotocol`.** Today a contract is a value passed to `mock`.
  Carried as `^{:contract …}` metadata on protocol methods — the way
  `^{:invariant …}` already rides on a process name — a *protocol* would derive
  its own mock, and `extend-type` would install it as a pure implementation.
- **A purity gate on the mock.** `effects.bl` already infers a function's effect
  and names where an impure one leaked in. Running it over a synthesized mock
  would *prove* the mock pure — the property that makes it sandbox-safe — rather
  than trusting it.
- **Per-host egress caps** (PLAN-060 Requirement C). Today selection keys on a
  module name; with egress caps it keys on "may reach `api.weather.com:443`", so
  the mock is chosen per-endpoint, not per-module. The resolver shape does not
  change.
- **Stateful mocks as verified machines.** A mock with state (a cart, a session)
  is a transition system; `system.core/verify-process` already proves such a
  machine preserves its invariant. A stateful mock would be *checked* to honour
  its own contract over time, not just per-response.
