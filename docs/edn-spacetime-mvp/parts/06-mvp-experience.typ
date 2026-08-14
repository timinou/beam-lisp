#import "../_preamble.typ": *

= The MVP experience

What it should feel like, as four walkthroughs. Each names the machinery that
makes it true, so experience claims stay falsifiable.

#xp(1, "Start a session with a long-form mission")[
  The user opens the session URL (or runs `mix beam_lisp.run spell/src/main.bl
  -- --session my-mission`, which boots `spacetime live my-mission` and opens
  the browser). The first thing on screen is not a prompt box — it is the
  #emph[mission composer]: a full-width, long-form Markdown-ish writing
  surface. Titles, sections, lists, code fences. Submitting writes
  `:mission` into the session value, gates, and mounts the shell.

  Machinery: composer = kit `form.st` with one markdown field (IMP-A4,
  IMP-N3); submission routed `:to :agent+log` (IMP-N2) so the act of
  starting the mission is itself the first log entry.
]

#xp(2, "The interface is a mission, not a chat")[
  The layout reads top-to-bottom as a document of intent:

  + #strong[Mission hero] — the statement, typeset large, collapsible to a
    title bar once turns begin.
  + #strong[Attachment timeline] — follow-ups the user adds later appear
    beneath the mission as a vertical timeline of attachments: small, dated,
    each one a trigger for a subsequent turn. Writing a follow-up uses the
    same composer, docked at the timeline's tail.
  + #strong[Turns] — below the timeline, one block per turn. A running turn
    shows its live status; the deeper log (tool calls, gate verdicts, button
    events) is one click away per turn, rendered by the log stream component
    (IMP-N4) — present, inspectable, never shouting.

  Machinery: one `spell/shell` function (§5.2); timeline append animated with
  `@flip`; open/collapse state is shell-local signals, so a page reload
  re-renders truth from the session value without replaying UI trivia.
]

#xp(3, "The turn ends with a big output — sometimes interactive")[
  When the agent finishes, the turn flips to `:done` and its output renders
  #emph[big]: the hero of the turn block, markdown-typeset. When the agent
  needs the user — a choice between alternatives, a confirmation, a small
  form — the output is a form collection rendered in place (§5.3): picker
  cards with pros/cons, a confirm bar, or a field set with a submit button.

  In the MVP the agent declares these forms as part of its output EDN; the
  beam-lisp process mounts them and the user's submission is waiting in the
  event history when the next turn begins. Fast-follow tightens this to
  intra-turn (`st_await` mid-turn) and adds async buttons that write straight
  into the log stream as they are clicked (`:to :log`), so the user can poke
  at an output — expand a diff, re-run a check, pin an alternative — without
  involving the agent at all.

  Machinery: kit picker/confirm/form (IMP-A4); dual-destination routing
  (IMP-N2); automatic surfacing of submissions into the Spell session
  (IMP-A3).
]

#xp(4, "The sidecar keeps the whole thing")[
  Close the laptop. Kill the agent. Restart the beam-lisp process. Reopen the
  browser: the mission, timeline, turns, outputs, and log are all there,
  because they live in the named sidecar session (snapshotted on every
  mutation, IMP-N1) and in `spell.store`'s durable tier — not in any client.
  The agent reattaches with its own cursor and sees exactly the submissions
  it missed.

  Machinery: `spacetime live <session>` persistence and multi-attach (IMP-N1);
  notification cursors (IMP-A3); ontology held as one EDN value (§5.1).
]

#invariant[
  Experience invariant: at every moment, everything on screen is a pure
  projection of (session value) + (shell-local UI signals). There is no third
  source of truth to lose, drift, or contradict the gate.
]
