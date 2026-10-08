# The runner kit — a generic test-runner + video explorer

*A domain-neutral component kit for **watching runs unfold**: browse a suite,
scrub one run's timeline, play the recording, jump to the failure, share the
exact frame. Built on `loom` + `live`, catalogued like `printflow.kit`, designed
to be **dropped into any project** — it knows a normalized `Run`, nothing about
print, scenarios, or your domain.*

Namespace: `scenario.runner` (domain-neutral; components promote to `loom`
later — a loom-promotion FUP). Read `10-time-travel-ui.md` for the time-travel spine and
`blueprint.chronicle` (Blueprint) for the read-head process this rides.

---

## 0. What "generic" and "explore videos" mean here

Two requirements drive every decision:

1. **Reusable across projects.** The kit renders a **normalized `Run` value**
   (§2). Any project writes one adapter (`your-result → Run`) and gets the whole
   runner. The kit never reaches into your domain; your domain projects itself
   into the `Run` shape. `scenario` ships one such adapter; a Jest/
   Playwright/pytest suite would ship another.
2. **Video is first-class, and synchronized to time.** The differentiator is not
   "a video player." It is **one coordinate — the timeline head — that drives
   the video, the state, and the proof at once, both ways**: scrub the timeline →
   the video seeks; scrub the video → the timeline moves; the failing claim, the
   state projection, and the frame are always the same instant. Explore by
   *time*, and everything follows.

Everything below serves those two.

---

## 1. DX principles (the reason the kit exists, not just its parts)

A generic runner lives or dies on how it *feels* to chase a failure. Seven rules,
each cashed out as a component behaviour:

| # | principle | how the kit honours it |
|---|---|---|
| D1 | **Land on the problem, not step 1.** | a refuted run opens at its **first refutation** (`transport`'s default `:at`), video paused on the witness frame |
| D2 | **One coordinate, everything synced.** | `timeline-scrubber` head ⇄ `video-stage` currentTime ⇄ `claim-list` highlight — via the run's `:media :marks` step↔time map |
| D3 | **Keyboard-first.** | `←/→` step · `space` play/pause · `f` jump-to-fail · `[ ]` frame-step · `,/.` prev/next run — surfaced by `keyboard-hints` |
| D4 | **Every state is deep-linkable.** | `permalink` encodes `run + coordinate` in the URL; open it → land on the exact frame. "The bug is *here*," pasteable |
| D5 | **Degrade honestly.** | no recording → `video-stage` falls back to the state projection; no steps → `empty-state`; mid-run → `running` shimmer. Never a blank box |
| D6 | **Explorable at every grain.** | suite → run → step → frame → raw evidence, each a component, each a stable URL |
| D7 | **Truth is legible.** | verdict is **colour + mark + word** (a11y floor, inherited from loom); green/red is never colour alone |

---

## 2. The reusability contract — the `Run` value

The one thing a host project must produce. Domain-neutral; every field except
`:id/:title/:verdict/:steps` is optional (the kit degrades, D5).

```clojure
{:id       "rush-refuted"                 ; stable, URL-safe
 :title    "Rush incident — the promise"
 :verdict  :refuted    ; :proven :witnessed :refuted :unknown :running :skipped
 :duration-ms 4200
 :tags     [:incident :promise]
 :world    :model      ; provenance badge: :model | :local | :kernel (which plane)

 ;; ── the recording (optional) — the video-exploration seam ──────────
 :media    {:kind  :video                 ; or :frames (thumbnails only)
            :src   "runs/rush.mp4"
            :poster "runs/rush.png"
            :marks [{:step 1 :t 0.0}       ; STEP ↔ VIDEO-TIME map — the sync key
                    {:step 2 :t 1.7}
                    {:step 3 :t 2.1}]}

 ;; ── the timeline — one frame per step ──────────────────────────────
 :steps    [{:i 1 :label "amina sees the promise" :actor :amina
             :verdict :proven :t 0.0
             :basis <db>                   ; the chronicle coordinate (for bisect)
             :views {:amina {…}}           ; per-actor projection at this basis
             :trace {:kind :sees :outcome :ok}}
            …]

 ;; ── the claims (the proof) ─────────────────────────────────────────
 :claims   [{:msg "the promise is Thursday" :verdict :refuted :step 3
             :evidence {:view {:status :blocked :promised "Fri 14:00"}
                        :frame "runs/rush.mp4#t=2.1"}}]   ; witness ± media

 :stretches [{:kind :stays :verdict :proven :msg "le temps perdu reste perdu"}]}
```

`scenario.runner.adapt/of-scenario` maps a `scenario` result → this
(the `:bases`→`:steps :basis`, verdicts→`:claims`, `bisect`→`:views` are already
there). A `Suite` is just `{:title :runs [Run]}`. **That is the whole API surface
a host must meet.**

---

## 3. The components — five bands

24 components. Each is a pure `(Run|Suite|…) → hiccup` fn on `loom.box`/`ui`/
`token`, ships as a `^:catalog` demo over a fixture run, and is **video-aware
where marked ▶**. Bands map to the exploration flow: *find → control → SHOW →
PROVE → frame*.

### Band A — Suite (the front door: find the run)

| component | purpose | loom basis | DX |
|---|---|---|---|
| `suite-header` | totals bar: N passed · M failed · K flaky · duration | `b/row` `k/stat-row` | D7 at-a-glance health |
| `filter-bar` | filter by verdict/tag/world · search by name | `k/toolbar` `k/search` | D6 narrow fast |
| `run-grid` | responsive grid of every run | `b/grid` | D6 |
| `run-tile` ▶ | one run: title · verdict badge · duration · world chip · **poster thumbnail** | `k/stateful` card | D1 reds jump out; poster previews the film |
| `verdict-badge` | the verdict as colour+mark+word | `k/status-pill` | D7 a11y floor |

### Band B — Transport (control time)

| component | purpose | loom basis | DX |
|---|---|---|---|
| `verdict-ribbon` | run headline: verdict + counts + danger border | `b/row` | D1 |
| `transport-bar` ▶ | ⏮ ◀ ▶/⏸ ▶▶ · speed · **jump-to-refutation** | `ui/button`×N | D1,D3 |
| `timeline-scrubber` ▶ | the step axis; ticks coloured by verdict; current lit; click/drag to seek | `b/row` ticks | D2 the spine |
| `scrub-rail` ▶ | the video seek-bar **fused with** the step ticks (frames aligned to steps) — one rail for both | `b/box` + range | D2 the sync made visible |
| `playhead` / `basis-chip` | where am I: `t=… · step k · actor·action` | `k/mono` `k/eyebrow` | D2 |
| `keyboard-hints` | the shortcut legend (dismissible) | `ui/prose` `k/badge` | D3 discoverability |

### Band C — Show (the video explorer — the heart)

| component | purpose | loom basis | DX |
|---|---|---|---|
| `video-stage` ▶ | the `<video>`, **two-way synced** to the head via `:media :marks`; seek→currentTime, timeupdate→step; falls back to state projection when no media | `[:video]` + media hook | D2,D5 |
| `filmstrip` ▶ | one thumbnail per step; the failing one ringed red; click to jump | `b/wrap` frames | D2,D6 the whole run at a glance |
| `witness-frame` ▶ | the refuted moment's frame, frozen, framed red, with the failing claim over it | `witness-card` + media | D1 the failure, shown |
| `stage-grid` ▶ | N synced videos/views side by side (multi-actor, multi-camera, before/after) | `b/grid` of `video-stage` | payoffs #3,#4 |
| `state-panel` | the projected world at the head (the no-video truth, always available) | `b/col` `k/mono` | D5 |

### Band D — Prove (the evidence side)

| component | purpose | loom basis | DX |
|---|---|---|---|
| `claim-list` | the assertions, each a `claim-row`; refuted first | `b/col` | D1 |
| `claim-row` ▶ | one verdict: mark · msg · step link (**click → seek video+timeline there**) | `k/queue-row` | D2,D6 |
| `witness-card` ▶ | a refuted claim's falsifying world; **media slot** for the frame | `k/section` | payoff #1 |
| `step-card` | this frame's trace entry: kind·actor·action·outcome | `k/section` | D6 "what happened here" |
| `belief-diff` | an actor's remembered expectation vs the world now | two `state-panel`s | payoff #4 |
| `stretch-badge` | a run-level property verdict (`stays`/`lively`) | `k/badge` | payoff #1 |
| `evidence-drawer` | expandable raw evidence: basis, datoms, logs, network | `ui/card` `<details>` | D6 escape hatch to ground truth |

### Band E — Frame (the DX shell)

| component | purpose | loom basis | DX |
|---|---|---|---|
| `runner-shell` | the layout: suite rail · main (transport+show) · inspector (prove) | `k/shell` `b/grid` | D6 |
| `split-pane` | resizable video ∣ proof | `b/row` + drag | D6 |
| `permalink` ▶ | copy a deep link to `run + coordinate` | `ui/button` + `[:navigate]` | D4 shareable failures |
| `states` | `empty-state` · `loading-state` (running shimmer) · `error-state` | `k/stateful` | D5 |

---

## 4. The sync mechanism — how video exploration actually works

Everything in §3 marked ▶ is one idea: **the head and the video currentTime are
the same coordinate, projected two ways**, joined by the run's `:media :marks`
(step ↔ seconds). Two pure conversions, computed from `:marks`:

```
step→t :  seek the timeline to step k  →  video.currentTime = (t-of k)
t→step :  video timeupdate at t seconds →  head = (step-at t)
```

- **Timeline drives video** (D2): a `timeline-scrubber` / `scrub-rail` seek is a
  `[:assign [:head] k]` (a pure local, per `chronicle`). The re-render emits
  `data-media-seek="<t-of-k>"`; a tiny client hook sets `video.currentTime`.
- **Video drives timeline** (D2): the `<video>` `timeupdate` maps `t → step` and
  posts `[:media/seek t]` — the *one* closed event term the kit adds (§6). The
  handler sets the head; the whole page re-projects at the new instant.
- **No media?** (D5) `step→t` is undefined → `video-stage` renders `state-panel`
  instead; the timeline still drives state and proof. Zero video is a supported
  first-class mode, not a broken one.

∴ "explore videos" = scrub anything, everything follows. The kit is a
**time browser** that happens to render a frame.

---

## 5. Prototype × component — the kit explores all of them

| prototype (purpose) | the components that carry it |
|---|---|
| **1. Certificate / forensic bisect** — a refutation with its witness | `verdict-ribbon` · `timeline-scrubber` · `transport-bar` (jump-to-fail) · `claim-row` · `witness-card` · `witness-frame` |
| **2. Proof-guided filming** — film the branches that matter | `filmstrip` (ticks *are* the proof's interesting steps) · a `branch-strip` above the scrubber (enumerated paths) |
| **3. Browser worlds / NIF** — the recording source | `video-stage` · `scrub-rail` · `stage-grid` (multi-camera) — they render whatever `:media` the NIF fills |
| **4. Actors with memory** — expectation vs reality | `belief-diff` · `stage-grid` (per-actor views synced) |
| **5. Telemetry → datoms** — live events as facts | `evidence-drawer` (the datoms) · `step-card` (the event) · `state-panel` (the derived world) |
| **6. Demo-is-the-run** — the shipped demo *is* the test | the whole `runner-shell`: scrub = inspect a proof; press play = watch a demo. Same screen, same data |

No prototype needs a component the others don't — they are **renders of one run
at one coordinate**. That is why one generic kit covers all six, and why a new
project that produces a `Run` gets every payoff for free.

---

## 6. The one honest extension — a `media` event vocabulary

The kit is pure `loom`/`live` **except** video sync: `client.js` today delegates
`click`/`input`/`Enter` only, so `<video>` `timeupdate`/`seeking` and setting
`currentTime` have no closed-term path. This is the *same* grain question as the
autoplay `[:tick]` note in `10-time-travel-ui.md §7`, made concrete and now
**necessary** for the headline feature. Propose to `20-loom-live-extensions.md`
one small, data-shaped media vocabulary (a coordinate, not arbitrary JS):

```
inbound  (DOM → head):   [:media/seek t]        ; the video moved to t seconds
outbound (head → DOM):   data-media-seek="t"    ; a hook sets video.currentTime
optional (autoplay):     [:tick {:ms 700}]      ; model-drives the head on a clock
```

Testable as `system` traces, replayable, pure. Filed **FUP-007** (media/tick
client affordance). Until it lands, the kit is fully usable **step-by-step and
keyboard-driven** (D3) — video sync is the increment the term unlocks, not a
prerequisite for the rest.

---

## 7. Build order

1. **`scenario.runner.adapt`** — `of-scenario : result → Run`; `Suite`. Pure;
   `=`-test against the certificate fixture (the shape is already there).
2. **Band A + B + D** (no-media) — suite index + transport + proof, over a
   fixture `Run`. Pure hiccup, `=`-tested. This is a working runner **today**,
   no client changes: scrub steps, see state + claims move.
3. **`catalog/runner-gallery.bl`** — every component `^:catalog`; coverage green.
   Browse it via the catalog server (§ `10-time-travel-ui.md`/kit-gallery route).
4. **`run/serve-runner.bl`** — the app value + `app/serve`; headless smoke
   mirroring `printflow.live` (renders `/runs` and `/run/:id`; a `:seek` moves
   the rendered basis).
5. **FUP-007** (`media` term) → light up Band C two-way video sync.
6. Then W1 NIF fills `:media` for real runs; **no component changes** — the
   `Run` contract already has the slot.

Verification per piece: pure components → hiccup `=`-assertions over a fixture
`Run`; the app → headless render + "seek moves the basis"; the gallery → catalog
coverage. A `system` trace over `chronicle`'s head-bound already proves the
scrubber can never seek off the log (done, `chronicle-test`).
