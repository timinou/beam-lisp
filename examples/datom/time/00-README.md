# `datom.time` — tempo, maximalist

Time as a value in the database that already remembers.

This directory is the demo series for `datom.time`: the beam-lisp answer to
[`ex_tempo`](https://ex-tempo.hexdocs.pm), the most complete model of *human*
time in any ecosystem. The design is written up in
[`docs/tempo-maximalist.md`](../../../docs/tempo-maximalist.md) — read that for
the argument; read these for the shape.

## The one-sentence thesis

beam-lisp already has a temporal module — `datom.time`, the `as-of` / `since`
/ `history` filters over the store (`priv/datom/time.bl`, "the database
remembers"). That module owns *transaction time*: **when the database learned
a fact**. Tempo owns the other axis, *valid time*: **when a fact is true in
the world**. They are not two libraries that share a word — they are the two
axes of one bitemporal store, and maximalist tempo is the second half of
`datom.time`.

And the representation is singular: a temporal value is a **bounded half-open
interval `[from, to)` at some resolution**, stored as a packed *value*
(`:db.type/interval`) that rides the same value-codec lane a native
`:db.type/instant` does. Not an entity, not a struct — a value, as fast and
sturdy as any date the store already holds. `02` is the demo that proves it.

## Status: all eight run green

These are runnable demos, not paper specs. The valid-time half of
`datom.time` — the `:db.type/time` value type, the interval constructors and
predicates, Allen's algebra, set operations, the `#time` reader, and the
miniKanren / z3 bridges — is built in `priv/datom/time.bl`, validated by
`test/bl/datom/time_valid_test.bl` (7 tests, 39 assertions, 0 failures), and
every file here executes end to end:

```
mix beam_lisp.run --path priv examples/datom/time/01-interval.bl   # … through 08
```

Where a demo leans on an engine that already ships — miniKanren's `run`, z3's
`check` — the comments mark it **LIVE**. A few maximalist end-states are named
inline as *the next build*, clearly separated from the running surface: the
`:~overlaps` computed-relation *edge* spelling (04 runs the same test as a
query predicate), the query-embedded `not-join` difference (05 runs it as a
`time/subtract` fold), the smeared `:possible` verdict with a counterexample
witness (07 runs the crisp `:certain` / `:impossible` poles), and ChronoLog's
`tighten` / `why` / `all-orderings` (08 runs the live z3 `consistent?`). Each
is a named follow-up in PLAN-063, and the running form proves the same thesis
today.

This is the measurement idiom the whole repo shares (`docs/jank-compat.md`,
`docs/specter-compat.md`): name what runs, name what's next, never blur the
line.

## Reading order

Each file proves exactly one row of the scorecard in `docs/tempo-maximalist.md`.
Read them in order; each builds on the representation the last one established.

| # | file | the one idea | doc § |
|---|------|--------------|-------|
| 01 | `01-interval.bl` | a date **is** a half-open interval `[from, to)`; one type, resolution varies; adjacency kills "end of day" | §0 |
| 02 | `02-value-not-entity.bl` | it is a packed **value** (`:db.type/interval`), sturdy and fast like `:instant` — round-trips, range-scans, ESC-lane fallback | §0 |
| 03 | `03-reader.bl` | `#time"…"` reads ISO 8601-2 text into an interval, **validated at read time** | §1 |
| 04 | `04-allen.bl` | Allen's 13 relations two ways: the `overlaps?` predicate **and** the `[?a :~overlaps ?b]` join — one relation, two spellings | §2 |
| 05 | `05-set-algebra.bl` | "the day minus the meetings" is `datom/q` with `not-join`; metadata rides through the join | §3 |
| 06 | `06-bitemporal.bl` | valid time × transaction time on one entity — the query neither library can express alone | §0, §6 |
| 07 | `07-uncertain.bl` | masks → miniKanren; `?`/`~` qualifications → z3's `certain` / `possible` / `impossible`, with the counterexample | §4 |
| 08 | `08-chronolog.bl` | a chronology is a db: `tighten` (fixpoint) · `consistent?` (z3) · `why` (provenance) | §7 |

## Run

```
mix beam_lisp.run --path priv examples/datom/time/01-interval.bl
```

(`--path priv` puts the `datom` / `datom.time` libraries on the load path.)
