# Typing the compiler with the language's own checker

The compiler is written in beam-lisp — `priv/boot/compiler.bl` is a normal program of
`defn`s. beam-lisp ships a type checker, `typed`, that reads beam-lisp source and
points at shapes that cannot be right. So one program can read another: `typed`
can read `compiler.bl`. That sentence sounds circular, but it is not — it is the
whole payoff of self-hosting, and it works for a plain, mechanical reason.

## First principle: a type is a set of tags

Forget subtyping lattices and inference algorithms for a moment. In `typed` a
type is nothing but **a set of tags** — the possible *shapes* a value could have:

```
#{:int :float :kw :string :bool :map :vec :set :fn :nil :sym :seq :list}
```

- `#{:int}` means "definitely an integer."
- `#{:int :float}` means "a number — one of these two, we don't know which."
- The empty set `#{}` means "no shape is possible" — a contradiction.
- The full set means "could be anything" — we know nothing, so we stay quiet.

Two operations are all you need:

- **meet** = set intersection. The type of a value that must satisfy *both* of
  two constraints. `#{:int :float}` meet `#{:string}` = `#{}` — nothing is both a
  number and a string.
- **union** = set union. The type of a value that could come from *either* of two
  branches.

That is the entire theory. A type is a set; meet is `∩`; union is `∪`.

## First principle: one warning, and only when it is certain

`typed` makes exactly **one** kind of complaint, and only when it is *sure*:

> at a position where a value is **required** to have some shape, its actual type
> **meets that requirement in the empty set**.

If a function's signature says argument 1 must be `#{:map}`, and the value you
pass is provably `#{:string}`, the meet is `#{}` — you handed a string where only
a map fits. That is a real bug, always, so `typed` warns. If it cannot prove the
meet is empty, it says **nothing**. Unknown is silent. This is the soundness
contract: every warning is a true error, and the price is that `typed` misses
things it cannot prove. No false alarms, ever.

## How it reads a program: walk the tree, carry an environment

`typed` walks the **reader nodes** of the source — the same tree the compiler
compiles. As it walks, it carries an environment mapping each bound name to its
current tag set, and it computes a type for every sub-expression:

- a literal `42` → `#{:int}`; `"hi"` → `#{:string}`; `[…]` → `#{:vec}`.
- a `let` binding records the bound name's type, then checks the body under it.
- an `if` whose test is a guard (`(int? x)`) **narrows**: inside the *then*
  branch, `x`'s type is meet-ed with `#{:int}`; inside the *else*, the difference
  is taken. If the *then* branch narrows `x` to `#{}`, that branch can never run —
  a dead branch — and `typed` says so.
- a **call** looks up the callee's signature (a `{:args [tagset…] :ret tagset}`
  table). For each argument, it meets the actual type against the declared type;
  an empty meet is the one warning. The call's own type is the signature's `:ret`.

Two moves make this precise rather than hand-wavy:

- **Positions ride along.** Every node the reader produced carries its
  `{:line :col :file}`. So a warning points at the exact character in the exact
  file, not at "somewhere in this function."
- **Macros are walked, not expanded — except when they must be.** `->`, `when`,
  `cond`, `and`/`or` are understood *structurally* (the checker knows their
  shape), so their positions stay the user's. An unknown macro is expanded once,
  through the compiler's own `macroexpand-1`, and the expansion is walked with the
  original position kept. The checker and the compiler agree on what a macro
  means because they call the *same* expander.

## Where the signatures come from: the compiler already wrote them

Here is the quiet part that makes it real. beam-lisp lets you annotate a function:

```clojure
(defn area ^{:args [number] :ret number} [r] (* 3.14 (* r r)))
```

That `^{:args :ret}` is **author metadata**, and the compiler stores it in the
environment as it compiles — for its own reasons, not the checker's. `typed` then
reads those annotations back out of `Env.meta` with `sigs-from-env`. Nothing is
re-declared for the checker; it reads the same facts the compiler already kept.
Annotations are *data the compiler produced*, and the checker is *another reader
of that data*. That is the pattern the whole self-aware stack is built on.

## Now point it at `compiler.bl`

`compiler.bl` is just `defn`s over reader nodes — `compile-if`, `compile-let`,
`compile-try`, `walk-calls`, and so on. Run `typed/check-source` over its text
and every one of the moves above applies to the compiler itself:

- each `defn`'s clauses are checked for **reachability** — a later clause that an
  earlier clause already fully covers is dead code, and `typed` names it.
- each call inside the compiler is checked against its callee's signature — a
  place where `compile-try` hands the wrong shape to `node-items` is exactly the
  kind of "argument meets in `#{}`" the checker exists to catch.
- guards inside the compiler narrow, so a branch that can never run — a `cond`
  arm guarded by a predicate the value already failed — shows up as unreachable.

The compiler cannot type-check itself while it is the *only* copy of the compiler
— that is the chicken-and-egg of a bootstrap. Self-hosting breaks the egg: once
`compiler.bl` is a program like any other, `typed` (which only needs *a* working
compiler, not *this* function's correctness) reads it as data. The genesis Elixir
compiler could never be read this way — it was Elixir, opaque to beam-lisp's own
tools. The `.bl` compiler is transparent to them.

## Why this is worth the trouble

The kind of bug that hid in `compile-try` — building a catch clause eagerly, so a
`try` with a `finally` and no `catch` passed `nil` into `node-items` and crashed
with a bare "not a tuple" — is precisely a **totality** bug: a dispatch that does
not cover one of its cases. `typed` sees argument-shape mismatches; its sibling
`system/model` + `system/gfp` can prove a compiler dispatch is *total* over its
cases. A compiler that is *analyzable by the language it compiles* can have that
whole class of bug found by tooling instead of by a user's confused bug report.

The leverage is not runtime speed — the BEAM caps that, and the `.bl` compiler
emits the same AST the Elixir one did. The leverage is **assurance**: the
compiler joins the corpus of programs its own type checker, its own datalog
codebase index, and its own model checker can read. It stops being a trusted
black box and becomes one more value the system can reason about.
