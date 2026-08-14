#import "../_preamble.typ": *

= Modules: the settlement to reach

New code is deliberately small. Each module below is one job at one level of
abstraction; together they replace `spell.ui` + `spell.clay` (≈200 lines of
pixel vocabulary and an unimplemented Port client) with a session vocabulary
and a client of an already-shipped protocol.

== beam-lisp side (`spell/src/spell/`)

#module("spell.session", "ONTOLOGY",
  owns: [the session schema (§5.1), transition rules, mission/follow-up/turn
         constructors, output assembly, the `:wiring` table, schema versioning
         and fingerprints],
  disowns: [rendering, transport, signals])[
  Pure functions over the session value plus `spell.store` persistence. Every
  mutation is a constructor call that validates against the ontology rules;
  invalid transitions are `{:error …}` data, never exceptions. This is the
  module the agent's outputs flow through — the agent never writes the shell,
  it asks `spell.session` to close a turn with an output.
]

#module("spell.st", "BOUNDARY",
  owns: [the Port to `spacetime live`, stdio JSON-RPC framing, EDN↔wire
         encoding (IMP-N5), tool-call wrappers (`fn-put!`, `mount!`,
         `await-event`, `subscribe!`), reconnect with cursor resume],
  disowns: [session semantics, gate logic, what to mount])[
  The only module that knows MCP exists. Everything else speaks EDN function
  calls. Reuses the trust-boundary rule already documented for `spell.clay`:
  incoming lines go through the bounded data reader, never `eval`.
]

#module("spell.view", "TEMPLATE",
  owns: [session value → shell projection; turn-output EDN → kit mount specs;
         markdown body handling; the template macros (`defoutput`,
         `defform`) that keep agent-authored outputs concise],
  disowns: [layout, styling, anything `.st`])[
  A pure compiler from ontology to mount payloads. Its output is exactly the
  `@mcp-input` shape of `spell/shell` and the kit functions — verified
  against the gate's registry, so "compiles" implies "renders".
]

#module("spell.gate", "PROOF",
  owns: [the §5.4 checks: signal existence, slot existence, intent
         registration, contract fingerprints; verdict records into the log;
         the parked/last-good posture],
  disowns: [fixing anything])[
  Reads the sidecar's self-describing registry (via `spell.st`) and the
  session's wiring; returns verdicts. Registered with the sidecar as the
  external gate hook (IMP-N1). The gate is the duet's immune system: it
  makes inconsistency a load-time event with a name and a log entry.
]

#module("spell.intent", "INTENT — fast-follow",
  owns: [the intent registry (`:intents`), dispatch of `:to :intent`
         envelopes to beam-lisp ops, intent result → session writes],
  disowns: [agent policy])[
  Async buttons wired directly to beam-lisp operations (§9). An intent is a
  namespaced, gated, fence-executed function from payload to session
  mutation. MVP ships the registry shape and the gate check; dispatch turns
  on in the fast-follow.
]

== Spacetime side (`spell-ui/` in the session workspace)

#module("spell-ui/shell.st", "SURFACE",
  owns: [the whole layout: mission hero, attachment timeline, turn blocks,
         log drawer, composer dock; design tokens, type scale, palette;
         all animation],
  disowns: [session semantics, durable state])[
  One function, hot-swappable (IMP-A2), contract-stable against the gate's
  fingerprint. Authored in the full design language; reviewed as design,
  never edited by the agent.
]

#module("spell-ui/log-stream.st", "SURFACE",
  owns: [rendering the session event feed as the deeper log: grouping,
         collapse, kind badges (tool / gate / action)],
  disowns: [event production])[
  The IMP-N4 component. Fed by an `@data stream` over the sidecar's event
  feed; stateless beyond scroll/collapse signals.
]

== Retired / unchanged

#table(
  columns: (auto, auto, 1fr),
  inset: 6pt,
  stroke: 0.4pt + tint(mutec, 60%),
  fill: (x, y) => if y == 0 { panelbg },
  [*module*], [*fate*], [*why*],
  [`spell.ui`],    [retired],  [pixel vocabulary with no design language; subsumed by `.st`],
  [`spell.clay`],  [retired],  [dumb-renderer protocol; subsumed by `spacetime live` + MCP],
  [`spell.store`], [kept],     [durable named state + wire taps; now backs `:session` and gate tests],
  [`spell.fence`], [kept],     [isolation; wraps intent dispatch and gate checks on untrusted payloads],
  [`spell.self`],  [kept, extended], [self-evolution of `.bl` sources; §8 adds view-term introspection],
  [`spell.providers`], [unchanged], [model/agent contracts; orthogonal to the view duet],
)

#decision[
  The duet deletes more than it adds: two modules retired, five new ones of
  which three (`session`, `view`, `gate`) are pure data-and-rules with no
  I/O. The system's complexity moves from protocol plumbing into one
  explicitly-checked seam — which is exactly where complexity can be gated,
  logged, and evolved.
]
