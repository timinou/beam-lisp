# datom live — the transaction-report broadcast, by example

datom keeps a durable, totally-ordered log of facts and lets any process hold a
consistent **value** of it for free. These examples add the one thing it lacked:
the ability to say **"it changed"** — and show what that unlocks, from a bare
subscription up to reactive frontend bindings.

Design doc (the spec these implement): `docs/datom-as-a-broadcast-substrate.md`.

Run any file with:

```
mix beam_lisp.run --path priv examples/datom/live/NN-name.bl
```

## The one idea

A commit is a **message**, the tx-log is the **topic**, and every BEAM broadcast
primitive is a **transport** for it. The default payload is the **delta** — the
datoms the commit wrote — so a subscriber filters what changed with *no* store
access. A dropped message is never a lost event: every payload carries the new
basis, so a subscriber that falls behind replays `(since db t)` from the log.
The broadcast is an accelerator; the log is the truth.

## Three payloads (and why the writer never projects)

| payload | shape | who emits | reader re-queries? |
|---|---|---|---|
| **delta** (default) | `[:datom/tx basis tx-datoms]` | writer | no — filter locally |
| **moment** (knob) | `[:datom/changed basis attrs]` | writer | yes — `as-of` + re-run |
| **projection** | rows/board for *(query, principal)* | **never the writer** | n/a |

The writer emits **facts**, never a projection — because a projection is a
function of *(data, who is asking)* and the writer knows only its half. A
projection is legitimate at a **reader** (per-viewer), a **projector**
(shared), or a **CRDT** (presence). That boundary is what §6.1 of the doc is
about, and examples 06 and 10–13 are its proof.

## The files

### Core L2 — the broadcast itself

| # | file | shows |
|---|---|---|
| 01 | `01-listen-delta.bl` | `listen!`; the delta in the mailbox, zero re-query |
| 02 | `02-live-defserver.bl` | a `defserver` whose db-value state stays live via `handle-info` |
| 03 | `03-attr-filter.bl` | T0 `:attrs` filter — a `:order/total` write does not wake an `:order/status` listener |
| 04 | `04-replay-gap.bl` | drop a message → `(since db t)` reconstructs it (effectively exactly-once) |
| 05 | `05-basis-knob.bl` | `{:payload :basis}` — the reader re-derives via `as-of`; when to choose it |

### The projection tier — §6.1's reactive-binding cases

Where live frontend rendering actually happens. Each maps to a case in §6.1 of
the design doc.

| # | file | §6.1 case | shows |
|---|---|---|---|
| 06 | `06-projector.bl` | B | shared materialized view: compute one board once, fan out to N identical viewers |
| 10 | `10-reactive-socket.bl` | A | per-socket binding: a basis → `as-of` → per-viewer re-project (the LiveView shape) |
| 11 | `11-reactive-diff.bl` | C | diff/patch binding: hold the answer set, emit only `{:added :removed}` from the delta |
| 12 | `12-derived-fact.bl` | D | derived state is a **fact** (a tx-fn), not a writer projection — the boundary line |
| 13 | `13-presence.bl` | E | presence binding: ephemeral membership (`:pg`) composed with the datom feed on one page |

### Filtered live queries — L3 (`datom/watch`)

The `watch` layer fires a callback only when a commit affects a declared
interest. All three interests are the *same* datalog the query engine already
speaks, so there is no second matcher to keep in agreement.

| # | file | shows |
|---|---|---|
| 07 | `07-pattern-watch.bl` | T1 `datom/watch` on a `:where` pattern, matched against the delta (reuses `unify-pattern`); assertions **and** retractions fire |
| 08 | `08-guarded-feed.bl` | `auth/guard` ∘ `datom/watch` — two principals, one app query, disjoint feeds, no leak (mirrors `examples/auth/05`) |
| 09 | `09-semantic-feed.bl` | `similar-to` bound-mode changefeed: scores only the delta's touched embeddings, and time-travels via the db value's basis |

## The guarantee, in one line

Raw BEAM `send` is at-most-once with no ordering and no replay. Over datom's
durable ordered log, the same `send` becomes a feed that is **totally ordered**
(one writer, monotonic basis), **gap-detectable and replayable** (every payload
carries the basis; `since` fills any gap), and **never emitted for a write that
did not commit** (`with` and rejected transactions are silent). That is strictly
stronger than the messaging it is built on — which is the whole point.
