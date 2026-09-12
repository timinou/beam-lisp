#import "_preamble.typ": *

#session-doc(
  title: "The Warm Session",
  subtitle: [
    A project file that is a value; a daemon that is the project as a process;
    a CLI that is nothing but a remote control for it.
  ],
  kicker: "beam-lisp · PLAN-103 · implementation report",
  dateline: [begun 2026-09-11 · this revision #datetime.today().display("[year]-[month]-[day]")],
  standfirst: [
    Two mechanisms for running a project's code already existed — a warm daemon
    and an isolated test runner — and they did not know about each other. This
    report follows the work that makes them one thing: *the warm session*. Each
    wave below states what changed, the decision behind it, and the evidence
    that it works, taken from the session in which it was built.
  ],
)[

= What this is

beam-lisp's `bl` CLI grew organically: twenty-one verbs, each its own namespace,
each learning how to find a project's files on its own. Alongside them, a daemon
learned how to keep a VM warm for a tree, and a test runner (`ward`) learned how
to run a file in an isolated fork. Warmth and isolation were *commands*.

This work makes them *properties of execution*. The surface that results:

#block(width: 100%, fill: wash, inset: 0.9em, radius: 2pt, above: 1em, below: 1.2em)[
  #set text(9.8pt)
  #grid(
    columns: (auto, 1fr), column-gutter: 1em, row-gutter: 0.45em,
    text(font: mono, "bl daemon start"), [the one lifecycle noun — a warm session for this tree],
    text(font: mono, "env.bl"), [the project as a value: roots, tasks, ports, environment],
    text(font: mono, "bl <task>"), [a task the project declares, running against the warm image],
    text(font: mono, "bl test"), [isolated per file, always — `ward`'s semantics, no second runner],
    text(font: mono, "bl ui"), [the session's dashboard: the same read-model the terminal shows],
    text(font: mono, "bl mcp"), [the same capabilities, for editors and agents],
  )
]

= The laws this work establishes

#law("one meaning, two hosts")[
  A command behaves identically cold (a standalone VM) and warm (through the
  daemon). Warmth is an optimization, never a difference in meaning: both hosts
  call the same entry point, and every wave is verified against both.
]

#law("errors are values")[
  A wrong key in a project file, a malformed file, a tree with no project file —
  each degrades what a tree can do and is reported as data. None of them stops a
  command, and none of them stops the daemon.
]

#law("one implementation per need")[
  Nothing in this work exists twice. The project file has one reader; the test
  semantics have one runner reachable cold and warm; the dashboard is a pure
  view over one read-model, and the terminal is another view of the same one.
]

= How to read the evidence

Three kinds of block carry the argument:

- #term("decision") — a choice and the reason for it. If you disagree with a
  choice, the reason is what to attack.
- #term("proof") — something observed in this session, with the command that
  observed it. The transcripts are real output, not illustrations.
- #term("dogfooded") — how the new tooling was used to check the new tooling.

Anything not yet true is in a #term("gap") block, marked as such.

= The waves

Each wave ships on its own and is verified before the next begins.

#grid(
  columns: (auto, 1fr, auto), column-gutter: 0.9em, row-gutter: 0.35em,
  align: (left + horizon, left + horizon, right + horizon),
  inset: (y: 0.25em),
  text(weight: 600, font: sans, "W1"), [The project file — `env.bl` read cold and warm], text(fill: ink-faint, font: sans, "shipped"),
  text(weight: 600, font: sans, "W2"), [Tasks — `bl <name>` as a declaration], text(fill: ink-faint, font: sans, "shipped"),
  text(weight: 600, font: sans, "W3"), [The session's address — named ports, one URL, MCP on it], text(fill: ink-faint, font: sans, "shipped"),
  text(weight: 600, font: sans, "W4"), [`bl test` absorbs `ward`], text(fill: ink-faint, font: sans, "planned"),
  text(weight: 600, font: sans, "W5"), [One read-model, two faces], text(fill: ink-faint, font: sans, "shipped"),
  text(weight: 600, font: sans, "W6"), [`bl ui` — the dashboard, and MCP over HTTP], text(fill: ink-faint, font: sans, "shipped"),
  text(weight: 600, font: sans, "W7"), [Walkthroughs that run, and a repo that reads its own file], text(fill: ink-faint, font: sans, "shipped"),
)

#pagebreak()

#include "waves/01-project-file.typ"
#include "waves/03-the-sessions-address.typ"
#include "waves/04-tasks-and-one-runner.typ"
#include "waves/07-docs-and-dogfood.typ"

]
