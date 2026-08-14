#import "../_preamble.typ": *

= Roadmap: MVP → fast-follow → later

#stage("MVP", "The duet stands up")[
  + `spacetime live` verb: named sessions, snapshots, multi-attach, gate hook
    (IMP-N1), on top of the assumed MCP improvements (IMP-A1…A4).
  + `spell-ui/shell.st`: mission hero, attachment timeline, turn blocks with
    hero markdown outputs, composer, kit forms mounted per output (IMP-N3
    markdown slots; IMP-A4 kit).
  + beam-lisp modules: `spell.session`, `spell.st`, `spell.view`,
    `spell.gate` — pure ontology + one MCP client + one pure projection
    compiler + the load gate (§5.4).
  + Experience 1–3 as specced (§6), with form submissions consumed at turn
    boundaries; `:to :log` routing live (IMP-N2).
  + Test discipline: `spell.store` taps over MCP frames; gate verdicts
    asserted as log data; one scripted end-to-end session (mission →
    follow-up → picker → submission) replayed headlessly.
]

#stage("FF-1", "The duet gets conversational")[
  + Intra-turn forms: agent emits a form and blocks on `st_await`; async
    buttons (`:to :log`) write into the log stream on click (IMP-N2
    audiences, IMP-A3 notifications).
  + `spell.intent` dispatch: buttons wired directly to beam-lisp ops
    (`:to :intent "spell.ops/refine"`), fence-executed, results written back
    to the session; the gate already proves the wiring.
  + Session fork/branch: a mission variant explored in a forked session value,
    merged by optics transforms — the first real payoff of keeping the
    interface as a value.
]

#stage("FF-2", "The duet becomes a place")[
  + LiveView host option: adopt `spacetime_lv` as the durable tier for
    multi-operator or server-rendered sessions, using the bridge's contract
    machinery (IMP-A5) — a host change, not a redesign (§4.3).
  + Self-evolution graduated: hooks promoted to intents, `spell.self`
    unblocked for Level-3 changes, shell hot-swap driven by gate-approved
    `.st` proposals from the agent itself (IMP-A2 + IMP-N1 gate hook).
  + Visual REPL / inspector panes for the session, per `docs/live-repl.md`,
    mounted as regions beside the shell.
]

== What settles this spec

The decisions marked #text(fill: goodc.darken(15%), weight: "bold")[DECISION]
and #text(fill: accent2.darken(25%), weight: "bold")[OPEN QUESTION] are the
settlement surface:

+ the ownership split (§4.2) — EDN never expresses layout; `.st` never holds
  session semantics;
+ one shell function vs. many mounted regions (§5.2 chose one function +
  kit mounts inside output regions);
+ forms as kit instances inside turn outputs vs. a bespoke form system
  (§5.3 chose kit);
+ hooks as gated data via Specter vs. free code hooks (§8 chose data);
+ hook placement: session value vs. source (§8 open question);
+ MVP form round-trip at turn boundaries vs. intra-turn (§5.3 note, §9).

#align(center)[
  #block(inset: (x: 18pt, y: 10pt), radius: 4pt, fill: tint(seamc, 88%))[
    #text(size: 11pt)[
      The interface is a value. The surface is a language. \
      The sidecar keeps the whole thing, and the gate keeps them honest.
    ]
  ]
]
