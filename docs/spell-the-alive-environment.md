# Spell — the alive environment

> Design synthesis for the new standalone Spell app. Every "exists" claim in
> this document was verified against the tree on 2026-09-01. Companion plan:
> `!tasks/plans/PLAN-070-spell-the-alive-environment.org`.

## Thesis

**Spell is not an IDE built on beam-lisp. Spell is beam-lisp's own boot mode,
made visible.**

The README's chain — *the language is the harness, the harness is the runtime,
the runtime is the application* — has one missing link: nothing makes the
harness *legible* while you are inside it. Nine organs already exist, each
proven by examples and tests, each living in its own folder, each booted by a
hand-written `mix beam_lisp.run` invocation:

| organ | lives at | proves |
|---|---|---|
| code as facts | `priv/std/codebase.bl` | source → datom → impact/reachability queries |
| self-building catalog | `tooling/catalog.bl` | `^:catalog` metadata; doc = demo = same form |
| explorer | `docs/explorer.md` | library × examples join; coverage as gap query |
| live views | `priv/lib/live/`, `examples/live/` | view = pure fn db→hiccup; convergence through the log |
| edit-as-transaction | `priv/std/reload.bl`, `priv/std/reload/`, `examples/reload/` | bundles held/coherent; quiesce; reroute |
| ward | `priv/std/reload/ward.bl` | isolated per-file env forks; coherence gate; always-latest |
| guarantee engine | `priv/lib/system/`, `examples/system/` | inductive safety, repair, deadlock, liveness, refinement |
| the fundamental form | `docs/the-fundamental-form.md` | process = transition relation; seven forms = one shape |
| aliveness observatory | `tooling/vitals.bl` | processes as tiles; supervision tree; kill → heal |

Spell boots all of them over **one namespace set** (core + stdlib + the
current folder) and lets a human — and an agent — live inside the result.

## The realisations

### R1 — Boot is a generalization of an existing program, not a new one

`tooling/catalog.bl` already does the hard part of "load a folder": it
EVALUATES each file (defns become live) and READS each (line + source become
facts). Spell's boot is that, generalized:

```clojure
(spell/boot {:roots ["priv/boot/core.bl" "priv" "."]})
;; → namespaces loaded through reload's coherent path (not raw eval)
;; → codebase facts indexed
;; → catalog, vitals, notebook, chat served over web/serve + live.socket
;; → reload watcher armed on the roots
```

The loader already tries `.bl`, `.bl.md`, `.bl.org`
(`lib/beam_lisp/loader.ex:297` — `@doc_extensions`). The watcher does **not**
yet: `lib/beam_lisp/reload_watcher.ex:111` matches only `ends_with?(path, ".bl")`.
That one predicate is the gap between "files load" and "files stay live" —
W3 of PLAN-069, still open.

### R2 — The file-claim loop is reload's bundle, applied to prose

A save of a `.bl.md` is a **staged bundle**. The machinery decides:

- **coherent** → Spell *claims the file*: its namespace joins the running
  image, its cells become live, results are written back as owned spans
  (`bl-result` fences / `#+RESULTS:`) — the PLAN-069 W1–W4 writer.
- **incoherent** → the file is *held*: the old image keeps serving, every
  reason is printed next to the cell — nothing half-applied is ever
  observable. This is `examples/reload/02-dangling-half-bundle.bl` with a
  prose wrapper.

A comment in the file is how the human *addresses* Spell:

```markdown
<!-- @spell: turn this section into a session, invariant: no lost updates -->
```

On save, the mention is parsed as intent and becomes a session-launch fact.
The file claims the image; the comment claims a session. **No new coherence
mechanism is invented** — the reload gate *is* the claim gate.

### R3 — Sessions are processes, not transcripts

The user's constraint — *sessions encode core concurrency patterns, reading
like a systems-theory masterclass in simplicity* — is not a style request.
It is a type request. `docs/the-fundamental-form.md` already established that
a process **is** a transition relation and that `system.model` extracts the
graph from a raw `receive` loop. So a session is written as what it is:

```clojure
(defprocess handoff-session
  {:state     {:conn …        :basis …}          ; the session datom conn
   :on        {:user-msg  (fn [s m] …)
               :file-save (fn [s m] …)
               :agent-turn (fn [s m] …)
               :handoff   (fn [s m] …)}           ; emits a handoff value
   :invariant (fn [s] (every? answered? (:asks s)))}  ; no ask left unanswered
```

and the guarantee engine then *proves the session's manners*: no handoff fact
is dropped (deadlock/reachability query), every tool call yields a result fact
(inductive invariant via z3), a handoff resume refines the original session
(`simulates?`). The chat transcript is the **log** (the same object that makes
two tabs converge in `examples/live/05-two-tabs.bl`); undo is a **basis
pointer**, not a stack (`examples/live/09-undo-redo.bl`). Sessions read like
systems theory because they *are* transition relations — the same value the
engine already knows how to reason about.

### R4 — A handoff is one value: cassette + image basis + env + cursor

Three prior systems each own a third of continuity:

| system | owns | verified at |
|---|---|---|
| LLM cassettes | deterministic wire transcripts, digest-matched, offline | `ora/spell/beam/spell_agent/test/support/llm_cassette.ex` (FEAT-006) |
| machine journal | what the image became (definitions, vars), replay re-fences | `undefine/spell/apps/spell/lib/spell/persist.ex`, `loop.ex` |
| relay env | fork-local config overrides, tombstone clear, per-env isolation | `ora/relay/src/relay/env.bl` |

Spell's handoff fuses them into one inspectable value:

```clojure
{:handoff/id    "…"                      ; content-addressed
 :handoff/note  "why I'm leaving, what's next"
 :handoff/state {:basis … :journal …}    ; image basis + definition journal
 :handoff/llm   {:cassette-id "…"        ; digest-matched SSE interactions
                 :cursor 7}              ; replay resumes at the cursor
 :handoff/env   {"BL_*" "…"}             ; the fork's override map
 :handoff/branch nil}                    ; parent handoff, if branched
```

Resume = load namespaces → apply journal (re-fence, skip invalid) → restore
env overrides → continue the agent loop from the cassette cursor. Branching a
conversation = branching the value. The chip is the UI face of this value;
handing off is a **move** in the session process (R3), so "a handoff is never
lost" is provable, not hoped for.

Cassette note: the shape to reuse is FEAT-006's — ordered interactions,
`request_digest` = sha256 over the canonical request (volatile fields
stripped), raw SSE bytes so replay drives the real parser, secrets
unwritable by construction (digest only). Modes via env
(`SPELL_CASSETTE=replay|record_missing|record`, default replay; a missing
digest in replay **raises**). In pure-bl Spell the transport seam is a
fn-valued completion backend (relay's `completion/backend` pattern), not a
Req plug.

Env note: adopt `relay.env` semantics wholesale — `getenv` consults a
`^:per-env` override atom first, then the OS; `clear-env!` writes a tombstone;
each ward fork / session / tenant gets its own instance, so concurrent runs
cannot race on the process-global table. This requires the upstream per-env
def support named in relay's PLAN-060 requirement — verify it landed before
W-handoff.

### R5 — Scenarios are Spell's spec/test/demo trinity

Blueprint's scenario module (`ora/blueprint/src/blueprint/scenario.bl`)
already treats a scenario as a **timeless value**: `{:name :actors :steps
:patterns}`, steps are `act / expect / witness / beat`, claims are `fn [db
ctx]`, worlds are interchangeable interpreters (`{:open :step! :claim!
:observe :close!}`), and runs end in a four-valued verdict
(`:proven :witnessed :refuted :unknown`). Spell adopts it as the *only*
specification surface, adding one world:

- **`:spell` world** — opens the real boot (R1), steps are file saves / chip
  moves / handoffs, `:observe` reads codebase + session facts. In-process, no
  browser needed.
- the existing **model world** proves session-process properties against
  `system.model` extractions;
- the **browser world** (blueprint's legacy film driver, replaced by the
  world protocol) stays optional, for `:witnessed` visual claims.

The patterns vocabulary maps 1:1 onto the example ladders the repo already
teaches: `converges` ↔ two tabs (`live/05`), `isolated` ↔ ward /
dangling-bundle (`reload/02`), `stays` ↔ invariants (`system/*`), `lively` ↔
kill-and-heal (`tooling/vitals.bl`). A scenario run emits blueprint's
deterministic HTML certificate — the demo of the spec.

### R6 — The catalog is the navigation; coverage is the debt metric

Every view, tool, demo, and scenario Spell ships is a `^:catalog` entry, so
the chrome of the app is queried, not listed. `tooling/catalog.bl` already
guarantees the doc and the demo cannot drift (they are the same form) and
already reports coverage — the functions no example demonstrates. Spell eats
its own dog food: the first catalog Spell serves is **itself**, and the
coverage number is the honesty metric in the corner of the screen.

### R7 — Vitals is the session view

Do not build a bespoke "session monitor." `tooling/vitals.bl` already renders
processes as tiles with heartbeat, mailbox depth, supervision trees, and a
kill button — reading live VM state as data. Spell sessions appear as the
same tiles: a session is a process (R3), a handoff is a message edge between
tiles, an invariant badge is proven by the engine. One read-model, one
renderer, zero new GUI concepts.

### R8 — Chips are edges, not buttons

`ora/djinn-bl` unifies authorization and UI: `available(marking, role)` is
*both* the guard and the affordance — the cockpit and the chat render the
same move IDs (`src/backdesk/audience.bl`, `view.bl`). Spell adopts this for
the chat chip: every chip is an edge of the session's transition graph whose
guard holds *right now*. Consequence: the system engine can prove "no chip
offers a move whose guard fails" — the UI cannot lie about what is possible.
A handoff chip is the `:handoff` edge; a "claim this file" chip is the
`:claim` edge.

### R9 — Keep the djinn/relay app shape, not the umbrella shape

The proven "app on beam-lisp" skeleton is `ora/djinn-bl`: one Mix host,
beam-lisp as path dep, app code in `.bl` namespaces, `.local/blrun --path src
src/…/main.bl`, ward suites via `.local/bltest`. The existing
`undefine/spell` umbrella carries the Phoenix/Spacetime emitter experiment —
its interface↔spell compile-time bridge and generated LiveView are the
encumbrance to leave behind. Live UI comes from `priv/live` + `web/serve`
(same seam catalog and vitals already use). Durability comes from
`datom.store-fjall` (already required by `priv/std/codebase.bl:27`) — no redb, no
Phoenix.

### R10 — The MVP cut

```
spell boot
  ├─ load: core + stdlib + ./ (loader already tries .bl/.bl.md/.bl.org)
  ├─ arm:  reload watcher (⚠ needs .bl.md/.bl.org predicate fix — W3)
  ├─ index: codebase facts + catalog entries (^:catalog) + coverage
  ├─ serve: catalog · explorer · vitals · notebook (livebook W5 surface)
  │         + chat (sessions) — all over web/serve + live.socket
  ├─ sessions: defprocess sessions; transcript = datom conn (log);
  │            chips = available moves; invariants proven by system engine
  ├─ agent: fn-backend seam; cassette record/replay; relay.env overrides
  └─ scenarios: blueprint scenarios over the :spell world; certificates
```

Explicitly **not** MVP: multi-tenancy, MCP face, branding, remote deploy,
Phoenix anything, and W6 reactive re-run (impact-scoped re-run on save) —
that lands after the notebook view exists (it is W5's prerequisite).

## Prior-art ledger (what was taken from where)

| source | taken | left behind |
|---|---|---|
| beam-lisp organs | everything in the table above | the hand-run `mix beam_lisp.run` invocations |
| `ora/djinn-bl` | Score-as-value discipline; affordance=authority; closed evaluator for untrusted input; Space-per-conn isolation; mix+blrun app shape | in-memory-only store; server-rendered cockpit; scripted mind stub |
| `ora/relay` | env fork semantics (`^:per-env`, tombstones); one-seam backend swap; the transport cutover target | gateway product concerns |
| `ora/blueprint` | scenario DSL, worlds, verdict algebra, patterns, certificates | legacy film DSL as primary path; manufacturing domain |
| `ora/spell/beam/spell_agent` | cassette shape (digest-matched, raw SSE, modes, redaction-by-construction) | Req.Test plug mechanism (replaced by fn seam) |
| `products/knowledger` | library-as-datom-space, schema packs, procedures suggest/propose-save (later) | multi-tenant onboarding/branding/product scope |
| `undefine/spell` umbrella | ladder philosophy, journal-vs-transcript separation, session IDs | Phoenix/Spacetime emitter, interface↔spell compile bridge, fixture MCP corpus |

## Linchpins

1. **Watcher predicate** — `reload_watcher.ex:111` must accept `.bl.md` /
   `.bl.org` or no file ever stays live. Smallest change, largest gate.
2. **Claim = coherent bundle** — the file-claim semantics must *be* reload's
   gate (held vs applied), never a parallel "did it parse" check.
3. **Session = defprocess** — the transcript-as-log, chips-as-edges, and
   provable-handoff properties all hang on sessions being transition
   relations from day one; retrofitting later is a rewrite.
4. **Handoff value stability** — the handoff map is a public artifact; its
   shape needs a version field and a content hash before anything consumes it.
5. **Per-env defs upstream** — relay-style env forks require beam-lisp
   env-scoped def instances (relay PLAN-060 req A). Verify landed; else
   handoff env restore degrades to OS-env writes (rejected: global race).

## Landmines

- Umbrella AOT compile hangs (librarium regression note) — the djinn-bl
  non-AOT blrun path avoids it; do not re-introduce an umbrella.
- Blueprint scenario composition is strictly ordered in v1 (parallel
  deferred) — spec within that; do not promise interleaved actors yet.
- Cassettes must never bill: replay marks runs as such and isolates provider
  credentials (env tombstones make this structural).
- The notebook "two tabs" claim needs the W5 session-conn-per-viewer work —
  Spell's chat view rides the same work item; build once.

## Open decisions (for the human)

1. **Where the app lives.** Recommendation: fresh repo
   (`undefine/spell-app` or rename), beam-lisp as path dep, `undefine/spell`
   umbrella archived as the experiment it was. The name `spell` is worth
   keeping; the directory history is not.
2. **stdlib scope at boot.** Recommendation: explicit manifest in the app
   (`spell/boot` takes roots), defaulting to `priv/boot/core.bl` + the stdlib set
   the catalog indexes + `.`. "Load all of priv" is convenient but drags z3
   and friends into every boot; make the default tasteful, not maximal.
3. **MCP face timing.** The agent-native story wants MCP early, but the MVP
   scenario set is human-in-the-loop. Recommendation: W-after-handoff.
