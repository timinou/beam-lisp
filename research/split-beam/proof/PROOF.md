# Split on BEAM — proof

Every showcase runs with its **server half natively on BEAM** (split.core +
split.web, one `bl serve`) and its **browser half** compiled to JavaScript from
the same file. Measured 2026-09-26.

## The verifiers, against BEAM

`research/js-actors/split-test-kit.mjs` boots `bl serve research/split-beam/serve.bl`
for each verifier. The checks themselves are the ones the Node server passed.

| Verifier | Checks | What it drives |
|---|---|---|
| `verify-split.mjs` | 28 | launch board: placement, closures, HTTP contract, the BL client, rebases, guards |
| `verify-outline.mjs` | 22 | recursion proofs, nested wire depth 24, add/toggle/remove in a tree |
| `verify-groceries.mjs` | 22 | predictions, queue, rebase conflicts, divergence, offline drain, nonces |
| `verify-team.mjs` | 30 | sessions, stamping, permission matrix, feed, presence, as-of, **restart replay from datom/fjall**, forged log fails boot |
| `verify-triage.mjs` | 18 | keys, drag reorder, inline rename, refused ids |
| `verify-ledger.mjs` | 6 | exact integers past 2^53 over HTTP and in the client |
| `verify-durable-ack.mjs` | 2 | a refused log append is never acknowledged; the service stays closed |

BEAM tests: `bl test test/bl/split/` — app_test 36 (every app hashes to the
browser's digest; the authority decides; replay; durable-before-ack),
web_test 44 (sessions, codec, codepoints, depth, exact digits, the log).

## In the browser (puppeteer, one BEAM serving all six on :8795)

| App | Done in the browser | Result |
|---|---|---|
| gallery | `/` | six cards, each links to `/<app>/` (`gallery.png`) |
| launch board | add "Ship on BEAM" | rev 0 → 1, row shown (`showcase.png`) |
| outline | toggle "Magic link" | rev 1, Sign-up flow rolls up 2/3 (`outline.png`) |
| groceries | Go offline, tick ×2 and +1, Go online | "Offline · 3 changes waiting" → rev 3, "All changes saved" |
| team | sign in as Ana, move a card, Undo; **kill the server, restart**; sign in; scrub to rev 1 | `SPLIT REPLAYED 2 commits for team`; feed intact; "Revision 1 — the board as it was then. Read-only." (`team-history.png`) |
| triage | keys j j x | rev 1, row 3 fixed and selected (`triage.png`) |
| ledger | add income 12 345 678 901 234 567.89 | balance 12 435 750 893 785 710.85 = 1 243 575 089 378 571 085 cents, equal to the exact sum (`ledger.png`) |

## Found and fixed on the way

- `count` of a string differs by runtime (graphemes on BEAM, UTF-16 units in
  JS): the wire's `[:text min max]` now counts codepoints on both.
- `boolean?` was missing from BEAM's core.
- Bandit tells a streaming handler nothing when its client leaves; streams now
  write a 1 s heartbeat, so presence and stream slots free within a second.
- JSON numbers past 2^53 would be rounded by the browser: the transport sends
  them as digit strings (`wire-json`), as the codec expects.
- The page's grid let the board's min-content width push under the explainer
  panel (visible on the team board); grid items now shrink (`min-width: 0`).
- Two verifier races the slower-to-answer BEAM server exposed (a view awaited
  before the settle trace; a fixed 60 ms sleep).

## Independent security review of the BEAM transport

A separate reviewer read `priv/lib/split/{web,core,log,wire}.bl` and `split.bl`
(read-only, no server run) and reported nine defects; all are fixed in
feeb0b6f and pinned by tests where a test can reach them.

| Severity | Finding | Fix | Pinned by |
|---|---|---|---|
| high | an answer arriving after a 4 s timeout could satisfy the next request on the same keep-alive connection | every question carries a fresh reference; answers echo it | app_test `an-old-answer-never-answers-a-new-question` |
| high | two servers could open one fjall keyspace and commit divergent histories | `<keyspace>.owner`, created exclusively, names the owning OS process; a live owner refuses, a dead one is taken over | web_test `a-log-has-one-owner` |
| high | the hub's tab-per-request map grew on every non-committing intent | the tab rides on the proposal and returns in the snapshot; no map | (structural: the map is gone) |
| medium | bl.json reads an object keyed by serde's private number token as a number | such a body is refused 400 | verify-shell |
| medium | method/Origin checked after reading the body, answered on the stale conn | checked first (`write-refusal`) | verify-shell |
| medium | one cookie path for all mounts: app B's login clobbered app A's | `Path=/<app>/` when mounted | browser: `Path=/team/` observed |
| medium | read APIs answered any method; a POST opened a stream | GET only, else 405 | verify-shell |
| medium | login with the authority gone said 403 unknown-person | 503 | code review |
| medium | an event stream never noticed its hub dying | streams monitor the hub and end | code review |

Verified as holding by the same review: session-based actor stamping (a
proposal naming an actor is malformed), no attacker-controlled atoms, MAC
verification in constant time, per-mount session tables, the body limit
applied before parsing, wire bounds, loopback Host and path checks, append +
fsync before acknowledgement, and fail-closed replay.
