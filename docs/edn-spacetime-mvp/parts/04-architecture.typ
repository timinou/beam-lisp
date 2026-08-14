#import "../_preamble.typ": *

= Architecture

== The whole picture

#align(center)[
#diagram(
  spacing: (26pt, 16pt),
  node-stroke: 0.6pt + mutec,
  edge-stroke: 0.7pt + mutec,
  node((0, 0), [
    #text(size: 8.5pt, weight: "bold")[human] \
    #text(size: 7.5pt, fill: mutec)[mission author · follows up · clicks forms]
  ], shape: fletcher.shapes.pill, inset: 8pt, fill: panelbg),
  node((1, 0), [
    #text(size: 8.5pt, weight: "bold")[browser] \
    #text(size: 7.5pt)[compiled `spell-ui.st` shell] \
    #text(size: 7.5pt, fill: mutec)[signal graph · design language · animation]
  ], inset: 8pt, fill: tint(accent2, 88%)),
  node((2, 0), [
    #text(size: 8.5pt, weight: "bold")[`spacetime live`] \
    #text(size: 7.5pt)[sidecar: LiveStore + HTTP plane] \
    #text(size: 7.5pt, fill: mutec)[named session · snapshots · gate hook]
  ], inset: 8pt, fill: tint(seamc, 85%)),
  node((1, 1), [
    #text(size: 8.5pt, weight: "bold")[beam-lisp session process] \
    #text(size: 7.5pt)[`spell.session` `spell.st` `spell.view` `spell.gate`] \
    #text(size: 7.5pt, fill: mutec)[EDN ontology · durable store · intents]
  ], inset: 8pt, fill: tint(accent, 88%)),
  node((2, 1), [
    #text(size: 8.5pt, weight: "bold")[Spell agent harness] \
    #text(size: 7.5pt)[MCP client · tools · `st_elicit`] \
    #text(size: 7.5pt, fill: mutec)[investigation / implementation outputs]
  ], inset: 8pt, fill: tint(accent, 88%)),
  node((0, 1), [
    #text(size: 8.5pt, weight: "bold")[`spell.store` · `spell.fence` · `spell.self`] \
    #text(size: 7.5pt, fill: mutec)[named state · isolation · self-evolution]
  ], inset: 8pt, fill: panelbg),

  edge((0, 0), (1, 0), ">-", [touches], label-size: 7pt),
  edge((1, 0), (2, 0), ">-", bend: -12deg,
       [signal envelopes\ `/__mcp/signal/{id}`], label-size: 7pt, label-pos: 0.62),
  edge((2, 0), (1, 0), ">-", bend: -12deg,
       [mounts · diffs · `st-set`], label-size: 7pt, label-pos: 0.62),
  edge((1, 1), (2, 0), "<->",
       [stdio MCP (Port)\ EDN wire values], label-size: 7pt),
  edge((2, 1), (2, 0), "<->",
       [stdio MCP\ `spell.kdl`], label-size: 7pt),
  edge((0, 1), (1, 1), "-", [backs], label-size: 7pt),
)
]

Three processes, one seam. The #term[sidecar] (`spacetime live`) is the only
always-on process: it holds the session environment — mounted functions,
instances, event history — across client churn. The beam-lisp session process
and the Spell agent harness are both #emph[clients]; either may die and
reattach without the human's screen so much as flickering.

== Ownership split

#table(
  columns: (auto, 1fr, 1fr),
  inset: 6pt,
  stroke: 0.4pt + tint(mutec, 60%),
  fill: (x, y) => if y == 0 { panelbg },
  [], [*EDN / beam-lisp*], [*Spacetime*],
  [owns],
    [session ontology (mission, follow-up, turn, output, log entry) ·
     durable state · intent registry · wiring · view templates · load gate],
    [shell layout · design tokens · typography · animation · transitions ·
     shell-local signals (hover, open/closed, scroll) · kit components],
  [speaks],
    [EDN values; MCP tool calls; intent names],
    [compiled signal graph; JSON envelopes at the browser edge only],
  [fails when],
    [state transitions violate the ontology; an intent is unhandled],
    [a referenced signal or slot does not exist; contract fingerprint drift],
)

#invariant[
  One signal graph exists, and it lives in Spacetime. EDN #emph[references]
  signals (`$turn-open`, `$log-at-tail`, kit action signals) by name; it never
  implements reactivity. Durable truth lives in `spell.store`; derived liveness
  lives in the browser; the sidecar holds the join.
]

== The four seams

+ #strong[Session → sidecar (control).] beam-lisp speaks MCP over a Port's
  stdio: `st_fn_put` (shell + kit functions, once per boot), `st_mount`
  (the session shell with the mission as input), tool results via
  `resources/subscribe` notifications (IMP-A3) or `st_await` fallback.
  Wire values are EDN (IMP-N5) normalised internally to JSON for the browser.
+ #strong[Agent → sidecar (drive).] The Spell harness attaches as a second
  MCP client. Its tools are the same `st_*` surface; its outputs arrive as
  EDN writes to the session ontology (through the beam-lisp process, not
  directly to the shell) — see §5.3.
+ #strong[Browser → sidecar (signal sink).] Unchanged from today: one generic
  sink, envelopes routed by destination (IMP-N2) to agent waiters, the log
  stream, or (fast-follow) named intents.
+ #strong[Sidecar → browser (liveness).] Unchanged: compiled bundles, `st-set`
  assign diffs, stream pushes. The shell is `phx-update="ignore"` territory;
  templates are never diffed, only data.

== Why not…

#defn("…put the session state in the browser?")[
  The duet's mission state must survive reloads, hot-swaps, and browser
  crashes, and must be transformable by optics/Specter (§8). Browser signals
  are the projection, not the truth.]
#defn("…let the agent write the shell directly?")[
  That recreates chat-with-HTML. The agent writes #emph[outputs into the
  ontology]; the shell decides how ontology renders. Layout authority stays
  in one place — the `.st` design language — which is what makes the
  interface feel designed rather than accumulated.]
#defn("…a Phoenix LiveView in the middle?")[
  The bridge (§2.3) is the proof of pattern, and the fast-follow answer for
  multi-user or server-rendered deployments. For the single-operator Spell
  session, the sidecar + MCP already provides everything the bridge provides,
  with one fewer process and no HEEx anywhere. The EDN gate mirrors the
  bridge's contract discipline, so adopting the bridge later is a host
  change, not a redesign.]
