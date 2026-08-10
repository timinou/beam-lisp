#set document(title: "The Interface as a Value", author: "ora")
#set page(paper: "a4", margin: 2.2cm, numbering: "1")
#set text(font: "New Computer Modern", size: 10.5pt)
#set heading(numbering: "1.1")
#show raw.where(block: true): set text(size: 8.5pt)

#align(center)[
  #text(size: 20pt, weight: "bold")[The Interface as a Value]
  #v(0.4em)
  #text(size: 12pt, style: "italic")[Compiling Spacetime to three artifacts, and what serialisability unlocks]
  #v(0.4em)
  #text(size: 9pt)[2026-08-10 · design exploration · status: vision, unimplemented]
]

#v(1em)

= What this is about, from zero

*Spacetime* is a small declarative language for user interfaces. A page is a
`.st` file: named, typed _signals_ hold state; selector blocks bind state to
the document; `@on` handlers fire signals on events; `@handle` arms consume
tagged replies. A Rust compiler turns a page into a JavaScript bundle plus a
stylesheet. The language has a macro system (`%macro`) that works as a
pattern-matching rewrite engine over surface syntax: a macro declares a
`%form` (the syntax it matches, with typed captures), a `%binds` clause (the
primitives it lowers to), and a `%registers` clause (facts it publishes into
a compile-time database — names, types, static-ness, source kinds).

*The Phoenix bridge.* A page can be hosted by a Phoenix LiveView
(`spacetime_lv`). The LiveView owns the socket and the authoritative state;
the Spacetime bundle owns the entire view. All communication is _data, never
templates_: the server pushes assign diffs (`st-set`), the page fires events
and receives tagged replies (`{:reply, %{tag, reply}}` decoding into the
page's own declared sum types). The seam between the two is governed by a
*contract*: the server declares which events, assigns, and pushes exist; a
deterministic JSON sidecar (`XLive.contract.json`, sha256-fingerprinted) is
checked against the page at compile time. A page that emits an event the
server never declared is a compile error, not a runtime surprise — and vice
versa.

Two facts of the current system matter for everything below:

+ *Declarations are already data.* Every entity a page declares lands in the
  compiler's fact database. The showcase gallery already _generates itself_
  from those declarations; typed subscribes auto-seed their zero value; a
  read of a field the type does not have is a compile error with a
  did-you-mean. The compiler knows everything about the page.
+ *The skeleton is hand-mirrored.* The LiveView host re-states the page's DOM
  skeleton by hand (three copies today), each one silently drifting from its
  `.st` source. This is a recorded defect with a known cure: the compiler
  should emit the skeleton.

This document proposes the move that both cures that defect and opens a much
larger door.

= The core inversion: three artifacts, not two

Today the compiler emits two artifacts:

```
page.st  →  spacetime.js    (behaviour, baked)
         →  spacetime.css   (style, baked)
```

The proposal: emit a third artifact that is the page itself, as data.

```
page.st  →  spacetime.js    (behaviour, baked)
         →  spacetime.css   (style, baked)
         →  page.stir       (the page, total self-description)
```

`page.stir` — the _Spacetime Intermediate Representation_ — is everything
the compiler already holds in hand at emit time, serialised:

#table(
  columns: (auto, 1fr),
  inset: 6pt,
  stroke: 0.5pt + gray,
  [*section*], [*contents*],
  [selector tree], [the DOM skeleton the page binds onto — one projection of
    this section replaces every hand-mirrored host skeleton, permanently],
  [signal graph], [names, types, dependency edges (derive/fold), source kinds],
  [receive sums], [every reply discriminator (`"ok" => Bumped(reply: number)`)
    as a schema — the page's wire vocabulary],
  [handlers], [handler bodies as syntax trees, not closures],
  [contract mirror], [the expected contract fingerprint + the page's side of it],
  [fact database], [the `%registers` facts themselves],
)

Nothing here is new information. It is an emit pass over facts that exist.
That is precisely why it is cheap — and why everything it unlocks compounds.

= Four levels of serialisability

Serialising an interface is not one thing. It is a ladder, and `.stir`
climbs it:

/ L1 — snapshot: the current signal values, as JSON. Reconnect reseeds,
  time-travel debugging, server-side rendering seeds. (Half-exists today via
  the `st-set` assign channel.)

/ L2 — structure: the skeleton and selector tree. The LiveView host's
  hand-mirrored markup becomes a projection; a fourth page never grows a
  fourth drifting arm.

/ L3 — behaviour: the page's logic is _declarative_ — signals, receive arms,
  selectors, lowering to primitives with stable names. A small interpreter
  over `.stir` can therefore run a page without the baked bundle. The
  interface becomes something that _travels_: embed a page in a message,
  paste it into a chat, evaluate it in a foreign runtime.

/ L4 — the live process: L1 plus the in-flight coordination state — pending
  reply-policy generations, optimistic snapshots awaiting confirmation. That
  is a serialisable _continuation_. The demonstration: drag a card on the
  desktop board, serialise mid-drag, open the page on a phone, and the drag
  continues. A Smalltalk image — but diff-able, merge-able, versionable data
  instead of a binary blob.

= Projections: an interface spoken by anything

Once the interface is a value, every consumer is a projection of it:

#table(
  columns: (auto, 1fr),
  inset: 6pt,
  stroke: 0.5pt + gray,
  [*target*], [*projection*],
  [DOM bundle], [today's compiler output, unchanged],
  [LiveView host], [the skeleton, emitted — the hand-mirror defect deleted],
  [agent UI (`spell.ui`)], [receive sums → select menus; forms → input
    chains; pushes → notifications],
  [tool server], [every declared event becomes an invocable, typed tool;
    the reply sum is its result schema],
  [docs / gallery], [the self-generating showcase, generalised to any page],
  [terminal / print], [a static render of skeleton + state],
)

The deep consequence: *any Spacetime interface becomes operable by an agent
with zero additional code.* The contract supplies the vocabulary (which
events exist), the IR supplies the grammar (their fields, their reply sums,
the current state). "Any interface is serialisable" and "any interface is
speakable by anything" are the same statement.

= Why the macro system is ready for this

The language's metaprogramming already runs on the required substrate; the
IR makes it visible. Natural successors:

+ *Macros that react to declarations.* `%registers` is a database; let macros
  subscribe to it — a `%on register(binding(...))` trigger that fires when a
  matching declaration lands, emitting derived structure. One typed record
  declaration unfolds into a form, validation, error surfacing, and a typed
  subscription. _The declaration is the app._
+ *Derives.* Rust-style, on any binding:
  `@data inline $doc text derive { serializable, history, crdt } : ""`.
  `history` generates an undo ring; `crdt` generates merge semantics for the
  wire; `serializable` opts the binding into snapshots and continuations.
  Derives are ordinary macros from point 1 — the library grows in `.st`,
  not in the compiler.
+ *Contract-driven codegen.* A page-side macro consumes the contract sidecar:
  the server declares `event :move_card` with fields, and the page's signal
  scaffold, receive sum, and optimistic-handler skeleton are _generated_ —
  typed and contract-clean by construction. The contract stops being only a
  check and becomes a source.
+ *Compile-time evaluation.* Meta-blocks run against the fact database and
  contracts, producing derived facts and authored diagnostics — generalising
  the existing near-miss error-sibling pattern from syntax to semantics.

= Staging

/ W0: Emit `page.stir` + the skeleton projection. Mechanical; deletes the
  hand-mirror defect; unlocks everything above.
/ W1: Contract → page scaffold macros. The boundary generates itself.
/ W2: `%on register` + a derive library (history, serializable, form).
/ W3: The `.stir` interpreter: behaviour-level serialisation, live-session
  capture/resume, agent-UI and tool-server projections.
/ W4: Reflection at runtime — pages that read and patch their own IR, with
  patches as mergeable data. Collaborative live-programming of interfaces.

= The through-line

Spacetime's bridge already believes one thing: _diff data, never templates._
The server never sends markup; only values move. This proposal takes the same
conviction one level up:

#align(center)[
  #text(size: 13pt, weight: "bold")[The template itself is data.]
]

An interface that is data can be stored, diffed, merged, projected,
transported, resumed, and operated — by browsers, servers, terminals, and
agents alike. The compiler already knows the whole page. Let it say so.
