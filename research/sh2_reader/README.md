# sh2 — the reader, in beam-lisp (P2)

**Question.** Can a reader written in beam-lisp turn source text into the same
tree of forms the existing Elixir reader produces, for real code?

**Verdict: yes.** 308 of 309 `.bl` files in the tree read **identically**. The
one exception is a deferred extension feature that correctly errors instead of
guessing.

## What was built

`priv/boot/reader.bl` — text → forms, written in beam-lisp. It reproduces the core
grammar: lists, vectors, maps, sets, strings (all escapes, including `\uXXXX`
and UTF-8), keywords (including `:"quoted"`), symbols, numbers, `nil`/`true`/
`false`, character literals, the quote family (`'` `` ` `` `~` `~@`), `@`
deref, `#()` fn literals with `%`/`%N`/`%&`, `#_` discard, `^metadata`, and
comment/comma trivia.

It leans on `priv/boot/reader-node.bl` (the shared node vocabulary, P1) to build the
tuples, and is graded by `priv/self/oracle.bl` (the differential oracle) which
compares its output against `BeamLisp.Reader/read_all`, the answer key.

## The gate

`corpus_gate.bl` runs **every** `.bl` file under `priv/`, `examples/`,
`test/bl/`, and `bench/` through both readers and compares the trees
(source-location metadata stripped, since `read_all` drops it on both sides).

```
total: 309  OK: 308  MISMATCH: 0  ERROR: 1
```

The single ERROR is `test/bl/datom/dlit_test.bl`, which uses the data-reader
tag `#d[...]` — a deferred feature (see below). It **errors loudly** ("records
and tagged data not yet ported") rather than misreading, which is the correct
behavior for something not yet built.

## Two bugs the corpus found

Running real code found what spot-checks did not:

1. **`^metadata` leaked in.** `^{:ret int} double` was read as four separate
   forms (`^`, `{…}`, `double`, …) instead of just `double`. The answer key
   drops metadata at `read_all`, so the reader must too: read the spec, discard
   it, return the target. Added `read-meta`.
2. **UTF-8 was mangled.** The reader converted source with `binary_to_list`,
   which splits a multi-byte character (an em-dash `—`, an accent) into raw
   bytes; a later re-encode then corrupted it. The answer key uses codepoint-
   aware conversion. Switched to `unicode/characters_to_list`. This one bug
   accounted for **219** of the mismatches — every file with a non-ASCII
   character in a docstring or string.

The second is the argument for measuring against a whole corpus rather than a
handful of examples: a spot-check of ASCII inputs would have shipped it.

## Deferred (tracked, not silently wrong)

Marked in `reader.bl` with `TODO(P2-tail)` and an explicit throw:

- reader conditionals `#?(…)` / `#?@(…)`
- record literals `#Name{…}`
- tagged data readers `#tag[…]` (e.g. `#d[…]` → `datom/read-query`)
- the rebindable `@` reader-macro table (`@` is always `deref` for now)

These need the runtime reader-macro registry and are rare (one corpus file uses
one of them). They are the P2-tail, to be finished before the frontend
checkpoint.

## Reproduce

```
mix compile.beam_lisp --source-dir priv
mix beam_lisp.run research/sh2_reader/corpus_gate.bl   # the whole-tree gate
mix beam_lisp.run research/sh2_reader/spot_checks.bl   # focused cases
```
