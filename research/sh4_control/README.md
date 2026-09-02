# sh4 — binding and control forms (P4)

**Question.** Can the beam-lisp compiler handle the binding and control special
forms — `if`, `do`, `quote`, `throw`, `let`, `loop`, `recur` — producing the
same Elixir syntax tree as the existing compiler, including the tail-position
rules `recur` depends on?

**Verdict: yes.** 17/17 forms compile AST-equal to the oracle; all three
`recur` misuse cases error exactly where the existing compiler does.

## What was added to `priv/boot/compiler.bl`

- **`if`** → Elixir's `if` tree; the test is not in tail position, the branches
  keep it (so a `recur` in a branch is still legal); a missing else is `nil`.
- **`do`** → one form, or an Elixir `__block__` running forms in sequence.
- **`throw`** → `BeamLisp.ExInfo.raise_payload(x)`.
- **`quote`** → the form as data (`datum`) then `Macro.escape`d into a constant.
  Handles symbols, lists, vectors, sets, maps, and nested forms.
- **`let`** → nested immediately-called functions, one per binding, with each
  binding visible to later ones and to the body (plain-name bindings;
  destructuring is a later prototype).
- **`loop`/`recur`** → a self-re-entrant function: `recur` re-enters the loop by
  self-application, in constant stack space. `recur` is checked to be in tail
  position, inside a loop, with the right number of values.

## The comparison had to get smarter: alpha-equivalence

`let` and `loop` invent unique Elixir variables for their bindings —
`x_26026`, `i_26034`. The number comes from a global counter, so the same
source compiled twice gets different numbers. That is pure bookkeeping:
`(fn a -> a end)` and `(fn b -> b end)` are the same function.

So `self/oracle.bl`'s `ast-equal?` now **canonicalises local variables**: every
local is renamed to `v0`, `v1`, `v2`… in order of first appearance, on both
trees, before comparing. This is the standard notion of alpha-equivalence —
bound-variable names do not change meaning. A local variable is recognised by
its shape: a `{name, meta, context}` node whose context is a compiler module
atom.

## The gate

```
gate.bl         17/17 OK  — if/do/throw/quote/let/loop, nested and mixed
error_cases.bl  3/3 threw — recur outside a loop, recur not in tail position,
                            recur with the wrong argument count
```

## A trap worth recording

An early version of `compile-quote` referred to a helper that did not exist
yet. Instead of a clean "undefined function" error, **compiling the whole file
hung** — the AOT build of `compiler.bl` never finished. The lesson: a dangling
reference in a `.bl` source can make the compiler loop rather than fail loudly.
Bisecting by adding functions back one at a time found it. When a `.bl` file
suddenly will not compile, suspect a name that resolves to nothing before
suspecting anything subtle.

## Reproduce

```
mix compile.beam_lisp --source-dir priv
mix beam_lisp.run research/sh4_control/gate.bl
mix beam_lisp.run research/sh4_control/error_cases.bl
```
