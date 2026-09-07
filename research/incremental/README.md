# Content-addressed incremental proofs

A function's summary (footprint, termination, return type) is a **pure function
of its ANF structure**. So it is content-addressable: hash the normalized body,
and an unchanged body reuses its cached summary. After an edit, only the
functions whose *structure* changed re-prove. On a large file this turns
"re-prove everything on every keystroke" into "re-prove the one function you
touched."

## The hash must be structural

The hash is over STRUCTURE, not source text, and it is:

- **position-independent** — `strip-ann` removes every `:ann` before hashing, so
  reindenting or adding a comment does not invalidate a summary.
- **rename-invariant (alpha)** — the compiler gensyms every bound variable
  (`z` → `z_2` in one compile, `z_7` in another), so `alpha-rename` canonicalizes
  each bound `:var` to its first-occurrence order (`v0`, `v1`, …). A `:global`
  (a free callee reference) keeps its name — `double` and `triple` must not
  collide.

## Measured (research/incremental/incr.bl)

Analyze three functions, then edit: reindent `a` and add a comment (structure
unchanged), change `b`'s constant `2`→`4`, leave `c` untouched.

| pass | hits | misses |
|---|---|---|
| cold (empty cache) | — | `a b c` |
| warm (after edit) | **`a c`** | **`b`** |

`a` reindented + commented → **hit** (structure identical). `c` untouched →
**hit**. Only `b`, whose body actually changed, re-proves. Reindentation and
comments never invalidate — the hash sees through both.

## Why it matters for the LSP

The LSP (`research/lsp/`) recomputes `system.analyze` per request. On a large
module that is wasteful — a keystroke in one function should not re-prove the
other two hundred. This cache is the substrate: keep `{fn-name → {:hash
:summary}}`, and each edit invalidates only the changed function's entry (plus,
in the full version, its transitive callers — the fixpoint over just the misses,
which is cheap because everything else is a hit).

## Honest extension

This prototype caches each function's LOCAL summary. The inter-procedural
closure (`system.analyze`'s fixpoint) still needs to re-run over the misses'
dependents: when `b` changes, any function whose summary depended on `b`'s
return type or footprint must recompute too. The call graph already gives the
dependents (`analyze/call-graph` reversed), so the incremental fixpoint is:
invalidate the misses, mark their transitive callers dirty, re-run the fixpoint
over only the dirty set. The per-function content hash proven here is what makes
that set small.
