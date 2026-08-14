#import "../_preamble.typ": *

= Purpose: the duet

The Spell interface is re-founded as a #term[duet] between two homoiconic
languages that each keep what they are best at:

- #strong[EDN (beam-lisp, `.bl`)] owns the session ontology: missions,
  follow-ups, turns, agent outputs, forms, wiring of intents, durable state,
  and the templates and basic macros that produce them. EDN terms are data;
  the interface is a value held, transformed, and submitted by the BEAM side.
- #strong[Spacetime (`.st`)] owns presentation: layout, the design language,
  styling, animation, transitions, and shell-local reactivity. It is the
  compiled, live, browser-executed surface the human actually touches.

The seam between them is narrow and typed: an EDN view term compiles to a
#emph[mounted Spacetime function instance] whose inputs are EDN→JSON payloads,
and any Spacetime signal the EDN references by name is validated at
live-environment load time. If the duet disagrees with itself, it refuses to
start — it never limps.

== Why Clay goes away

The current view layer (`spell/src/spell/ui.bl` + the `spell.clay` contract
stub) renders pure EDN trees to a dumb external renderer over a line-oriented
Port protocol:

#edn(```
{:cmd :frame :tree <tree>}
{:cmd :screenshot :path "..."}
{:cmd :inject :event <ev>}
{:cmd :quit}
```)

This was a sound study in boundaries, but as the Spell interface it loses on
every axis that now matters:

#table(
  columns: (auto, 1fr, 1fr),
  inset: 6pt,
  stroke: 0.4pt + tint(mutec, 60%),
  fill: (x, y) => if y == 0 { panelbg },
  [*axis*], [*Clay path*], [*Spacetime path*],
  [design language],
    [none — raw props (`:bg`, `:padding`) on EDN maps],
    [first-class: selectors, tokens, transitions, `@flip`, keyframes],
  [reactivity],
    [thunks + refs re-realized per frame by the harness],
    [compiled signal graph; `@data signal/stream`, `@handle`, optimistic arms],
  [interaction],
    [events arrive as raw maps; no kit, no forms],
    [shipped interaction kit: picker / confirm / form / review with async buttons],
  [agent driveability],
    [bespoke protocol, unimplemented client],
    [`spacetime mcp` tool surface (`st_fn_put`, `st_mount`, `st_await`, `st_elicit`)],
  [server state],
    [would have to be invented],
    [LiveView bridge: assigns, typed pushes, "diff data, never templates"],
  [liveness],
    [renderer process, one frame at a time],
    [persistent live environment; hot-swap; self-describing functions],
)

#decision[
  Clay is not replaced by a better renderer. It is replaced by a better
  #emph[relationship]: the EDN side stops describing pixels and starts
  describing the session; Spacetime, which already knows how to be a live
  interface for agents, becomes the surface. `spell.clay` and `spell.ui`'s
  pixel vocabulary are retired; `spell.store`, `spell.fence`, and the
  BOUNDARY/SELF/AGENT contracts survive unchanged.
]

== The one-sentence spec

#invariant[
  A mission is an EDN value. Its rendering is a Spacetime shell. The shell is
  kept alive by `spacetime live`, a sidecar-grade environment that outlives
  any single agent client, and every cross-reference between the two languages
  is proven consistent before the first frame is shown.
]

== Non-goals (MVP)

- No replacement of the Rust compiler or of beam-lisp's evaluator.
- No new reactive system on the EDN side — EDN signals are #emph[references
  into] the Spacetime signal graph plus Store-backed durable values, not a
  third runtime.
- No chat UI. The interface is a mission surface, not a message list.
- No visual REPL / inspector panes (that is `docs/live-repl.md`'s job, later).
