# Time-travel UI — the scrubber, the stage, the witness

*The test runner and the demo viewer are one screen. This is its component
vocabulary, built on `loom` + `live`, catalogued like `printflow.kit`.*

Read `research/40-scenario/00-scenario-kernel.md` first (the primitives, the
verdict algebra, the payoff portfolio) and `priv/lib/scenario.bl` (the run
result shape). This doc is the **UI projection** of that machinery.

---

## 0. The one realization everything follows from

A scenario run is already a time-travel data structure. `run-world` keeps a
**basis per step** — `(:bases result)` is a vector of datom db-values, one for
each frame of the story — and `(scenario/bisect result n)` renders any of them.
A datom db-value is a *coordinate*, not a copy (verified: ETS store ref +
`:basis-t`; an old basis still answers as-of reads because history is intact).

That movable-read-head-over-a-log shape is named once, as a BEAM process, in
**`blueprint.chronicle`** (a Blueprint module; the read-head the runner mirrors):

- **value algebra** — a chronicle is `{:conn :marks :head}`; `undo`/`redo`/
  `seek`/`frames` are pure, `=`-testable, and a write past a rewound head
  *branches* (truncates the redo future).
- **the process** — `chronicle-server`, a `defserver` whose state IS the head:
  `cast :undo`, `call [:peek lens]`. It subscribes to a shared conn so an
  external commit auto-checkpoints (the live-defserver shape).
- **the proven core** — `head-machine` carries `^{:invariant (and (>= head 0)
  (< head length))}`, discharged by the SMT checker: the pointer can never fall
  off the log, so no scrubber tick / over-redo / seek-past-end ever crashes.
- **compose** — hand `spawn-process` one pure transition `(op payload db) →
  tx-or-nil` and get a rewindable process for free.

So the live UI needs **no new time machine**. It is exactly the shape the
beam-lisp `09-undo-redo.bl` example already proves, now reified as a process:

```
undo/redo is a basis POINTER over a log. The view is (shared, session, locals)
→ hiccup. `as-of db basis` is the db at a past basis. Rendering the past is the
SAME view function at a different coordinate. Ctrl-Z = (assign :at prev-basis).
```

Generalize that one draft to **N actors + a verdict track** and you have the
whole interface:

| undo-redo (1 draft) | scenario time-travel (N actors) |
|---|---|
| `:at` local = a basis | `:at` local = a **step index** into `(:bases result)` |
| render `editor` at `(as-of db :at)` | render **every actor's stage** via `(bisect result :at)` |
| — | a **verdict track** colours each step green/red |
| Ctrl-Z = prev basis | scrubber tick / ←→ = any step |
| — | a **refuted** step freezes on its **witness** |

The scrubber is the spine. Everything else hangs off `:at`.

---

## 1. Grain we honour (verified in `priv/live/`, `priv/loom/`)

- A view is a pure `(shared-db, session-db, locals) → hiccup`. No templates, no
  JS. `scenario.live` components are pure functions of the run result
  + `:at`.
- Events are **closed data terms** the socket forwards: `[:intent op payload]`,
  `[:assign path source]`, `[:navigate target]`. Every affordance below is one
  of these — never an escape hatch to arbitrary JS.
- State has three homes: **shared** datom conn (the plant, durable), **session**
  conn (per-socket drafts — unused here), **local** map (`:at`, `:playing`,
  `:route`). Scrubbing writes only a local → the pure view re-renders at the new
  coordinate. **No server write to move through time.**
- Components funnel through `loom.box`, inherit its escape hatches for free
  (`:style` wins, `data-*`/`aria-*` forwarded), and paint from `loom.token`
  scale — accessible by default. We compose `loom.ui` + `printflow.kit`, never
  raw HTML.

**The rule:** a new interaction is a new closed event term. Only **one** new
term is needed (`[:tick]`, §7) and it is optional — the whole interface works
step-by-step without it.

---

## 2. The component vocabulary — `scenario.live`

Twelve components, three bands. Each is a pure `→ hiccup` fn built on
`loom.box`/`loom.ui`/`printflow.kit`, and each ships as a `^:catalog` demo in
`catalog/scenario-gallery.bl` (§6) — the vocabulary is a browsable,
coverage-measured gallery, same discipline as `kit-gallery.bl`.

Placement: these live in **`scenario.*`** (domain-neutral — they know
*scenario runs* and *verdicts*, not ink) not in any host domain namespace. The three purest
(`timeline-scrubber`, `basis-chip`, `transport-bar`) are candidates to promote
into `loom` proper later — filed as a loom-promotion FUP so we don't force the
`20-loom-live-extensions.md` sign-off gate to land this design.

### Band A — chrono (the time axis)

| component | role | built on | event | stage |
|---|---|---|---|---|
| `timeline-scrubber` | the step axis; N ticks, each coloured by that step's verdict; current step lit; click a tick to jump | `b/row` + `t/sx` ticks | `[:assign [:at] n]` | **W1** |
| `transport-bar` | ⏮ ◀ ▶ ⏭ + "jump to refutation" | `ui/button` ×5 | `[:assign [:at] n]`, `[:intent :bisect {:to :first-refuted}]` | **W1** |
| `basis-chip` | mono "where am I in time" readout: `t=…` + step's actor·action | `k/mono` `k/eyebrow` | — | **W1** |
| `verdict-ribbon` | run headline: `:proven`/`:refuted` badge + witnessed/refuted/unknown counts; danger border-left | `b/row` `k/status-pill` | — | **W1** |

### Band B — stage (the N-actor as-of world)

| component | role | built on | event | stage |
|---|---|---|---|---|
| `actor-stage` | one actor's projected world **at the scrubbed basis** — the projector's view (status pill, promised-date mono, …) | `b/col` `k/status-pill` `k/mono` | — | **W1** |
| `stage-grid` | all actor-stages side by side (the printflow.live "two facing tabs", now N and time-scrubbed) | `b/grid` | — | **W1** |
| `witness-card` | a refuted claim's falsifying world, framed red: "claim said X · basis says Y"; **media slot** for the replay frame | `k/section` + `k/mono` | — | W1 view · **W3 frame** |
| `belief-diff` | actor's *remembered expectation* vs the world now (payoff #3 — actors with memory) | `b/row` two `actor-stage`s | — | **W2** |

### Band C — proof + index

| component | role | built on | event | stage |
|---|---|---|---|---|
| `claim-row` | one verdict: mark + actor + `:because` + step link; refuted → red, expands to witness | `k/queue-row` pattern | `[:assign [:at] step]` | **W1** |
| `step-card` | the trace entry at the current basis: kind·actor·action·outcome ("this frame") | `k/section` | — | **W1** |
| `stretch-badge` | a run-level pattern verdict (`stays`/`lively`) + its result | `k/badge` | — | **W1** |
| `run-tile` | a scenario in the runner index: name · verdict badge · steps · world-kind | `k/stateful` card | `[:navigate "/run/<name>"]` | **W1** |

Every component binds to the **already-built** result keys:
`{:ok :verdicts :stretches :bases :projector :world :name :trace :witnesses}`,
verdict entries `{:msg :verdict :step :actor :evidence}`, and
`(bisect result n) → {:step :basis :views {actor→view}}`. Nothing in the backend
needs to change for Band A/C to render.

---

## 3. Keystone sketches (wired to real APIs)

### `timeline-scrubber` — the spine

```clojure
(defn ^{:catalog {:group "Chrono" :title "Timeline scrubber"
                  :doc "The step axis. One tick per basis, coloured by that step's verdict; the current step is lit; a tick is a jump through time — a pure local assign, no server write."
                  :tags [:chrono :time-travel]}}
  timeline-scrubber [result at]
  (let [verdict-by-step (into {} (map (fn [v] [(:step v) (:verdict v)]) (:verdicts result)))
        n (count (:bases result))]
    (b/row {:gap :1 :align :center :role "slider" :aria-label "run timeline"}
      (for [i (range 1 (inc n))]
        (let [vd  (get verdict-by-step i :none)
              tone (case vd :proven :success :witnessed :accent
                            :refuted :danger  :unknown :warning :muted)
              here (= i at)]
          [:button {:key i
                    :class (t/sx {:width (if here "22px" "14px") :height "14px"
                                  :border-radius (t/radius :sm)
                                  :background (t/color tone)
                                  :outline (if here (str "2px solid " (t/color :text)) "none")
                                  :cursor "pointer" :transition "width .12s"})
                    :aria-label (str "step " i " — " (name vd))
                    :data-ev-click (h/ev [:assign [:at] i])}])))))    ; ← the whole time machine
```

The tick's `[:assign [:at] i]` sets a **local**; the socket re-renders the pure
view at that coordinate. Same mechanism as `09-undo-redo.bl`, one term.

### `actor-stage` — one actor's world at the basis

```clojure
(defn ^{:catalog {:group "Stage" :title "Actor stage"
                  :doc "One actor's projected world AT the scrubbed basis, via the run's own projector. The generalisation of the undo-redo editor from one draft to one actor — same view, a coordinate ago."
                  :tags [:stage :time-travel]}}
  actor-stage [result at actor]
  (let [view (get (:views (s/bisect result at)) actor)]        ; ← as-of, already done by bisect
    (b/col {:gap :2 :pad :4 :radius :lg :bg :surface :border true}
      (b/row {:justify :between}
        (k/eyebrow (name actor))
        (k/status-pill (:status view)))
      (k/mono {:size :lg :tone :accent}
        (str (:promised-date view))))))                          ; the projector decides the fields
```

`bisect` already renders every actor's view at step `at` — `actor-stage` just
picks one. For a print run the projector yields `{:status … :promised-date …}`;
the stage renders whatever the projector put there (domain-neutral).

### `witness-card` — refuted, with the receipt (and the W3 media slot)

```clojure
(defn ^{:catalog {:group "Stage" :title "Witness card"
                  :doc "A refuted claim's falsifying world, framed red. The claim said X; the basis says Y — and here is Y. The media slot docks a replay frame at W3; the data shape does not change."
                  :tags [:stage :witness :refuted]}}
  witness-card [verdict view]
  (k/section {:title (str "✗ refuted — step " (:step verdict))}
    (b/col {:gap :3 :style {:border-left (str "4px solid " (t/color :danger))}
            :pad [:3 :4] :radius :md :bg :surface}
      (ui/prose {:tone :danger} (:msg verdict))
      (k/mono {:tone :muted} (str "the world at this basis: " (pr-str view)))
      ;; W3: a recording frame docks HERE — same card, richer evidence.
      (when-let [frame (:frame (:evidence verdict))]
        [:video {:src frame :controls "true"
                 :class (t/sx {:width "100%" :border-radius (t/radius :md)})}]))))
```

This is the certificate's witness (already rendered to static HTML in
`scenario-certificate.bl`) made **live and scrubbable** — and the `:frame` slot
is where W3's kernel.sh recording lands with zero structural change.

---

## 4. The two screens — which are one screen

### Screen A — the runner board `/runs` (the CI wall)

A `b/grid` of `run-tile`s: every scenario, green or red at a glance. This is the
test-runner's front door.

```clojure
(app/defscreen runs-screen [{:keys [db]}]
  (b/col {:gap :5 :max-w "1080px" :pad [:7 :6] :style {:margin "0 auto"}}
    (k/page-header {:eyebrow "Scenarios" :title "Runs"
                    :subtitle "Every story, its verdict, and a door into its timeline."})
    (b/grid {:min-col "280px" :gap :4}
      (for [r (all-runs (db :suite))]
        (run-tile r)))))                       ; tile → [:navigate "/run/<name>"]
```

### Screen B — the run detail `/run/:name` (**runner AND demo viewer**)

One screen, two modes. Scrub it → you are inspecting a proof. Press play (or,
at W3, the docked `<video>`) → you are watching a demo. *The demo is the run.*

```clojure
(app/defscreen run-screen [{:keys [db locals]}]
  (let [result (current-run db locals)
        at     (or (:at locals) (count (:bases result)))   ; default: the verdict frame
        step   (nth (:trace result) (dec at) nil)
        ref    (first (filter #(= at (:step %)) (s/refuted result)))]
    (b/col {:gap :5 :max-w "1180px" :pad [:6] :style {:margin "0 auto"}}
      ;; ── headline + transport ────────────────────────────────
      (b/row {:justify :between :align :center}
        (verdict-ribbon result)
        (transport-bar result at))
      (basis-chip result at)

      ;; ── the spine ───────────────────────────────────────────
      (timeline-scrubber result at)

      ;; ── DEMO plane: every actor's world at this instant ─────
      (b/row {:gap :4 :align :start}
        (stage-grid result at)
        (when ref (witness-card ref (get (:views (s/bisect result at)) (:actor ref)))))

      ;; ── PROOF plane: this frame + the whole claim ledger ────
      (b/grid {:min-col "360px" :gap :4}
        (step-card step)
        (k/section {:title "Claims"}
          (b/col {:gap :1} (for [v (:verdicts result)] (claim-row v at)))))

      ;; ── run-level properties ────────────────────────────────
      (b/wrap {:gap :2} (for [s (:stretches result)] (stretch-badge s))))))
```

The DEMO plane (stages) and the PROOF plane (step + claims) share **one `at`**.
That shared coordinate is the whole thesis: the thing you *show* and the thing
you *prove* are the same object at the same instant.

---

## 5. Live wiring — the app value

Mirrors `printflow.live` exactly (verified house pattern). Time-travel is a
**local**, so `:worlds`/`:observe` stay trivial.

```clojure
(defn app-value []
  {:title    "Blueprint — scenario time-travel"
   :home     "/runs"
   :theme    brand/install!
   :principal (fn [conn] (or (qparam (web/query conn) "as") "amina"))
   :worlds   (fn [_me _p] {:suite (suite-db)})     ; the runs index (shared)
   :observe  (fn [_me] [])                          ; static certificate → no live feed…
   :intents  {:bisect  (fn [_s payload _me] (assoc-local :at (resolve-target payload)))
              :rerun    rerun-scenario}             ; …unless a "re-run" transacts (then observe the conn)
   :routes   [["/runs" runs-screen]
              ["/run"  run-screen]]
   :warm-me  "amina" :warm ["/runs"]})
```

- **Scrub / step / rewind** — pure `[:assign [:at] n]`. No conn write. Works now.
- **Jump-to-refutation** — `[:intent :bisect {:to :first-refuted}]` → the handler
  reads `(:step (first (refuted result)))` and sets `:at`. Forensic bisect as a
  button.
- **Re-run** (optional) — `[:intent :rerun {}]` transacts a fresh run onto a
  shared conn; `:observe` then re-projects every socket (the printflow.live
  convergence seam). This is how a live plant feeds the runner.

---

## 6. The catalog gallery — `catalog/scenario-gallery.bl`

Every component above as a `^{:catalog …}` demo over a **fixture run** (a tiny
proven+refuted scenario computed once), so the gallery paints real timelines,
real witnesses, real verdicts — and `tooling/catalog.bl` measures coverage. Run
it the same way as `kit-gallery.bl`:

```
BL_CATALOG_LIB=<tree>/priv/lib/scenario/runner BL_CATALOG_DIR=<bp>/catalog \
mix beam_lisp.run --path priv --path <bp>/src tooling/run-catalog.bl
```

Groups: **Chrono** (scrubber, transport, basis-chip, verdict-ribbon) · **Stage**
(actor-stage, stage-grid, witness-card, belief-diff) · **Proof** (claim-row,
step-card, stretch-badge) · **Index** (run-tile). A component and its doc are the
same form → they cannot drift.

---

## 7. The one honest extension — autoplay needs a timer term

Everything above works **step-by-step today** with the closed event vocabulary.
The only affordance that does not fit is **autoplay** (the model auto-advancing
`:at` on a clock): `client.js` delegates click/input/Enter only, and the grain
rule forbids smuggling a `setInterval`. Two clean answers, both honest:

1. **W3 makes it moot.** The real demo *plays a `<video>`* (the kernel.sh
   recording docked in `witness-card`/`actor-stage`) — native browser playback,
   no timer term needed. Model-autoplay is only a W1/W2 convenience.
2. **If we want model-autoplay before W3** → propose one closed term
   `[:tick {:ms 700}]` to `20-loom-live-extensions.md` (a sanctioned client
   timer that re-posts `[:assign [:at] (inc at)]`). Small, data-shaped, testable
   as a `system` trace. Filed as **FUP-007**; not on the W1 path.

∴ ship scrub/step/bisect now; autoplay rides W3's video or a blessed `[:tick]`.

---

## 8. How the vocabulary exercises all five payoffs

| # | payoff (from `00-scenario-kernel.md` part three) | components that carry it | stage |
|---|---|---|---|
| 1 | **forensic bisect / refuted-with-witness** | `timeline-scrubber` + `transport-bar` (jump-to-refutation) + `witness-card` | **W1 now** |
| 2 | **proof-guided filming** | scrubber ticks *are* the proof's interesting steps; `branch-strip` (enumerated paths) slots above the scrubber | W2 |
| 3 | **actors with memory** | `belief-diff` — remembered expectation vs the world at this basis | W2 |
| 4 | **telemetry → datoms** | browser events become datoms on the same conn → `actor-stage`/`witness-card` gain a `:frame`; **same components** | W2/W3 |
| 5 | **demo-is-the-run** | Screen B *is* both runner detail and demo viewer; `<video>` docks into existing slots | culmination |

No payoff needs a screen the others don't. The five are **renders of one run at
one coordinate** — which is why one component vocabulary covers them all.

---

## 10. The runner kit is the whole loop, not just the viewer

The twelve loom components above are the **read** surface. But a "test scenario
runner + demo creator" is a DX product across the developer's whole loop —
**author → seed → claim → run → read** — and today only *read* has a kit. The
other four stages are hand-rolled, and that is where the real friction (and a
real bug) lives.

### The DX "before" (a real scenario today, `scenario-test.bl`)

```clojure
(def seed (datom/transact! conn [{:db/id -3 :assign/id "a-1" …}]))
(def A (get (:tempids seed) -3))          ; ← tempid bookkeeping, by hand
(defn perform [conn actor action] (cond (= (first action) :log-incident) …))  ; ← hand-rolled dispatch
(s/sees :amina
  (fn [db ctx] (time/overlaps? (:assign/span (datom/entity db A))
                               (time/interval :year 2026 :month 9 :day 3 :hour 10)))  ; ← raw closure + literal, repeated 4×
  "promise is Thursday")
```

Three DX wounds, each evidenced:
- **tempid math** — `(get (:tempids seed) -3)`. *This exact pattern caused the
  last bug*: `A` was bound to the job, not the assignment, and every claim
  silently read `nil`. A fixture builder that returns **named handles** makes
  that unrepresentable.
- **repeated interval literals** — `(time/interval :year 2026 :month 9 :day 3
  :hour 10)` written verbatim at 4+ call sites. One typo = one false verdict.
- **raw assertion closures** — `(fn [db ctx] (time/overlaps? (:assign/span
  (datom/entity db A)) …))`. The claim's *intent* ("promised Thursday") is buried
  in entity-plumbing.

### The authoring kit — `scenario.kit` (the "before the run" half)

Four component families, each a pure helper that composes with the existing
`does`/`sees`/`witness` primitives (unchanged — this is sugar over them, per the
cutover rule).

| family | component | removes | shape |
|---|---|---|---|
| **Seed** | `plant` | tempid math | `(plant conn {:job {…} :cd102 {…} :assign {…}}) → {:job eid :cd102 eid :assign eid}` — named handles, never `(get (:tempids …) -3)` |
| | `seed-fixture` | copy-paste seeds | a named, reusable plant (the "rush incident" plant once, imported by every test + the gallery + the demo) |
| **Clock** | `at` | interval literals | `(at 2026 9 3 10) → interval`; `(def thursday (at …))` names the moment once |
| | `clock` | scattered dates | a scenario's calendar in one map: `{:thursday (at …) :friday (at …)}` — the labels the film burns in |
| **Lens** | `lens` | entity-plumbing | `(lens :assign :assign/span) → (fn [db] …)` over a **named handle**; reused by claim, projector, and scrubber |
| | `project-of` | projector boilerplate | build the actor-view fn from a handle + field map, so `model-world`'s projector is declared, not written |
| **Claim** | `on` | `overlaps?` closures | `(sees :amina (on :assign thursday) "…")` — the matcher reads like the sentence |
| | `is`, `moved-to`, `became` | status/shift closures | `(is :assign :status :blocked)`, `(moved-to :assign :friday)` — composable, each carries its own witness on refute |
| **Action** | `defaction` | the `perform` cond | `(defaction :log-incident [plant] […tx…])` → a registry `perform` dispatches; the demo and the test share ONE action library |

The payoff is a scenario that reads like its own description:

```clojure
(def P (kit/seed-fixture rush-plant))          ; named handles, seeded once
(def cal (kit/clock {:thursday (kit/at 2026 9 3 10) :friday (kit/at 2026 9 4 14)}))

(s/scenario "rush incident" actors
  [(s/sees   :amina (kit/on :assign (:thursday cal)) "promised Thursday, in delay")
   (s/does   :op12  (kit/action :log-incident))
   (s/sees   :amina (kit/on :assign (:thursday cal)) "still claims Thursday — a lie")]
  [(s/stays  :amina (kit/lens :assign :assign/span) "le temps perdu reste perdu")])
```

No tempid math, no repeated literals, no entity-plumbing in the claims. The
`(kit/on :assign thursday)` matcher over a **named handle** makes last turn's
bug (wrong entity) a type error, not a silent `nil`.

### The runner — `scenario.runner` (the "drive many" half)

One scenario is a value; a **suite** is the test runner:

| component | role | serves |
|---|---|---|
| `run-suite` | run N scenarios over a chosen world, collect `[{:name :verdict :result}]` | the CI entrypoint |
| `report` | the console transcript — `✓/✗ name — because` per claim (the `verify/report-line` precedent, generalized) | the terminal loop |
| `to-certificate` | every refuted run → its HTML certificate (already built) | the artifact / PR comment |
| `to-live` | the suite → the `/runs` + `/run` screens (§4) | the demo viewer |
| `world-of` | pick `:model` / `:local` / `:kernel` by keyword | W1–W3 swap, one flag |

The thesis holds at the runner seam: `run-suite` produces **one** value; `report`
renders it for CI, `to-certificate` for the PR, `to-live` for the demo. *Same
run, three renders* — the test and the demo are the same object, finally at the
API level.

### DX-mapped to the five payoffs

| payoff | the kit component that makes it *pleasant to author* |
|---|---|
| forensic bisect | `on`/`moved-to` matchers carry a witness on refute — the author writes the claim, gets the receipt free |
| proof-guided filming | `defaction` registry = the enumerable move-set the prover walks |
| actors with memory | `witness` + `became` matcher = "she was told X, now sees Y" in one line |
| telemetry→datoms | `world-of :local` swaps the world; the SAME `plant`/`lens`/matchers author it |
| demo-is-the-run | `run-suite` → `to-live` / `to-certificate` — one run, both outputs |

### Build order correction

The **authoring kit is step 0**, before the loom viewer — it is the surface a
developer touches on every single scenario, it removes a class of bug we already
hit, and both the gallery and the demo consume its fixtures. Sequence:
`scenario-kit` (seed/clock/lens/claim/action) → `runner` (suite/report) →
`scenario-live` (the 12 viewer components) → gallery → W1 NIF.

1. **`scenario.live`** — Band A + C + `actor-stage`/`stage-grid`/
   `witness-card` (Band B W1 subset). Pure fns; test with `=` against a fixture
   run (a proven+refuted scenario), asserting hiccup shape — no browser needed.
2. **`catalog/scenario-gallery.bl`** — every component as `^:catalog`; coverage
   green.
3. **`run/serve-scenario.bl`** — the app value + `app/serve`; headless smoke
   (`app/dispatch` renders `/runs` and `/run` non-trivially, scrub changes the
   rendered basis) mirroring `printflow.live`'s `main`.
4. loom-promotion FUP (promote chrono trio into loom) + **FUP-007** (`[:tick]`/media) filed.
5. Then W1 NIF (`scenario_kernel`) fills the `:frame` slots — the components do
   not change.

Verification: each component gets a `=`-assertion test (pure hiccup); the app
gets the headless-smoke assertion (renders + scrub moves the basis); the gallery
gets catalog coverage. No hand-written unit test where a `system` trace or a
fixture-run equality will do.
