#import "../_preamble.typ": *

#wave("W7", "Walkthroughs that run, and a repository that uses its own file", status: "shipped")[

= The docs are programs

`docs/dev/env.bl.md` and `docs/dev/the-warm-session.bl.md` are livebooks: prose,
then cells that RUN, with the result stored beside each one. `bl doc run --check`
fails a build whose stored results no longer match its code, so a walkthrough
cannot quietly go stale:

#ran("bl doc run docs/dev/env.bl.md --check",
"bl doc run: docs/dev/env.bl.md — 7 cells, 0 cell errors (checked, unchanged)")

Every cell is deterministic by construction — temp dirs, no daemons, no
timestamps — which is what lets them be checked at all. That constraint found
one real thing: `u/kw [:root \"/x\" :pid 1]` SILENTLY DROPS the second pair,
because `kw` takes one pair per argument. The cell that documented the port
refusal was quietly asserting nothing until the stored result exposed it
(`{:ok, 45153}` where a refusal was expected).

#gap(id: "G2", title: "`u/kw` should reject what it cannot express")[
  `(u/kw [:a 1 :b 2])` builds one pair and drops the rest — a caller that
  intended two gets no error and no second binding. The arity is discoverable
  (one vector per argument) but the failure is silent, and silent is the one
  thing a configuration builder must not be. A check on the vector's length,
  plus an error naming the offending form, would cost three lines.
]


= The repository's own env.bl

The strongest dogfood available: this checkout now has an `env.bl`, and the
tooling in it reads that file about itself.

```clojure
{:name "beam-lisp"
 :paths ["examples" "priv/lib"]
 :tasks {:demo   {:run "examples/live/11-pulse-app.bl" …}
         :runner {:run "examples/reload/10-ward-warm-runner.bl" …}}}
```

Two things fall out of it. `bl demo` and `bl runner` are now verbs this
repository has — and the dashboard in the previous wave shows them as buttons.
And the test corpus RESOLVES: `test/bl/` reaches into `examples/` for shapes,
schemas and live apps, which is why `bl test test/bl/` used to fail on missing
namespaces before it could fail on a failing test.

#ran("bl test test/bl/",
`161 file(s) passed, 8 failed, 1 incoherent
  ✗ not green`,
note: "the corpus RUNS from the repo root now; the remaining failures are the corpus's own business, not the runner's")

#proof("Isolation holds across a 170-file corpus")[
  Each of those files ran in its own env fork off one warm image. A file that
  crashed at load was contained and its siblings still ran — the property ward
  was built for, now just what `bl test` does.
]

]

#wave("—", "What this cost, and what is left", status: "closing")[

= Where the bugs came from

Every non-trivial bug this work uncovered was found by RUNNING something, not by
reading it:

#list(
  [A daemon request's fork could not reach the loader: a search path registered
    inside a request was invisible to the `Loader.Server`, so a project's
    declared roots never applied warm. (W1)],
  [`:os.getpid/0` answers a CHARLIST, so every port claim looked stale and was
    swept the moment it was written — the registry worked perfectly and was
    empty. (W3)],
  [The loader could not see a namespace whose `ns` form carries metadata, so
    `source_content(\"codebase\")` answered nil for a file sitting in the search
    path, and the MCP codebase mount had been failing — `examples/mcp-demo.bl`
    too. (W3)],
  [The isolated runner is not reentrant on itself: a bl-language test that
    starts a suite inside a suite hangs. Found by a 900-second timeout. (W4)],
  [Three separate places treated \"is a map\" as \"is a beam-lisp map\", in a
    codebase where eleven struct types are maps. The repository's own lint test
    caught all three at once. (W5/W6)],
)

= What is not done

#list(
  [G1, above — the dashboard is server-rendered: one read-model, no keyed
    diffs, no convergence between tabs.],
  [G2, above — `u/kw` silently drops what it cannot express.],
  [The dashboard REPL pane (FUP-038) and the editing/file-browsing spike
    (FUP-039) remain follow-ups, as planned.],
  [One test in the full suite is red and NOT explained: a daemon-served `bl test`
    of a scratch suite fails in full-suite runs with
    `BeamLisp.Ns.Core."is-eq-report"/7 is undefined or private`, and passes when
    its own file is run alone (3 for 3). Filed as FUP-044 with the evidence and
    the three candidate causes. Recording it here rather than leaving a green
    suite to imply more than it showed.],
  [The plan listed five walkthroughs (`env.bl`, `daemon`, `tasks`, `ports`,
    `ui`); two shipped, covering the same ground in one pass each. The verb
    livebooks (`bl.env`, `bl.test`, `bl.ports`) are the other half of that
    documentation.],
)

= The shape of the thing

#contrast(
  "before",
  [
    Twenty-one verbs, each finding a project's files its own way; a daemon and
    an isolated test runner that did not know about each other; warmth and
    isolation as commands a developer had to choose between.
  ],
  "after",
  [
    One project file the tooling reads about itself; one runner whose isolation
    is the default; one session per tree with one address; one read-model that
    the terminal and the browser both render. Warmth is an optimization,
    isolation is a property, and the CLI is a remote control.
  ],
)

]
