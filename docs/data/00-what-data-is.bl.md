# data — reusable patterns for values that remember, relate, and reveal

Most programs treat data as something you push around: read it, transform it,
write it out, forget it. The `data` family is a small shelf of **reusable
patterns** for the cases where a value should do more — remember what it
computed, relate to the values it depends on, or be shared and observed while
the program runs.

These patterns are possible because BeamLisp has one native **cell** underneath
its whole state model — the same cell behind `atom`, `delay`, `derived`,
`memoize`, and `lazy-seq`. A cell is a small box that holds a value, can be read
and swapped atomically, and is owned by whoever holds it (reclaimed by the
garbage collector when the last holder lets go). Once state, caching, and
reactivity are all one substrate, a family of patterns can sit on top that would
otherwise each need their own machinery.

`data` is the shelf of patterns. It is not where the tools live — an instrument
you *run* (like the live cell dashboard) belongs in `tooling`, and *uses* these
patterns rather than being one. That separation is the point: `data` holds the
building blocks; `tooling` holds the instruments built from them.

Everything here is ordinary BeamLisp you `require`.

## The three patterns

### `data.cache` — remember

> compute once, keep it, ask what you kept

At heart, memoisation: a key and a thunk, run at most once per key, result
remembered. On top of that, content-addressing and a hot/durable tier so "once"
survives restarts, and a datalog index so the cache is *queryable* — what is
stored, how large, how often hit. The plain name is the honest one: it is a
cache. Full tour: `priv/lib/data/cache.bl.md`.

### `data.registry` — a roll-call

> let live things sign in, then list them

The shape behind any "list of active things": open connections, running jobs,
tracked values. A thing `enroll`s with a kind, a name, and whatever `meta` you
want; you `entries`, `of-kind`, `lookup`, or `retire`. One shared cell, so it is
safe across processes and needs no process to supervise. Full tour:
`priv/lib/data/registry.bl.md`.

### `data.config` — shared settings, read live

> one settings sheet everyone shares

A read-mostly bag of settings held once, in one shared cell every process reads
directly — no per-read rebuild, no per-process copy. It plugs into the
language's own dispatch: a `Config` record implements a `Settings` protocol, so
`fetch` is one verb dispatched on type, not a shadowed `get`. Overrides layer on
top of a base for per-context twists. Full tour: `priv/lib/data/config.bl.md`.

### `data.lens` — relate (the reactive core, already in the language)

> a value that follows other values

`derived` and `atom` already give you relating: a value that recomputes only
when its inputs changed, and `add-watch` to drive effects. These live in the
core language; `data` names the capability *lens* to place it on the shelf, but
introduces no new module. Tour:
`docs/memory-policy/08-one-cell-many-references.bl.md`.

## The names, and the power each carries

| pattern | verb | one word | what it gives you |
|---|---|---|---|
| `data.cache` | remember | keep | expensive results computed once, kept, queryable |
| `data.registry` | enroll | list | a safe, shared roll-call of live things |
| `data.config` | fetch | share | one live settings sheet, dispatched by type |
| `data.lens` | derive | follow | values that update themselves when inputs move |

## Tooling built on these patterns

The `tooling` namespace holds instruments that *use* `data`:

- **`tooling.pulse`** — a live dashboard of every cell, as a full page and as an
  expandable corner **chip** you inject into any live view with `with-chip`
  (the chip is hiccup, so it rides the app's own render→diff→patch loop). Its
  roll-call of tracked cells *is* a `data.registry`. Tour:
  `priv/lib/tooling/pulse.bl.md`.
- **`tooling.incremental`** — render only what changed: a component memoised on
  its inputs returns identical hiccup, and the differ prunes unchanged subtrees.
  Tour: `priv/lib/tooling/incremental.bl.md`.
- **`tooling.trace`** — why did the UI update? A causal record — fact changed →
  subtrees recomputed → patch ops shipped — that even catches the wasteful
  recompute-with-no-op. Tour: `priv/lib/tooling/trace.bl.md`.

## What is honest about `data`

- **`cache`'s datalog index is bookkeeping, not correctness.** It makes the
  cache queryable; if its table is unreachable (e.g. created by a process that
  exited), the cache still memoises correctly and the catalog simply reads
  empty. And the index is heavier than a plain map — worth it when the question
  "what is cached" matters as much as the values.
- **`config` dispatches, it does not shadow.** `fetch` is a protocol method on
  the Config type — one verb, many types — not a new `get` per module.
- **`lens` is not new code.** It names `derived`/`atom`/`add-watch`, which ship
  in the core.
- **The dashboard is an instrument, not a pattern.** It lives in `tooling` and
  stands on `data.registry`, never the other way around.

## Where to go next

- `priv/lib/data/cache.bl.md`, `registry.bl.md`, `config.bl.md` — the patterns.
- `priv/lib/tooling/pulse.bl.md`, `incremental.bl.md`, `trace.bl.md` — the
  instruments.
- `docs/memory-policy/08-one-cell-many-references.bl.md` — the one cell behind
  all of it.

The thread through everything: **one cell, many faces.** `data` is the shelf of
patterns those faces make reusable; `tooling` is the instruments built from them.
