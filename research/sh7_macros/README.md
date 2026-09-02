# sh7 — macros and hygiene (P7, the riskiest wave)

**Question.** Can the beam-lisp compiler expand macro calls, compile
`syntax-quote` templates (`` ` `` `~` `~@`), auto-gensym (`x#`), and `defmacro`
— to the same Elixir syntax tree as the existing compiler, *including* the
documented variable-capture case?

**Verdict: yes.** 30/30 across three gates, and the R1 hygiene risk is retired:
`(let [and-tmp 5] (and 1 and-tmp))` compiles byte-identically, so the capture
bug cannot occur.

## What was added to `priv/boot/compiler.bl`

- **Macro expansion.** When a call head is a macro (a var tagged
  `{:"$macro", fn}`), the call is expanded at compile time via the runtime's
  `Compiler.macroexpand_1` and the result compiled — the arguments are NOT
  pre-compiled (a macro receives them as data). A bound local shadows a macro.
- **`syntax-quote`.** `synq` builds the Elixir tree that *constructs* the
  templated form: `~x` splices the compiled value, `~@xs` splices a whole
  sequence with `RT.splice`, a list becomes `[a | [b | …]]` cons-structure, a
  vector wraps it in `Vector.new`, a symbol becomes an escaped,
  namespace-qualified symbol node, and `x#` auto-gensyms to a stable
  `x__N__auto`.
- **`defmacro`.** Records a `{:"$macro", fn}` var. The function's parameters are
  `&form`, `&env`, then the declared ones, and it uses **nil-rest**: a macro's
  trailing `& body` is nil (not `[]`) when empty.

Macro expansion reuses the runtime (`macroexpand_1`, `RT.splice`,
`Env.local_var?`/`refer_source`) — substrate the compiler *calls*, exactly the
doctrine ("declaration in `.bl`, substrate in the host").

## Why hygiene holds

The classic capture bug: a macro that expands to code using a temporary named
`and-tmp` would, at a call site that also binds `and-tmp`, capture the user's
binding. beam-lisp avoids this by namespace-qualifying template symbols and
auto-gensyming `x#`. The proof here is not a hand-argument: the `.bl` compiler
produces the **same AST** the existing (correct) compiler does for
`(let [and-tmp 5] (and 1 and-tmp))`, so it inherits the same correct behavior.

## The gates

```
macroexpand_gate.bl  10/10 — when/and/or/when-not/if-not/->/->>/cond, nested
syntax_quote_gate.bl 10/10 — `x, `(a b), ~x, ~@xs, `[..], `{..}, x#, defmacro
hygiene_gate.bl      10/10 — and-tmp capture case, when-let/if-let (auto-gensym
                             macros), threading, doto, a `-defined `unless`
```

## Four things the differential gate forced

1. **`if-not` exposed `core/not`.** A qualified name whose prefix is an existing
   *namespace* (`core/not`) is a var fetch, not a module call. Added
   `slash-target`, which resolves `alias → var`, `Uppercase → Elixir module`,
   `existing-ns → var`, else `erlang module` — matching the compiler's
   resolution order.
2. **Cons cells need a list wrapper.** An Elixir list-cons is `[{:|, [], […]}]`
   — a one-element list holding the `|` node — so a template list nests as
   `[a | [b | [c | []]]]`. The bare `|` node produced a flat, wrong shape.
3. **Auto-gensym numbering must be compared by role.** `x#` yields
   `g__49508__auto` as a *string* inside a `{:symbol, name}` node. The oracle's
   `ast-equal?` now canonicalises those `__auto` strings the same way it
   canonicalises gensym atoms — by first appearance.
4. **Macro variadic params use nil-rest.** A macro's trailing `& body` binds to
   nil when empty (`body = if raw == [] do nil else raw end`), unlike an
   ordinary fn's `()`. Threaded a `nil-rest?` flag through the fn compiler.

No regressions: 121 checks green across P3-P7.

## Reproduce

```
mix compile.beam_lisp --source-dir priv
mix beam_lisp.run research/sh7_macros/macroexpand_gate.bl
mix beam_lisp.run research/sh7_macros/syntax_quote_gate.bl
mix beam_lisp.run research/sh7_macros/hygiene_gate.bl
```
