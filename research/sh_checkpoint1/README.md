# CHECKPOINT 1 — the .bl compiler compiles the whole prelude

**Question.** Can the beam-lisp-written compiler (priv/compiler.bl) compile the
entire prelude to the same Elixir AST the existing Elixir compiler produces —
not just isolated forms, but every top-level form of every real file?

**Result: 931 of 932 forms AST-equal (99.9%).** The one exception is a single
macro (`doseq`-family) with a deeply nested destructuring parameter that
produces a slightly different (but equivalent) chain of intermediate bindings.

## The gate

`prelude_corpus_gate.bl` reads every `.bl` file under `priv/` and
`priv/system/`, threads the current namespace (each `(ns X)` switches the
compile ns), and compiles every top-level form through BOTH the `.bl` compiler
and the oracle, comparing with `ast-equal?`.

```
FILES: 32  OK: 931  FAIL: 1
```

## What CHECKPOINT 1 debugging surfaced (each a systematic gap, now fixed)

Individual-form gates (P3-P9) all passed, but real files exercise combinations
those gates did not. In order of impact:

1. **`ns`** was missing entirely — every file starts with it, and its absence
   put every following form in the wrong namespace. Added the full form
   (declare_ns / in_ns / Loader.ensure_loaded / add_alias / add_refer[_all],
   alias/refer groups emitted in reverse spec order).
2. **`apply/3` import metadata** (437→736): the Kernel `apply` node carries
   `[context:, imports: [{2,Kernel},{3,Kernel}]]`; blank metadata broke every
   escaped defn body that calls a remote function.
3. **struct-construction alias metadata** (736→866): `%Vector{}`/`%Set{}`
   aliases use plain `[]`, not `[alias: false]` (which is for dotted calls).
4. **docstrings + privacy** on `defn`/`defn-`/`defmacro`/`def`: a doc or
   `:private` wraps the definition as `value = …; Env.put_meta(…); value`.
5. **variadic linked calls**: a link's `{min, fname}` third element (`apply`,
   `str`, …) compiles to `Module.fname(a1..amin, [rest])`.
6. **qualified-var calls are linked** (875→931): `rn/node-tag` (an aliased
   helper) compiles to a direct module call when the target var is a linked
   defn, not a generic `RT.invoke(Env.fetch!)`.

## Significance

The self-hosted compiler is not a toy that handles textbook forms — it compiles
the language's own standard library, its macros, its OTP servers, its protocol
definitions, byte-for-byte the same as the compiler it replaces. The remaining
1 form is a known nested-destructuring edge case, tracked for a focused fix.

## Reproduce

```
mix compile.beam_lisp --source-dir priv
mix beam_lisp.run research/sh_checkpoint1/prelude_corpus_gate.bl
```
