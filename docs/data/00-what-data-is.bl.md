# data — values that remember, relate, and reveal themselves

Most programs treat data as something you push around: read it, transform it,
write it out, forget it. The `data` family treats data as something *alive* — a
value that can remember what it computed, relate to the values it depends on,
and reveal its own state to you while the program runs.

This is possible because BeamLisp has one native **cell** underneath its whole
state model — the same cell behind `atom`, `delay`, `derived`, `memoize`, and
`lazy-seq`. A cell is a small box that holds a value, can be read and swapped
atomically, and is owned by whoever holds it (reclaimed by the garbage collector
when the last holder lets go). Once state, caching, and reactivity are all *one*
substrate, a family of tools can sit on top that would otherwise each need their
own machinery. That family is `data`.

Everything here is ordinary BeamLisp. There is no new syntax to learn; `data`
modules are libraries you `require`.

## The three verbs of living data

`data` is organized around three things a living value can do. Each is a
namespace, named for the power it gives you.

### `data.cache` — *remember*

> compute once, keep forever, and ask what you kept

A `cache` is a content-addressed cache: a value's identity is the hash of its
inputs, so the same inputs return the same slot — this run, and (with a
directory) the next. Two tiers, one door: a hot tier in memory in front of a
durable tier on disk. What makes it `data` and not just a cache: **every entry
is also a fact in a small datalog database**, so the cache is queryable. "What
is cached, how large, how often hit, by which store" is a `q`, not a private
scan.

```beam-lisp
; (illustrative — see data.cache for the runnable tour)
; (require '[data.cache :as cache])
; (def v (cache/open "gemini" {:dir "cache/gemini"}))
; (cache/get! v prompt (fn [] (call-the-model prompt)))   ; runs at most once
; (cache/hottest v 10)                                     ; what's earning its slot
```

Read the full, runnable introduction in `priv/lib/data/cache.bl.md` — the module
*is* its own literate tour.

### `data.lens` — *relate* (the reactive core, already in the language)

> a value that follows other values

`derived` and `atom` already give you relating: `(derived [a b] …)` is a value
that recomputes only when `a` or `b` actually changed, and `add-watch` lets a
change drive an effect. These live in the core language (`lib/beam_lisp/`), and
the tutorial `docs/memory-policy/08-one-cell-many-references.bl.md` is their
tour. `data` names this capability *lens* to make its role legible — a lens is a
view onto other values that stays in focus as they move — but it introduces no
new module; it points at what the language already has.

### `data.pulse` — *reveal*

> watch your program's living state breathe

`pulse` is a live dashboard of the cells themselves. Every atom, delay, derived,
and cache is a cell; `pulse` shows the native vitals (how many cells are alive,
how many bytes they retain) as ground truth, and — for cells that opt in with
`track` — a labelled, live table of their current values. Served into any app in
dev mode with two route lines. It is deliberately a bold, dark instrument panel,
unlike the document-like look of the rest of the stack, because it is an
instrument, not a page.

Read the full introduction in `priv/lib/data/pulse.bl.md`.

## Why these three, and why these names

The names are chosen so the *power* is legible from the word:

| namespace | verb | one word | what it means for you |
|---|---|---|---|
| `data.cache` | remember | keep | expensive results computed once, kept, and queryable |
| `data.lens` | relate | follow | values that update themselves when their inputs move |
| `data.pulse` | reveal | see | your program's living state, visible as it runs |

A cache is where you *keep* things safe and retrievable. A lens is what you look
*through* to see a value derived from others. A pulse is the *sign of life* you
watch. Together they cover the three things that make data feel alive rather than
inert: it persists, it connects, and it is observable.

## What is honest about `data`

- **`cache`'s datalog index is heavier than a plain map.** You buy a queryable,
  watchable catalog; for a cache of thousands that is a rounding error, for tens
  of millions you would sample or compact. Reach for it when the *question*
  "what is cached" matters as much as the values.
- **`pulse`'s per-cell table is opt-in.** The runtime reports an *aggregate* —
  it does not enumerate individual cells — so the labelled rows are exactly the
  cells that called `track`, never a fabricated list. The vitals are the floor
  of truth; the registry is the lens you choose to add.
- **`lens` is not new code.** It is a name for `derived`/`atom`/`add-watch`,
  which already ship in the core. `data` gives the capability a home in the
  mental map without duplicating the implementation.

## Where to go next

- `priv/lib/data/cache.bl.md` — the cache that remembers and can be queried.
- `priv/lib/data/pulse.bl.md` — the dashboard that reveals living state.
- `docs/memory-policy/08-one-cell-many-references.bl.md` — the one cell behind
  atom, delay, derived, and memoize, which everything in `data` stands on.
- `docs/memory-policy/shared-lazy-values.bl.md` — why ownership follows
  references, the property that makes a cache.s hot tier reclaim itself.

The thread through all of it: **one cell, many faces.** `data` is the family of
faces that make a value remember, relate, and reveal.
