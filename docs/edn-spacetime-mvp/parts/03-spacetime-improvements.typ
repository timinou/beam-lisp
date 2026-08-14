#import "../_preamble.typ": *

= Required Spacetime improvements

Two classes. #strong[Assumed] improvements are already planned in
`verse/!tasks` and are taken as given (this spec only names the dependency).
#strong[New] improvements are what the duet itself requires and does not get
for free.

== Assumed (planned upstream)

#req("IMP-A1", "Self-describing function interfaces", status: "assumed")[
  FEAT-111 / PLAN-038: a mounted function exposes its `@mcp-input` payload
  shape, signal registry, transports, and response sums through `st_inspect`
  and MCP resources. The duet's load gate (§5.4) reads this registry; without
  it there is no load-time consistency proof.
]

#req("IMP-A2", "Contract-stable hot-swap in the live environment", status: "assumed")[
  FEAT-124: `st_fn_put` with a compatible contract hot-swaps a mounted
  function without dropping its instance or event history. The duet needs
  this so the shell (design language) and the session (EDN state) can evolve
  on independent clocks.
]

#req("IMP-A3", "Automatic event surfacing", status: "assumed")[
  PLAN-040 / FUP-168: `resources/subscribe` produces real
  `notifications/resources/updated`; instance event streams surface into the
  Spell session without polling. `st_await` remains the explicit fallback.
  The duet's "submission arrives the moment the user clicks" experience
  depends on this.
]

#req("IMP-A4", "Interaction kit with async buttons", status: "assumed")[
  PLAN-043 / PLAN-044: picker/confirm/form/review as plain `.st` functions
  with `@mcp-input`, `@mcp-action`, `@mcp-submit`. The duet's forms and
  fast-follow async buttons are kit instances, not new machinery.
]

#req("IMP-A5", "LiveView bridge: contract emission + host skeleton", status: "assumed")[
  FEAT-160 (server-emitted contracts), FUP-121 (compiler-emitted host DOM
  skeleton), FEAT-138 (Mix compiler + hot `.st` reload). Required for the
  BEAM-resident durable tier (§4) to host `.st` pages without hand-mirrored
  skeletons or manual cargo builds.
]

== New (this spec)

#req("IMP-N1", "`spacetime live` — a sidecar-grade environment verb")[
  A new CLI verb beside `mcp` and `workbench`, same process shape as
  `spacetime mcp` (stdio JSON-RPC + HTTP live plane), with three changes of
  character:

  + #strong[Named, persistent sessions.] `spacetime live <session>` opens (or
    re-opens) a named live environment. Environment state — functions,
    instances, event history, cursors — snapshots to
    `<session>/.live/*.json` on every mutation and restores on boot. Client
    disconnect no longer implies state loss; the sidecar keeps the whole thing.
  + #strong[Multi-attach.] More than one MCP client (the Spell agent
    #emph[and] the beam-lisp session process) may attach to the same session;
    each gets its own cursor over the shared event history.
  + #strong[Load gate hook.] On session open and on every `st_fn_put` into a
    gated environment, a registered external checker runs before the function
    goes live (§5.4). Fail → the function stays parked and the gate's
    diagnostics are returned as the tool result.

  Non-goals: no CDP wave, no workbench changes, no new transport — it _is_
  the mcp server, with persistence, naming, and a gate.
]

#req("IMP-N2", "Dual-destination action routing")[
  Today an async button's envelope has exactly one audience: the agent that
  called `st_await`. The duet needs each action to declare its destination at
  authoring time:

  #st(```
  @mcp-action $approve : to agent ;        // st_await resolves (today)
  @mcp-action $retry   : to log ;          // appends to session log stream only
  @mcp-action $refine  : to agent+log ;    // both
  @mcp-action $run-op  : to intent "spell.ops/refine" ;  // fast-follow (§9)
  ```)

  `to log` envelopes are recorded into the session event history and rendered
  by the shell's log stream, but resolve no waiter. This is a small,
  backward-compatible envelope extension (`audience` field, default
  `agent`) plus shell rendering support.
]

#req("IMP-N3", "Markdown slots in mounted shells")[
  `stdlib/md` renders markdown strings today. The shell (§5.2) needs markdown
  #emph[slots]: named regions whose content is data supplied per instance
  (mission statement, output bodies), hot-swappable without recompiling the
  shell. Concretely: `@mcp-input` fields typed `markdown`, rendered through
  `render-markdown` inside a slot node. This is stdlib work, not compiler work.
]

#req("IMP-N4", "Session log stream component")[
  A stdlib shell component rendering the session event history as an
  append-only, grouped, collapsible log (tool calls, gate verdicts,
  `to log` button events), driven by an `@data stream` fed from the live
  plane's event feed. The deeper-log affordance of the MVP experience (§6)
  is this component. Mostly stdlib; requires the live plane to expose the
  per-session event feed as a subscribable stream (a thin read over
  `LiveStore` history + notifications from IMP-A3).
]

#req("IMP-N5", "EDN wire values in tool arguments")[
  beam-lisp's native tongue is EDN, not JSON. `spacetime live` accepts an
  `edn` media type on `st_fn_put` input payloads and `st_mount` inputs, parsed
  by the existing bounded EDN reader and normalised to the same internal
  values. This keeps the duet's wire honest: EDN all the way from the BEAM to
  the gate, JSON only where the browser already speaks it. (Small; can be
  fast-followed if it threatens the MVP.)
]
