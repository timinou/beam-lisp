# sh12 — the loop closes (P12)

Two proofs that the self-hosted compiler is real, not just AST-matching.

## 1. End-to-end: the compiler's output actually runs (`end_to_end.bl`)

The compiler doesn't just produce AST that MATCHES the oracle — it produces
working code. `end_to_end.bl` compiles forms with the `.bl` compiler, evaluates
the resulting Elixir AST, and checks the values:

```
(+ 1 2) => 3
(let [x 5 y 3] (* x y)) => 15
((fn [n] (if (< n 2) 1 n)) 5) => 5
(loop [i 0 acc 0] (if (< i 10) (recur (+ i 1) (+ acc i)) acc)) => 45
```

Closures, arithmetic, strings, tail-recursive loops — all compiled by the
beam-lisp compiler, all producing correct BEAM behavior.

## 2. The compiler analyzes itself (`examples/self/compiler-as-codebase.bl`)

Because the compiler is now a beam-lisp program, the language's own source
analyzer (codebase, backed by the datom database) ingests it and answers
questions about it:

```
functions captured: 121
arity mismatches in the compiler: (none — every call is well-formed)
what breaks if I change compile-body?
   <- compile-catch-branch, compile-defn-clause, compile-fn-clause,
      compile-let, compile-loop, compile-special, compile-try, server-body
how many functions depend on ast-node? 41
```

"What breaks if I change this?" is a **datalog query over the compiler**. The
same facts-database and queries that analyze any beam-lisp program analyze the
compiler that compiles them. This is the payoff the self-hosting effort was
building toward from both directions: the analysis tools (typed, codebase) and
the compiler now meet — the compiler is the first large program the language
reasons about about itself.

## Reproduce

```
mix beam_lisp.run research/sh12_selfanalysis/end_to_end.bl
mix beam_lisp.run examples/self/compiler-as-codebase.bl
```
