# A home for checked optimization

Beam Lisp optimizes canonical ANF before emitting Core Erlang. `optimize` is the public front door. Its implementation lives together in `priv/host/optimize.bl`, pinned as `BeamLisp.Optimize` so it can help compile the compiler itself. The `optimize` boot namespace is a thin facade over it; the rules exist exactly once.

The compiler calls one API:

```clojure
(optimize/module descriptor)
```

That returns a validated, optimized descriptor. AOT compilation, interactive evaluation and live emission share this path through one hook in the lowerer, so every program is offered to the optimizer and no application namespace needs its own pass. Each rule checks its own eligibility. Proven regions can benefit while other regions keep their reference form.

## Look inside a decision

Callbacks bound to names, and a mapped list bound to a name, are ordinary source. The optimizer sees through them.

```clojure
(ns docs.compiler.optimizer
  (:require [optimize :as opt] [anf :as anf] [compiler :as compiler]))

(defn descriptor [source]
  (compiler/reset-fresh!)
  (anf/module :Elixir.OptimizerGuide
    (list {:op :defn-clause :fname :run :params (list) :guard nil
           :body (compiler/compile-node (BeamLisp.Reader/read_one source)
                                        (compiler/new-env "user"))
           :ann {}})
    (list [:run 0]) (list)))

(def source
  "(let [mapper  (fn [x] (* x 2))
         reducer (fn [x acc] (+ acc x))
         mapped  (lists/map mapper (lists/seq 0 31))]
     (lists/foldl reducer 0 mapped))")

(def plan (opt/explain (descriptor source)))

(assert (some (fn [entry] (= :strict-map-fold (:rule entry))) (:evidence plan)))
(assert (= (:descriptor plan) (opt/module (descriptor source))))
```

`mapper` and `reducer` are aliases of closed integer callbacks. `mapped` has one use, the fold, so no one else can observe the list. The mapper then runs once per element inside the fold, in the same order, and the intermediate list is never built.

An explanation contains:

- `:descriptor`: the resulting program.
- `:evidence`: applied rules, source positions and checked conditions.
- `:refusals`: retained candidates, with safety/coverage or profitability reasons.
- `:stats`: visited nodes, rewrite count, callback nodes inlined and budget status.
- `:version`: the rule implementation version.

`(opt/rules)` describes the available laws. Facts come from executable ANF and lexical scope; source annotations remain source information.

## The checked laws

**Native calls.** A native function with an established arity receives a direct function call. A dominating `erlang/is_function` guard establishes that fact too. A lexical alias of a literal function carries its arity. Callback evaluation order is preserved.

**Numeric domains.** Integer, float and number guards establish when a numeric operation uses the Erlang BIF branch. Other domains keep numeric-tower dispatch.

**Integer folds.** A literal, closed integer callback using addition, subtraction, multiplication and local integer bindings preserves an integer accumulator over an integer list. The compiler can specialize that callback without copying its body.

**Callback facts.** Within a definition, the optimizer records each eligible callback where it is bound and follows local aliases of it. A name is resolved against the binding in scope at the use, never a later binding that reuses the name. Callbacks must have one clause, no guard, distinct plain parameters, and a body of integer `+`, `-`, `*`, literals, variables and local lets. Captured variables, globals, helper calls, `_` parameters, division and effects are not recognized. Recognition reads at most 64 expression nodes per callback.

**Strict map/fold composition.** A `lists/map` consumed by a `lists/foldl` joins it when both callbacks are eligible, the source and initial accumulator have the required integer domains, and nothing else can see the mapped list. Two shapes count:

- the map call written directly as the fold's list argument;
- a `let` binding of the mapped list whose body is the fold, with no other use of the binding. The accumulator expression must not mention the list and cannot raise or run effects.

The mapper runs once per element and the left-fold order stays the same. The fused fold keeps a private copy of each callback body, bounded by a per-descriptor inlining allowance (see below). Shared lazy values, escaping lists and live namespace providers retain their regular path.

**Why aliases alone are left alone.** Standalone alias specialization requires a demonstrated benefit. Rematerializing a callback can leave its original closure definition behind and grow the output without removing a traversal. The optimizer therefore only rematerializes callbacks when a fusion removes real work.

**Literal specialization.** A closed integer callback written inline at its fold is specialized without copying.

**Module identity.** A closure literal's module is the module being emitted. Standalone expression optimization keeps module identity unknown.

## Small, predictable APIs

```clojure
; Compilation: descriptor in, descriptor out.
(opt/module (descriptor "(+ 2 3)"))

; An expression under an empty lexical scope.
(assert (= :remote (:op (opt/node (anf/arith :add :+
                                       (list (anf/lit 2) (anf/lit 3)))))))

; Reference emission and bounded exploration.
(assert (= (descriptor "(+ 2 3)")
           (opt/module (descriptor "(+ 2 3)") {:enabled? false})))
(assert (:limited? (:stats (opt/explain
  (descriptor "(let [x 2] (+ x 3))") {:max-nodes 1}))))
```

`module` avoids storing explanations during compilation. `run` returns the full result and accepts `:report?`; `explain` requests a report.

Options:

- `:enabled? false` returns the input descriptor unchanged: the reference emission.
- `:max-nodes` is a positive budget, default 100,000. It bounds the rewrite traversal, and it also seeds the cumulative callback inlining allowance for the whole descriptor, so no number of fusions can copy more than that many callback nodes. The `:stats` count `:inlined-nodes`; exhausting the allowance reports `:callback-inline-budget` and leaves that region as written.

Once a budget is reached, remaining regions retain their existing forms. Descriptor validation still checks the whole input and output, so neither budget makes compilation constant-time.

There is no switch for turning a law on: a law either proves its conditions or does not apply.

## What stays on the regular path

The pass uses checked laws without starting a solver. Anything unproven keeps its baseline form, while other independent rules can still apply:

- **Unknown callables or domains.** Parameters, globals, values from other namespaces and helper results.
- **Effects and errors.** A callback that can raise, divide, perform I/O or read mutable state is never reordered or dropped.
- **Escapes and sharing.** A mapped list returned, stored, captured or used twice keeps its map.
- **Ordinary heap values.** Public arithmetic functions passed as values, maps, decimals and floats keep their normal dispatch.
- **Lazy sequences.** Shared realization, replay and native resource limits stay with the lazy runtime; the optimizer neither fuses nor reorders them.
- **Composition boundaries.** Filters, indexed maps and transducers keep their regular contracts. A longer strict map chain can retain stages outside the checked map/fold pair.

Correctness never depends on an annotation or an external tool. A missing fact costs speed, not meaning.

## Extending a law

A new rule needs executable binding and domain facts, a law preserving the relevant observations, baseline and counterexample tests, bounded generated code, and a measured benefit on ordinary source. Helper-dependent facts also need body-change invalidation; lazy rules need demand, replay and resource contracts. Build and strict cold checks validate the exact compiler generation; package audits validate a distributable.

The [research revisit ledger](../../research/optimizer-integration/README.md) names the deferred domains, their missing obligations and the evidence required to revisit each one.
