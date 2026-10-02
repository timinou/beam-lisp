# The language compiles itself

Run this tour with:

```sh
bin/bl run docs/self/the-language-compiles-itself.bl.md
```

Beam Lisp's reader, compiler and runtime hosts are Beam Lisp programs. Erlang
supplies the virtual machine and the final Core Erlang → BEAM step.

## 1. Write an ordinary program

```clojure
(ns self-hosting.tour
  (:require [compiler :as c] [codebase :as cb]))

(defn sum-to [n]
  (reduce + 0 (range (+ n 1))))

(assert (= 5050 (sum-to 100)))
```

Self-hosting changes who implements the language, not how you use `reduce`.

## 2. Read text as data

```clojure
(def forms (BeamLisp.Reader/read_string "(+ 1 2)"))
(assert (= 1 (count forms)))
```

The reader returns structured forms. The compiler consumes those values rather
than guessing meaning from strings.

## 3. Compile a form

```clojure
(def form (first forms))
(def anf (c/compile-node form (c/new-env "self-hosting.tour")))
(assert (map? anf))
(assert (= 3 (c/eval-form form (c/new-env "self-hosting.tour"))))
```

`compile-node` produces **bl-ANF**, the shared intermediate representation.
`eval-form` compiles and runs the form. The lowering path is:

```text
text → reader forms → bl-ANF → Core Erlang → .beam
```

The emitter folds an own closure's module identity when it is provable. A plain
BEAM function call uses a direct function-kind check. Both avoid unnecessary
work while preserving live namespace bindings and host capability checks.

## 4. Query code as data

```clojure
(def facts (cb/index-source {} "example" "(defn double [x] (erlang/* x 2))"))
(assert (seq (:fn facts)))
(assert (seq (:calls facts)))
```

The result contains definition and call facts. Local helper calls can carry an
inherited loop context: a file read inside a helper still matters when a map
calls that helper for every row. Recursive and external contexts stay explicitly
partial. A zero syntactic loop depth is not a zero-cost proof.

## 5. Bootstrap from checked bytecode

`priv/bootstrap/seed/` supplies the compiler needed to build the compiler. Its
manifest verifies source identity, generation and module hashes. Pinned hosts
keep exact names such as `BeamLisp.Reader`; their source is in `priv/host/*.bl`.

The build includes source and literate-source extensions. Ordinary body changes
reuse consumers; interface changes rebuild them; macro dependencies and compiler
generations have stronger invalidation rules. See
[namespace loading](../namespace-loading.md) for the boundaries.

## 6. Learn what the tools prove

Analysis includes every function clause and its guard. SMT inlining selects an
exact supported arity. Host purity comes from exact operation signatures, not a
module name. A generator-aware shrink keeps a counterexample inside its domain.

**Unknown means keep the generic behavior.** This rule lets a self-hosted
compiler improve its own execution without quietly changing the language.
