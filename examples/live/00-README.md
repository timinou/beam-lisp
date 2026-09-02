# live — hiccup views over a datom conn, by example

A reactive UI layer for beam-lisp: a view is a **pure function `db → hiccup`**,
an event is a **fact**, a socket's state is a **session datom conn**, and the
DOM diff rides on **fact-deltas**. Everything LiveView does, plus the three
things it structurally cannot — provable-sound incremental diffs, auth as the
same datalog as the query, and free time-travel.

Design: `!tasks/plans/PLAN-052-*.org`. The layer lives in `priv/lib/live/`
(`hiccup.bl` · `diff.bl` · `socket.bl`) and rests on the W0 language fix that
made `^{:key …}` reach runtime collections.

Run any file with:

```
mix beam_lisp.run --path priv examples/live/NN-name.bl
```

## The ladder — zero to the whole thing

| # | file | teaches |
|---|---|---|
| 01 | `01-hiccup.bl` | a view is a function → hiccup → HTML: tag shorthand, seq splice, escaping |
| 02 | `02-diff.bl` | minimal keyed patches: text/insert/remove/**move** — better than string diff |
| 03 | `03-view-is-a-function.bl` | the view is pure, so a whole page is unit-testable with `=` |
| 05 | `05-two-tabs.bl` | **two viewers converge on one write, through the log** — the thesis |
| 06 | `06-session-cart.bl` | per-socket state that is a *database* (session conn), self-cleaning |
| 07 | `07-guarded-live.bl` | the view is row-scoped and the write is gated — auth as datalog |
| 08 | `08-optimistic.bl` | optimistic UI with a **real** rollback source (the log, not a guess) |
| 09 | `09-undo-redo.bl` | undo is a **basis pointer** over the session conn — no undo stack |

## The one idea per example

- **01–03** — the view is data. No template, no DSL; a function you call, print,
  and test. Its output diffs into minimal, keyed patches.
- **05** — the loop closes through the durable log, so N tabs converge on one
  fact without talking to each other. LiveView's loop never leaves one process.
- **06** — a socket's ephemeral state can be a full in-memory datom conn: it
  gets `q`/`pull`/`as-of`/`watch` for free and dies with the socket process.
- **07** — authorization *is* the query: `auth/guard` scopes the view (a
  forbidden row is never selected), and an intent is authorized before it can
  commit. The guard's monotonicity is also the live diff's soundness gate.
- **08** — the optimistic value is a socket local; the authoritative value is a
  fact. Reconcile clears the local on the commit echo; a denial rolls it back to
  the last committed fact.
- **09** — the session log *is* the history and `as-of` *is* the time machine,
  so undo/redo is `(assign :at prev-basis)` — the same view over a coordinate.

## Verified in-repo

Every example runs clean under `mix test` (the `examples/**/*.bl` glob executes
each; a crash fails the suite). The server-side loop is proven headless by
`test/bl/live/*_test.bl` (55 tests). The browser half — a real Chromium applying
the patches — is the `live.browser` Playwright harness (W5).
