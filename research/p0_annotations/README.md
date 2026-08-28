# P0 — the annotation pipe: findings + convention

Verified 2026-08-28, worktree `feat/type-inference`. Every claim below was
run, not read.

## What survives, end to end

```
(defn ^{:args [int] :ret int} double [x] (* x 2))
```

reader (`^` → `{:meta, sym, map}`) → compiler `var_meta_ast` →
`Env.put_meta` → `Env.meta/2` returns `{:ok, %{args: [int], ret: int}}`
→ `Env.ns_defs` persists the entry → **AOT `compile_file` preserves it**
and the closure cache does not disturb it.

Multiple `^` forms stack: `^:opaque ^{:decreasing (count xs)}` →
`%{opaque: true, decreasing: (count xs)}`.

## The compiler fix this required (BUG, root-caused, TDD'd)

Metadata values were COMPILED (evaluated at defn time): `:args [int]`
stored `&Core.int/1` (a fn capture), a bare `:ret int` stored a raw
reader tuple, and a type *expression* like `(fn [int] bool)` would have
been CALLED. Type annotations are data — the checker parses them, the
language must not run them. Clojure never evaluates metadata either.

Fix (`lib/beam_lisp/compiler.ex`, `attr_value_ast`): reader-attached
values go through `datum/1` (quote's own form→data bridge); macro-attached
runtime data escapes directly; one `(quote …)` layer is stripped because
both the source spelling `'([x])` and Specter's `(list 'quote …)` stamp
use it to MEAN "the datum, literally".

Regression coverage: `test/bl/prelude_test.bl`
`var-metadata-values-are-data` + `wave27_macrometa_test.exs` (6/6) +
`specter_compat_test.exs` (13/13, the defnav `:arglists` stamp).

## The annotation convention (v1)

- **Annotate the NAME**: `(defn ^{...} f [x] …)`. Annotating the params
  vector (`(defn f ^{...} [x] …)`) is a parse error today — the meta
  lands on the vector and defn reads it as a clause.
- **Core keys**: `:args` (vector of type expressions), `:ret`,
  `:opaque` (trust the annotation, don't look through the defn — the
  Lean reducibility knob, L9), `:decreasing` (termination measure
  expression, L13).
- **Type expressions are data**: `int`, `(fn [int] bool)`,
  `(U int string)` — the checker's grammar, never evaluated.
- **Multi-arity**: `:arities {1 {:args [int] :ret int}}` — plain meta
  data, no compiler support needed; the checker interprets it.
- **Namespace opt-in**: `(ns foo ^:typed)` — ns-level meta already flows
  through `capture_ns_decl` in AOT.

## What this unblocks

P1 (lattice reads `:args`/`:ret`), P0-consuming invariants 7–9 (cached
signature tables, evidence table), and the Lean-tier keys (`:opaque`,
`:decreasing`) needed no further language changes — the pipe is generic.
