# A home for checked optimization

Beam Lisp optimizes canonical ANF before emitting Core Erlang. `optimize` is the public front door. Its implementation lives together in `priv/host/optimize.bl`, pinned as `BeamLisp.Optimize` so it can help compile the compiler itself.

The compiler calls one API:

```clojure
(optimize/module descriptor)
```

That returns a validated, optimized descriptor. AOT compilation, interactive evaluation and live emission share this path.

## Look inside a decision

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

(def plan
  (opt/explain
    (descriptor
      "(lists/foldl (fn [x acc] (+ acc x)) 0 (lists/map (fn [x] (* x 2)) (lists/seq 0 31)))")))

(assert (some (fn [entry] (= :strict-map-fold (:rule entry))) (:evidence plan)))
(assert (= (:descriptor plan) (opt/module
  (descriptor
    "(lists/foldl (fn [x acc] (+ acc x)) 0 (lists/map (fn [x] (* x 2)) (lists/seq 0 31)))"))))
```

An explanation contains:

- `:descriptor`: the resulting program.
- `:evidence`: applied rules, source positions and checked conditions.
- `:refusals`: candidate rules whose conditions remain unknown.
- `:stats`: visited nodes, rewrite count and budget status.
- `:version`: the rule implementation version.

`(opt/rules)` describes the available laws. Facts come from executable ANF and lexical scope; source annotations remain source information.

## The checked laws

**Native calls.** A native function with an established arity receives a direct function call. A dominating `erlang/is_function` guard establishes that fact too. Callback evaluation order is preserved.

**Numeric domains.** Integer, float and number guards establish when a numeric operation uses the Erlang BIF branch. Other domains keep numeric-tower dispatch.

**Integer folds.** A literal, closed integer callback using addition, subtraction, multiplication and local integer bindings preserves an integer accumulator over an integer list. The compiler can specialize that callback without copying its body.

**Strict map/fold composition.** An immediately consumed `lists/map` can join a `lists/foldl` when both literal callbacks are closed total integer expressions and the source and accumulator have the required domains. The mapper runs once per element and the left-fold order stays the same. Shared lazy values and live namespace providers retain their regular path.

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

`module` avoids storing explanations during compilation. `run` returns the full result and accepts `:report?`; `explain` requests a report. `:max-nodes` is a positive rewrite-traversal budget, defaulting to 100,000. Once reached, remaining regions retain their existing forms. Descriptor validation still checks the whole input and output.

The boot pass uses checked laws without starting a solver. Unknown callable, domain, sharing or demand information is a reason to keep the regular path, while other independent rules can still apply.
