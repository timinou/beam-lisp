# The scenario kernel — native browser substrate + the primitive/pattern scenario

*Status: design v1 (2026-09-01). Companion code: `priv/lib/scenario.bl`
(v2 namespace, model world runnable), `test/bl/scenario/patterns_test.bl`
(five film properties proven in-model). Plan: `PLAN-003`.*

## 0. The mandate

`scenario` already proves the product thesis in-model (the operator
logs an incident; the commercial's promised date moves; nobody coordinated —
the datom log is the coordinator). `printflow.film` films the same story on
the real app. But the film leg leans on glue that is not ours:

| today | what it is | why it hurts |
|---|---|---|
| `test/film/film-driver.mjs` | 262 lines of node + Playwright | a second runtime, a second language, a JSON boundary where the scenario stops being a value |
| `test/film/record.sh` | pkill / nohup / curl-poll / port juggling / ffmpeg hstack | shell orchestration of state; unreplayable, undiffable, fragile |
| Playwright + ms-playwright cache | a browser we do not manage | chrome discovery, hydration hacks, version drift |
| ffmpeg | the convergence composite | a binary dependency for what is really a *view* over two timelines |

And the two legs — the *proof* (model trace) and the *film* (browser) — never
meet: the film does not inherit the proof, the proof does not benefit from the
film's evidence.

The move, in three cuts:

1. **Own the browser substrate as a native NIF** — kernel.sh's surface
   (sessions, CDP, pools, profiles, replays, live view, telemetry) behind a
   Rust crate in beam-lisp's existing `defnative` tier, with a self-host
   path on `onkernel/kernel-images`. One crate, one namespace; no node, no
   shell, no Elixir browser packages.
2. **Cut the scenario language to primitives + patterns** — a four-event
   algebra and a world protocol so the *same scenario value* runs as a
   proof (model world), a test (`:local`), a film, and a live demo (`:kernel`).
3. **Collect the payoffs that only this combination unlocks** — trace↔replay
   frame sync, proof-guided filming, actors with memory, telemetry→datoms,
   refuted-with-witness CI.

---

## 1. The substrate: what kernel.sh gives us

kernel.sh (api base `https://api.onkernel.com`, OpenAPI 3.1 published) is
browser *infrastructure*: not another driver — a place where browsers live.
Audit of its surface against what a scenario runner needs:

| kernel.sh capability | primitive shape | what the scenario runner does with it |
|---|---|---|
| **Browser sessions** — create/delete, CDP + Playwright + WebDriver-BiDi endpoints, headless/headful, GPU, viewport+refresh | `session-create`, `session-delete`, `sessions` | one session per ACTOR (amina's tab, karim's kiosk); the convergence setup is N sessions, one plant log |
| **Browser pools** — pre-warmed, long-poll `acquire`, `release` | `pool-acquire`, `pool-release` | per-take isolation with no boot cost; the suite runs in seconds, not minutes |
| **Profiles** — persist cookies/localStorage as zstd-tar state, `save_changes` | `profile-create`, sessions with `profile` | actors WITH MEMORY: amina's logged-in commercial browser exists across runs; day-1 seed scenario, day-3 inspection |
| **Managed auth** — hosted UI / programmatic login flows, credentials vault, SSE flow events | `auth-connection-*` | real logins with zero credentials in the repo; MFA handled out-of-band |
| **Replays** — start/stop/download, H.264 mp4 of the whole VM screen | `replay-start`, `replay-stop`, `replay-download` | the film IS a replay; per-actor videos + composite; replay-on-fail in CI is one call |
| **Live view** — WebRTC (neko) read/write streaming URL | `live-view` | the demo IS the run: embed the actor tabs in a loom panel; take over live |
| **Telemetry** — per-session event stream (SSE), OTLP export | `telemetry-open`, `stream-next` | browser-plane events land in the SAME datom log as plant facts (§5.5) |
| **Computer controls** — mouse/keyboard/screenshot/clipboard batched | `computer-*` | OS-level fidelity input for kiosk-style flows; agent-driving later |
| **Playwright execution** — JS runs in-VM beside the browser | `playwright-exec` | escape hatch / fidelity lever, not the substrate |
| **Processes / file I/O / curl-through-browser** | `exec`, `fs-*`, `fetch-via` | in-VM helpers; API-leg tests through the browser's TLS fingerprint + cookies |
| **Stealth / proxies / Web Bot Auth** | session opts | automating third-party sites honestly when the product needs it |
| **Projects / spending caps** | headers | per-workstream isolation and budget guardrails for CI |

**Self-host path — "our own thing":** `onkernel/kernel-images` (Apache-2.0)
is the same substrate in an image: headful Chromium in Docker or as a
Unikraft unikernel, CDP exposed on `:9222`, WebRTC live view (neko), a
recording server (`:10001/recording/{start,stop,download}` → mp4), and — on
unikernels — automatic standby with snapshot/restore (<20 ms cold restart).
The NIF speaks plain HTTP + CDP + SSE, so the *same* crate drives a
kernel.sh cloud session or our own kernel-images instance. The backend is a
base-URL, not an API change. This is the famiprint lesson inverted: we are
not depending on a vendor's runtime, we are binding a *protocol* we control
end to end.

---

## 2. The native tier: `native/scenario_kernel`

Follows the established tier exactly (`datom_fjall` is the template): a
Rust crate under `native/`, built by the `:beam_lisp_native` Mix compiler,
declared by ONE host namespace via `defnative`; kebab-case in beam-lisp,
snake_case in Rust; dirty-IO schedulers because every call is I/O.

```
(defnative "scenario_kernel"
  ;; lifecycle (kernel.sh REST; also kernel-images base-URL)
  (session-create 1)     ; opts map → {:session-id :cdp-ws :live-view :replayable …}
  (session-delete 1)
  (pool-acquire 1)       ; long-poll → session map
  (pool-release 2)
  ;; control (CDP over websocket)
  (cdp-open 2)           ; session, url → page
  (cdp-call 3)           ; page, method, params → result   (any CDP domain)
  (cdp-eval 2)           ; page, js → value
  (cdp-close 1)
  ;; observe
  (replay-start 1)  (replay-stop 1)  (replay-download 2)
  (live-view 1)          ; → webrtc URL (the demo panel)
  (telemetry-open 1)     ; SSE → stream handle
  (stream-next 2)        ; handle, timeout → [events]    (poll model: BEAM-friendly)
  ;; state + environment
  (screenshot 2)  (exec 2)  (fetch-via 2)
  ;; local backend — same CDP surface, our chromium
  (local-launch 1))      ; opts → {:cdp-ws …} (then cdp-open/cdp-call as above)
```

Design rules:

- **The NIF never sees actors, steps, or scenarios.** It knows sessions,
  pages, methods, streams. The scenario language lives in `.bl`; the NIF is
  substrate. (Same cut as `datom_datalog`: the kernel doesn't know about
  routings.)
- **One crate, one namespace** (`scenario.kernel`), per
  `BeamLisp.Native`'s rustler module-name contract. Callers that need it
  from printflow `require` it.
- **Poll, don't callback.** SSE streams are buffered in a Rust thread and
  drained with `stream-next`; the BEAM side models the stream as a lazy
  value and can fold it into the datom log transactionally. No async
  runtime leaks across the boundary.
- **`local-launch` first.** W1 proves the CDP half against a locally spawned
  chromium — no cloud account, no network — so the world protocol (§3) can
  land before the kernel.sh half. The cloud is a base-URL swap, not new code.

### What dies when this lands

`film-driver.mjs` (the interpreter becomes ~80 lines of `.bl` over
`cdp-call`/`cdp-eval` — and it is *the same interpreter* that runs the model
world, modulo the world adapter), `record.sh` (the runner boots the app
in-process; sessions come from a pool; no ports to juggle), the ffmpeg
composite (§5.6), chrome discovery and hydration hacks (kernel sessions are
warm and standby-capable).

---

## 3. The language: primitives, patterns, worlds, verdicts

### 3.1 The four-space discipline, applied to scenarios

| space | scenario concept |
|---|---|
| SPECIFICATION | the scenario **value**: actors + events (what happens; timeless) |
| CAPABILITY | the **world**: a runner that can *be* the timeline (model / local / kernel) |
| PROCESS | the **run**: trace + bases + verdicts (how it unfolded) |
| PLAN/FLOW | the **film/demo**: a dated presentation of a run (captions, cuts, live view) |

A scenario never mentions a browser; a world never mentions a print term; a
film never changes the outcome it presents.

### 3.2 Primitives — four events and one composition

A scenario is a VALUE: `{:name :actors :steps :patterns}` where steps is a
linear vector of events.

```clojure
(beat ms)                    ; time passes (a determinate no-op act)
(act actor term)             ; actor does term to the world (domain-interpreted)
(expect actor claim msg)     ; the actor's view of the world satisfies claim — NOW
(witness actor lens name)    ; capture the actor's observation, bind it for later claims
```

- a **claim** is `(fn [db ctx] bool)` in the model world — `db` is the world
  basis, `ctx` carries `{:witnesses {name value}}`. In browser worlds a
  claim is the same position in the value, interpreted by the world
  (`{:op :text …}` / `{:op :no-text …}` …). The *scenario author writes one
  thing*; the world decides what it means to check it.
- a **lens** is the observation primitive: `(fn [db] value)` (model) or data
  (browser). Witnesses make claims comparative (`shifts`, `isolated`) without
  a global notion of time.
- **composition v1 is sequence** — the five films are total orders, and a
  faithful replay of a proven interleaving is the honest default.
  `par`/interleave is v_next (§5.2), not a v1 primitive. Scope discipline.

### 3.3 Patterns — named properties that expand to primitives

Every pattern expands into events (or a run-level check) *and carries its
because* — the narration is part of the property, so `say`-as-step
disappears from the language and returns as a presentation concern (§4).

```clojure
;; event-level (macroexpand into the steps vector)
(converges writer term observer claim because)
  → [(act writer term) (expect observer claim because)]

(isolated writer term bystander lens because)
  → [(witness bystander lens :before) (act writer term)
     (expect bystander #(= (:before %) (lens db)) because)]

(shifts writer term observer lens delta because)
  → [(witness observer lens :before) (act writer term)
     (expect observer #(= delta (measure (lens db) (:before %))) because)]

;; run-level (declared in :patterns, checked at close over the whole stretch)
(stays lens after-tag msg)   ; after the event tagged after-tag, the lens value
                             ; is identical at EVERY subsequent basis — the
                             ; honest-resolution property: unblocked, but the
                             ; lost time stays lost
(lively actors)              ; no actor's liveness signal dropped anywhere in
                             ; the stretch (assert-live, generalized)
```

The five existing films *are* these patterns over one skeleton:

| film | pattern instance |
|---|---|
| rush-incident | `(converges op12 log-incident amina sees-18h45 "sans un mot")` |
| cascade-visible | `(shifts op12 log-incident rachid promise +3h "recalculée, pas devinée")` |
| isolation | `(isolated karim log-incident sofia flyer-promise "l'incident est ailleurs")` |
| resolve-honest | `(stays promise :resolved "le temps perdu ne revient pas")` |
| full-chain | three `(converges …)` from one act |

Same skeleton, four properties, five films. The compression is the point:
properties you can NAME are properties you can REUSE on the next scenario.

### 3.4 Worlds — one interpreter seam

```clojure
{:open    (fn [scen] handle)                     ; boot the world for this take
 :step!   (fn [handle ev] outcome)               ; act / beat
 :claim!  (fn [handle actor claim ctx] bool)     ; expect
 :observe (fn [handle actor lens] value)         ; witness + stays snapshots
 :liveness (fn [handle] drops)                   ; lively
 :close!  (fn [handle] …)}
```

| world | open | what an expect MEANS |
|---|---|---|
| `:model` | a fresh datom conn (or the test conn) | claim evaluated over the shared basis — **:proven** / :refuted (decidable, ms, no browser) |
| `:local` | in-process app boot + `local-launch` chromium, one page per actor | claim evaluated on that actor's page over CDP — **:witnessed** |
| `:kernel` | `session-create` per actor (profiles!), pool-warmed | witnessed **on the real infrastructure** — with replays, live view, telemetry |

### 3.5 Verdicts — the film is a proof certificate

Every expect resolves to a verdict, carried on the trace and burned into the
film captions:

```
:proven    the model world decided it (datalog/SMT-grade)
:witnessed observed on a live world (video evidence exists)
:refuted   + the witness: the failing basis (model) or the replay frame (browser)
:unknown   the world cannot decide it (first-class; e.g. :lively on :model)
```

`:model → :kernel` is the honesty chain: the model PROVES the property, the
browser BEARS WITNESS, the film SHOWS the witness.

---

## 4. Films and demos — projections, not languages

`printflow.film` v2 compiles FROM pattern scenarios; presentation is a lens
over the run, never a second vocabulary:

- **captions** — each pattern's `because` is the narration; the runner knows
  which event each caption belongs to, so the burned-in caption bar is
  generated, not authored.
- **cuts** — the composite (cause LEFT, effect RIGHT — the convergence frame)
  becomes a loom view that syncs the per-actor replays by *trace time*
  (every verdict pins a replay frame; §5.1). Deterministic, in-repo,
  diffable — and only if someone wants a single mp4 does a render pass run.
- **live demo** — `:kernel` open + `live-view` per actor embedded in a loom
  panel: the salesperson presses play (the runner executes the scenario) or
  takes over (WebRTC is read/write). Test ≡ film ≡ demo: one value, three
  consumptions, zero divergence.

---

## 5. The payoff portfolio (what this unlocks that neither leg had)

### 5.1 Forensic bisect — the film is an INDEX over the proof
Telemetry/CDP timestamps let every run step pin a replay frame. A refuted
expect returns `{:basis … :frame t :replay …}` — click the red verdict, see
the datom basis AND the exact second of video. Debugging a demo becomes
bisection over a certificate. (CI corollary: replay-on-fail is one
`replay-stop` — every red build ships its own evidence.)

### 5.2 Proof-guided filming — enumerate, prove, then film the witness
In-model, interleavings are enumerable (minikanren.bl) and each admissible
ordering is checkable in milliseconds. Film ONLY orderings the model already
proves (or deliberately films the adversarial one to show the refutation).
Filming is expensive; proving is cheap; the model budgets the film.

### 5.3 Actors with memory — scenarios that span days
Profiles make an actor a persistent PERSONA: amina's browser keeps her login
(managed auth keeps it fresh — no credentials in the repo). Sagas: a day-1
seed scenario, a day-3 inspection scenario — the plant has history, and the
tests can be about *history*. Unikernel standby means a "resident" plant
session sleeps at negligible cost and restores <20 ms mid-scenario.

### 5.4 Pools = the suite at film speed
Warm `pool-acquire` per take: fresh isolation with no boot, no pkill dance,
no port juggling. The full five-film suite on real browsers in seconds;
CI runs films on every PR with spending caps as the guardrail.

### 5.5 Telemetry → datoms — one log for both planes
`telemetry-open` + `stream-next` fold browser-plane events (navigations,
console, socket drops) into the SAME datom store as plant facts. Convergence
checks become datalog queries over a unified log; `lively` becomes a query,
not a watchdog; incident forensics join business facts to browser facts in
one bitemporal history.

### 5.6 The composite without ffmpeg
The convergence frame is a *view*: a loom hiccup page placing N replays
side-by-side, synchronized by trace time, captions and verdicts rendered as
DOM. Deterministic, diffable, reviewable in-repo. An mp4 render is an
optional export, not the artifact of record.

### 5.7 Honesty economics
Budgets, projects, and audit logs make the runner's cost visible and
capped; the demo-creator pipeline regenerates the product's own marketing
video from the certificate on every release — the product demos itself with
proofs burned into the captions.

---

## 6. Waves

- **W1** `native/scenario_kernel` + `scenario.kernel`: REST
  lifecycle, CDP open/call/eval, `local-launch`, replay trio, live-view,
  telemetry stream (poll). Gate: a `.bl` smoke test opens a local chromium,
  navigates, evals, screenshots — no node.
- **W2** browser worlds behind the protocol (§3.4); step interpreter in
  `.bl`; film-driver.mjs + record.sh deleted; the five films play from the
  pattern scenarios.
- **W3** film projections: captions from `because`, verdict-burned captions,
  convergence frame as loom view; replay frame pinning.
- **W4** payoffs: proof-guided filming, telemetry→datoms, profiles/auth
  personas, replay-on-fail CI, live demo panel.

## FUPs

- FUP: `par` composition + admissible-interleave enumeration semantics
  (minikanren) — v1 sequence only.
- FUP: self-hosted kernel-images on our metal (unikernel standby/snapshot)
  as the second backend; kernel.sh cloud as the first.
- FUP: WebDriver-BiDi as an alternative CDP transport if a world needs it.
