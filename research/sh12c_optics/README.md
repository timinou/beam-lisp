# sh12c — AST passes as optics traversals (P12c)

Nugget 7: a compiler AST pass (line/meta-stamping) is a `path + transform`,
composable via optics, not hand-rolled recursion.

`ast_as_optics.bl` defines a `list-items` traversal over a reader list node —
its `:view` is every child, its `:over` maps a transform and rebuilds the node —
and shows `view`/`over`/stamp working on `(foo a b c)`:

```
view all children:  [foo a b c]
stamped tags:       ["sym:foo" "sym:a" "sym:b" "sym:c"]
```

A pass is `(over list-items stamp ast)`. Traversals compose with `*>` (the
optics path combinator), so a deep-walk pass (all-list-nodes, recursive) is
built by composing `list-items` with itself — the same shape at every depth,
no bespoke recursion per pass.

This is a tier-1 capability: it depends on the optics library, which the kernel
compiles. Correctness lives in the kernel's inline stamping; this is the
composable, principled way to express the same at tier-1. The full recursive
all-nodes traversal is the production form; this demo proves the shape.

## Reproduce
```
mix beam_lisp.run research/sh12c_optics/ast_as_optics.bl
```
