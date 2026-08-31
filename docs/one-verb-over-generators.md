# One verb over generators

Mocking, fuzzing, coverage, and proof were four tools. They are one operation
wearing four costumes:

```
(quantifier [var generator] predicate) → verdict
```

`veritas` is that one verb. Pick a quantifier, hand it a typed generator and a
predicate, and read a verdict that states **how sure it is** — proven, witnessed,
refuted, or unknown. The confidence is a field, never a footnote.

## The one idea

Every question these tools asked is a quantified statement over a domain:

| you wanted | you write | it is |
|---|---|---|
| a mock — some value satisfying a spec | `(exists [v gen] spec)` | ∃ |
| a property test — every input holds | `(for-all [v gen] spec)` | ∀ |
| a coverage lint — every input handled | `(covers fn gen)` | ∀ over the fn's guards |
| the fault space — a value wrong for one law | `(exists [v gen] (and (not lawᵢ) rest))` | ∃¬ |

Four questions, one verb, distinguished only by the quantifier. They fragmented
into four tools only because three things were left implicit — the **generator**
was ad-hoc ranges, the **predicate** was a stringly-typed blob, and the
**verdict** hid whether it had proved anything or merely sampled. Make those
three explicit and the four tools collapse into one.

## The three nouns

### 1. `gen` — a typed generator that feeds three engines

A generator is the object that unifies the engines. Each one knows how to do
three things, and `check` uses whichever is strongest:

```
gen-sample     → witnesses          → the FUZZ engine
gen-enumerate  → a finite set | :inf → the EXHAUSTIVE engine
gen-constrain  → z3 decls + asserts  → the SYMBOLIC engine
```

The algebra:

```clojure
(v/int-of -90 60)                 ; Int theory
(v/real-of 0.0 1.0)               ; Real theory, exact rationals
(v/string-of "sk_" 8 32)          ; String theory — prefix + length bounds
(v/bool-of)                       ; finite ⇒ exhaustive proofs
(v/one-of 200 404 500)            ; a finite value set
(v/tuple-of a b)                  ; a product, for multi-arg queries
(v/any-of)                        ; the UNION of every type — the coverage keystone
```

`gen/any` is the keystone for coverage: it spans every type, so a check over it
**witnesses type-partiality automatically** — you never have to remember to build
a mixed domain. A `kind` function missing a clause for floats is caught because
`gen/any` yields a float.

Because a generator carries its own z3 theory, the domain choice *is* the theory
choice. Hand `check` an `int-of` and it reasons in Int; a `real-of` and it
reasons in Real; nothing else changes.

### 2. `spec` — a predicate that composes and cannot leak

A spec is an ordinary beam-lisp predicate over the bound variable, as source. It
is evaluated as a self-contained lambda — `((fn [v] spec) value)` — so it
composes freely and nothing from the caller's namespace can leak into it. When
the spec is in the linear-arithmetic-or-theory fragment, it is also handed to
`system.smt` — **the same translator the verifier uses** — so a spec means
exactly the same thing to the mock and to the checker. They can never disagree.

### 3. `check` — one verb, a modal verdict

Every answer carries its **modality**, so a sample can never pose as a proof:

```
:proven     discharged symbolically (z3) or exhaustively (a finite domain) — a real proof
:witnessed  sampled; no counterexample found — NOT a proof
:refuted    a definite counterexample, with :witness and (for ∀) :shrunk
:unknown    undecidable or timed out — the honest nothing
```

`check` runs an **engine escalator** — the strongest modality the `(gen, pred)`
pair supports:

```
constrain-able ∧ pred in an SMT theory  → symbolic     → :proven | :refuted | :unknown
else the generator enumerates finitely   → exhaustive   → :proven | :refuted
else                                       → sample+shrink → :witnessed | :refuted
```

You never pick an engine. You pick a generator and a predicate; the strongest
engine they jointly support is what answers.

## Worked examples

```clojure
(require '[veritas :as v] '[z3])
(def port (z3/open))

;; exists = the MOCK — z3 solves it, the model IS the value
(v/exists port "temp" (v/int-of -90 60) "(> temp 50)")
;; → {:modality :proven :engine :z3 :witness 51}

;; a structured token, from the String theory
(v/exists port "tok" (v/string-of "sk_" 8 16) "(str-prefix? \"sk_\" tok)")
;; → {:modality :proven :engine :z3 :witness "sk_ABCED"}

;; for-all = the PROPERTY TEST — a real ∀ proof when linear
(v/for-all port "n" (v/int-of 0 100) "(>= n 0)")
;; → {:modality :proven :engine :z3}

(v/for-all port "n" (v/int-of 0 100) "(< n 50)")
;; → {:modality :refuted :engine :z3 :witness 50}

;; covers = the COVERAGE LINT — the "spec" is the function's own guards
(def classify "(defn classify ([n] :when (pos? n) :p) ([n] :when (neg? n) :neg))")
(v/covers port classify (v/int-of -5 5))
;; → {:modality :refuted :engine :enumerate :witness 0}   ; zero falls through
(v/covers port (str classify " …plus a zero clause") (v/int-of -5 5))
;; → {:modality :proven :engine :enumerate}               ; exhaustive over a finite domain

;; gen/any witnesses type-partiality with no mixed domain to remember
(v/for-all port "x" (v/any-of) "(int? x)")
;; → {:modality :refuted :engine :sample :witness 1.5}
```

## The fault space is `exists`, negated

"A value wrong for exactly law *i*" needs no new machinery — it is
`(exists [v gen] (and (not lawᵢ) (every other law)))`. And the verdict's
modality is itself the finding:

```clojure
(v/faults port {:gen (v/int-of -100 100)
                :laws ["(>= v -40)" "(<= v 60)" "(>= v -50)"]})
;; → [{:law 0 :modality :proven :isolated-fault -50 :implied false}
;;    {:law 1 :modality :proven :isolated-fault 61  :implied false}
;;    {:law 2 :modality :proven :isolated-fault nil :implied true}]
```

Law 2 (`>= v -50`) comes back `:implied` — z3 **proved** it cannot be broken
while the others hold, because anything below −50 is already below −40. That is a
redundant law in the spec, *proven* redundant, not guessed. The fault space told
on the contract, and the modality carried the finding.

## Every honest limitation of the four tools, dissolved

The four tools (`mock`, `fault`, `fuzz`, and the coverage check) each shipped
with a caveat. Unifying them removes each one:

| limitation | dissolved by |
|---|---|
| a sample silently read as a proof | `:modality` states proven / witnessed / unknown |
| domain type-blind (missed a float gap) | `gen/any` + `gen-tag` — generators span their type |
| hand-written numeric ranges | typed generators; `gen-from-type` derives the domain |
| guard vocabulary not self-contained | specs evaluate as a lambda in the function's own terms |
| `unsat` meant "none in my grid" | `gen-constrain` → a real z3 ∀/∃; `:proven` is explicit |
| no strings, reals, nonlinear | z3 theories via `system.smt`; `:unknown` when it can't |
| three separate tools | one `check`; `exists`/`for-all`/`covers` differ only in quantifier |

## How it works, in one breath

- A **generator** is a `defrecord`, so its type dispatches the `Gen` protocol
  **globally** — across require boundaries. (Multimethods are namespace-local and
  will not dispatch from a requiring module; that is why generators are records,
  not `:gen/kind` maps.)
- A **spec** is translated by `system.smt/of-source` — the verifier's own
  translator — so veritas inherits Int, Real, Bool, String, and enum theories for
  free, and cannot disagree with the checker about what a predicate means.
- **`check`** tries z3, then finite enumeration, then sampling, and labels the
  result with the strongest modality it earned. Every z3 call carries a timeout,
  so an undecidable query yields `:unknown`, never a hang.

## Where it lives

- `priv/veritas.bl` — the engine: the `Gen` protocol + generators, `smt-of` (the
  `system.smt` seam), `check` with its escalator, and the sugar `exists`,
  `for-all`, `covers`, `faults`, `isolate-fault`, `with-solver`.
- `examples/veritas/00-one-verb.bl` — mock, property, and lint as one verb.
- `examples/veritas/01-the-generator-algebra.bl` — one generator, three engines.
- `examples/veritas/02-faults-are-queries.bl` — the fault space as `exists`-not.
- `test/bl/veritas/veritas_test.bl` — 11 tests over the three engines, the
  modality discipline, coverage, and proven redundancy.

## Relationship to the tools it unifies

`veritas` is the general form of `priv/mock.bl` (∃ over a contract),
`priv/mock/fault.bl` (∃¬ over a contract), and `priv/fuzz.bl` (∀ over a
function's guards). Those modules still run and are still tested; veritas is the
one surface new code should reach for, and the older three are candidates to
become thin wrappers over it — a cutover to track separately, so their green
tests are re-pointed rather than broken.
