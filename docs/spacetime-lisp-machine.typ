#set document(title: "Spacetime's Lisp Machine", author: "ora")
#set page(paper: "a4", margin: 2.2cm, numbering: "1")
#set text(font: "New Computer Modern", size: 10.5pt)
#set heading(numbering: "1.1")
#show raw.where(block: true): set text(size: 8pt)

#align(center)[
  #text(size: 20pt, weight: "bold")[Spacetime's Lisp Machine]
  #v(0.4em)
  #text(size: 12pt, style: "italic")[One compiler, one runtime, and a beam-lisp harness that owns state and evolves the face it does not render]
  #v(0.4em)
  #text(size: 9pt)[2026-08-10 · architecture · status: agreed design, unimplemented]
]

#v(0.5em)

= Zero-context grounding

Three systems meet in this document. Each is introduced as if you have never
seen it.

*beam-lisp* is a Clojure dialect that compiles to Elixir's quoted expressions
and thus to ordinary BEAM bytecode: processes, OTP supervision, per-process
garbage collection, hot code reloading, and the entire Elixir/Erlang library
ecosystem, with interop as a calling convention rather than a bridge. Its own
README states the pattern it follows: jank ships its language as data, the
BEAM ships a compiler with a homoiconic AST, and beam-lisp is only the
missing middle.

_spell/_ is a study inside the beam-lisp repository: recreate spell.jank — a
self-rewriting agent harness with a rendered GUI — as first-principles as the
BEAM allows. Its analysis clusters every primitive by the _force_ it answers:
BOUNDARY (untrusted bytes ↔ terms), PROCESS (external programs that may die),
FENCE (bounded failure), STORE (state outliving code), SELF (rewriting
yourself safely), VIEW (UI as data), AGENT (the LLM loop). A seventh force —
the event pump — dissolves because sources are processes. The study's VIEW
cluster was, until now, a transliteration of an immediate-mode clay renderer
protocol. This document replaces it entirely.

*Spacetime* is a declarative interface language (`.st` files) compiled by a
Rust compiler to JavaScript/CSS bundles. Named, typed signals hold state;
selector blocks bind state to the document; intents fire events and consume
tagged, correlated replies through pattern-matched arms; optimistic
mutations roll back via snapshots; a macro tower (`%form` / `%binds` /
`%registers`, with authored near-miss diagnostics) makes the language
extensible while lowering everything to a small set of primitives. A mature
Phoenix LiveView vertical (`spacetime_lv`) has already proven the bridge
protocol this design inherits, end-to-end in a browser:

- the server owns authoritative state; the compiled bundle owns the entire
  view; all communication is _data, never templates_;
- server → view: module-scoped assign diffs (`st-set`), including the full
  seed on (re)connect — which makes reseeding an already-solved mechanism;
- view → server: declared events; replies arrive as tagged envelopes
  (`{:reply, %{tag, reply}}`) and decode through the page's own receive arms,
  with latest-wins correlation policies;
- the seam is checked both directions at compile time (E0928-family) against
  a deterministic contract; a page emitting an undeclared event is a compile
  error, not a runtime surprise.

A companion document (`spacetime-interface-as-value.typ`) proposed that the
compiler emit a third artifact beside the JS and CSS: `page.stir`, the page's
total self-description as data — selector tree, signal graph, receive sums,
handler syntax trees, contract mirror, fact database. This document depends
on that artifact and gives it its destiny: the `.stir` is written as
_s-expressions_, making it natively homoiconic to beam-lisp.

= The architecture

Three pieces, one direction of truth:

```
verse/  Rust compiler — the ONE brain
   .st ──► parse · macro tower · typecheck · lower
        ├──► spacetime.js bundle     (the ONLY runtime that executes a page)
        └──► page.stir               (s-expr term: skeleton · facts · contract)

webview/browser — the ACTUAL Spacetime runtime
   signals, flip, gestures, editable, presence — battle-tested

        ▲ st-set diffs · streams · ephemeral      (BEAM → runtime)
        ▼ send emit · replies                     (runtime → BEAM)

beam-lisp spell/ — authority + workbench
   owner processes (assigns/events/pushes — the contract source)
   STORE · FENCE · SELF · the agent loop
   .stir surgery bench — homoiconic evolution, compiler canonicalizes
```

The roles, stated as invariants:

+ *One brain.* The Rust compiler is the only language implementation that
  exists, ever. beam-lisp never parses `.st`, never pattern-matches a
  `%form`, never typechecks, never lowers. Macros — the standard library's
  forty, any future ones — live in `.st` and are the tower's business.
+ *One runtime.* The compiled bundle executes every page. The BEAM contains
  no page interpreter, no expression evaluator, no parallel semantics —
  nothing to drift, nothing to conformance-test against the real thing.
+ *One lisp machine.* beam-lisp owns authoritative state and the agent loop,
  and treats `.stir` terms as data: reading them (its bounded data reader —
  BOUNDARY — consumes one term, no evaluation, no atom interning),
  transforming them with ordinary sequence functions, and submitting the
  results to the one compiler for canonicalization.

beam-lisp plays Phoenix's role from the proven LiveView vertical — minus
Phoenix: the seam is a mailbox on the BEAM side, a websocket on the runtime
side.

= The term: `.stir` as a lisp

The compiler's emit pass writes s-expressions. This single artifact is what
the bridge serves as skeleton, what the agent reflects upon, what evolution
operates on, and what the contract fingerprint covers:

```clojure
;; counter.stir — emitted by the ONE compiler. Data, not code.
(page counter
  {:schema {:version 1 :fingerprint "9f2a…"}
   :facts  {:count {:type :int :source :subscribe :writable false}
            :error {:type :string :source :local :writable true}}
   :events {"inc" {} "dec" {}}}

  (signals
    ($count :int    {:from {:owner :counter :assign :count} :zero 0})
    ($error :string {:initial ""}))

  (intents
    (intent $inc []
      {:send {:event "inc"} :policy :latest}
      (arm [:bumped n] (do (<- $count n) (<- $error "")))
      (arm [:failed m] (<- $error m)))

    (intent $dec []
      {:send {:event "dec"} :policy :latest
       :optimistic (<- $count (- $count 1))}
      (arm [:bumped n] (do (<- $count n) (<- $error "")))
      (arm [:failed m] (do (<- $count :snapshot) (<- $error m)))))

  (view
    (node :.counter {:sizing :fit :dir :column :gap 16 :padding 24}
      (node :.value    {:text (bind $count) :size 96 :font :mono :color :accent})
      (node :.error    {:text (bind $error) :size 14 :color :red})
      (node :.controls {:dir :row :gap 8}
        (node :button.inc {:on {"mouse-down" (fire $inc)}} "+")
        (node :button.dec {:on {"mouse-down" (fire $dec)}} "−"))))

  (clock :virtual))
```

Properties to read off it:

- *Bodies are syntax trees.* The compiler normalizes `.st`'s infix writes
  (`$count <- n`) to prefix forms. Bodies never execute on the BEAM; they
  exist here for reflection, transformation, and re-emission.
- *Reply variants are plain terms.* The `"ok" => Bumped(…)` decode layer of
  the JSON bridge dissolves: a BEAM owner replies `[:bumped 3]` directly,
  and the page's arms pattern-match native terms.
- *Dependencies are explicit.* `(bind $count)` is data; nothing re-derives
  scope on this side.
- *Node identity is compiler-assigned* (elided above), one scheme serving
  live patching and layout-motion retargeting alike.
- *Facts ride inside the term* — emitted by the compiler, never accumulated
  as side effects, so the term alone is sufficient for reflection and
  re-validation.

= The authority: owners as processes

The harness side of the seam is a declared owner — the contract's source of
truth, in plain beam-lisp:

```clojure
(defowner counter
  (assigns (count :int))                  ;; the st-set seed + diff source
  (events  (inc) (dec) (reset))           ;; page may emit these; checked
  (pushes  (flash (message :string)))     ;; transient streams

  (handle "inc" []
    (store/swap! [:assign :counter :count] inc)
    (reply {:tag "ok" :reply (store/get [:assign :counter :count])}))

  (handle "dec" []
    (let [c (store/get [:assign :counter :count])]
      (if (pos? c)
        (do (store/swap! [:assign :counter :count] dec)
            (reply {:tag "ok" :reply (dec c)}))
        (reply {:tag "failed" :reply "can't go below zero"}))))

  (every 1000 (store/swap! [:assign :counter :count] inc)))
```

Assigns live in STORE (named processes; identity by name, surviving code
replacement). Mutations push `st-set` diffs to subscribed runtimes —
push-native, with no render-cycle reconciler. Declarations are checked
against the page by the compiler (E0928, both directions), exactly as in the
LiveView vertical.

= The bridge: `spell.rt`

The namespace that was `spell.clay`, reborn with a new protocol and the same
cluster anatomy (PROCESS + BOUNDARY):

+ *Spawn* the webview/browser as a Port — handshake bounded by monotonic
  time, monitor, `:transient` restart declared in the supervisor. A renderer
  crash cannot take the harness; an orphaned renderer is a shape the platform
  refuses.
+ *Serve* one websocket that the runtime's small bridge hook connects to.
+ *BOUNDARY*: every frame off the wire is read by the bounded data reader —
  never evaluated, never interning fresh atoms — and matched against the
  owner's declared event vocabulary. Unknown events are refused, by name.
+ *Route*: events to owner mailboxes; owner replies back, correlated;
  STORE diffs to `st-set` fan-out.

= The evolution loop

The harness's thesis cluster is SELF — rewriting yourself safely. Its
discipline (compile without loading; install atomically; verify through a
fence with a deadline; revert to a remembered artifact that _cannot fail to
compile — it already did_) applies to the interface verbatim. An evolution,
end to end:

```clojure
;; goal, mid-turn: the counter needs a reset button

(def ir (spell.page/reflect 'counter))      ;; the live term is data

;; surgery with ordinary sequence functions — no macro system, no DSL:
(def ir2
  (-> ir
      (conj-intent (quote (intent $reset []
                      {:send {:event "reset"} :policy :latest}
                      (arm [:bumped n] (<- $count n)))))
      (conj-event  "reset")
      (conj-view   [:controls]
                   (quote (node :button.reset {:on {"mouse-down" (fire $reset)}} "0")))))

;; the ONE brain checks the work — errors arrive as DATA:
(spell.spacetime/validate ir2)
;; → {:error [{:code "E0928"
;;             :message "owner :counter declares no event \"reset\""
;;             :hint "owner declares: inc, dec"}]}

;; fix the owner, re-validate:
(spell.spacetime/validate ir2)
;; → {:ok canonical}              ;; re-fingerprinted; deps recomputed

;; rehearse in the REAL runtime — deterministic clock, recorded events:
(spell.page/rehearse canonical {:cassette "counter-clicks.edn" :clock :virtual})
;; → {:ok {:frames 12 :assertions-passed true}}

;; install: new bundle emitted from the canonical term, hot-swapped;
;; assigns ride through on the existing reconnect-reseed mechanism;
;; the previous (term, bundle) pair is remembered:
(spell.page/install! 'counter canonical)

;; on any later grief:
(spell.page/revert! 'counter)
;; — a remembered term cannot fail to interpret; a remembered bundle
;;   cannot fail to compile. The failure mode does not get handled;
;;   it stops existing.
```

What makes this loop unprecedented rather than merely pleasant:

- *Rehearsal before installation.* The candidate interface performs itself
  against recorded reality, under a deterministic clock, before it earns the
  screen. Changing a live UI stops meaning "ship and look."
- *Evolutions are values.* The surgery input, the canonical term, the
  E-codes, the rehearsal verdict, and the install record are all data —
  appendable to an evolution log, diffable, replayable, shareable between
  harness instances. Interfaces gain what code has had for decades:
  versionable, transactional change.
- *The agent is inside the check loop.* Compile diagnostics arrive as
  structured terms the model can reason about — self-correction in one turn
  instead of log-scraping.

= The deletion ledger

This design is as much what it removes as what it adds. Recorded honestly:

#table(
  columns: (auto, 1fr),
  inset: 6pt,
  stroke: 0.5pt + gray,
  [*removed*], [*fate*],
  [clayd (C++/raylib renderer)],
  [deleted; the window is a webview running the compiled bundle],
  [clay wire protocol (`:cmd :frame` / `:event` EDN lines)],
  [deleted; replaced by the proven st-set / emit / reply bridge protocol],
  [`ui.bl` — el/text/realize transliteration],
  [deleted; VIEW is pages. Grapheme-exact editing survives in the runtime's
   own editable primitive],
  [ANSI terminal renderer (clay-protocol speaker)],
  [deleted with clay; a terminal UI may return later as a `.stir`
   projection, never as a clay revival],
  [BEAM page interpreter (considered, rejected)],
  [deleted before birth: no expression evaluator, no parallel semantics,
   no conformance suite — one runtime executes every page],
  [60fps realize-everything pump],
  [deleted twice over: the runtime's signal graph invalidates; nothing
   polls],
)

= Implementation readiness

Rough edges pinned before the work begins:

+ *Compiler daemon, not per-call spawns.* Validation round-trips are on the
  agent's critical path; the compiler runs as a persistent daemon Port with a
  handshake, not a process per attempt.
+ *The owner API is real work.* `defowner`, `handle`, `reply`, `every` are
  specified here as contracts, not implementations; they deserve the same
  rigor as the page side.
+ *BOUNDARY stays binary-safe.* Vocabulary and event names cross the wire as
  binaries; nothing interns atoms from wire tokens. This is the reason the
  trust-boundary reader exists.
+ *Page-local state across hot-swap.* Assigns ride through reseed by
  construction; page-local signals survive only via declared seeds (typed
  subscriptions with zero-values). The fuller snapshot story is the
  companion document's L1 thread, filed honestly rather than assumed.
+ *The skeleton comes from the compiler.* The runtime host's DOM skeleton is
  emitted from `.stir` (the LiveView vertical's hand-mirrored-skeleton
  defect, cured as a side effect).

Compiler-side asks (in the verse repository, all aligned with the companion
document's W0/W1): emit `.stir` as s-expressions · a validate/canonicalize
mode accepting `.stir` input · bundle emission from canonical terms ·
compiler-assigned stable node ids · the bridge hook retargeted from the
Phoenix channel to a plain websocket.

= Layout

```
verse/                            the ONE brain
  src/emit_stir.rs                .stir emit · validate/canonicalize · skeleton
  stdlib/…                        the macro tower, growing in .st

beam-lisp/spell/src/              authority + workbench
  spell/rt.bl                     runtime bridge (PROCESS+BOUNDARY; ws + Port)
  spell/owner.bl                  defowner: assigns/events/pushes, replies
  spell/spacetime.bl              compiler daemon client
  spell/page.bl                   reflect · rehearse · install · revert
  spell/store.bl fence.bl self.bl providers.bl
  pages/*.st                      the harness's own UI, authored in spacetime
  pages/*.stir                    canonical terms; the evolution log beside them
```

= The through-line

#align(center)[
  #text(size: 11.5pt)[
    *The template is data.* — the compiler says everything it knows. \
    *The conversation is a process.* — authority lives where concurrency is native. \
    *The language has one brain, and the machine has none of its own.*
  ]
]

One compiler thinks. One runtime renders. One lisp machine owns the state,
checks nothing it is not the authority for, and evolves the face it does not
render — through a loop where every intermediate is a value, every check is
data, and every mistake is revertible by construction.
