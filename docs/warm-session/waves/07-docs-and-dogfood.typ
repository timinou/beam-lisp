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


= What the docs' gate could not see

Both walkthroughs checked green while one of them showed the WRONG OUTPUT for
every cell after its fifth. The stored results had been attached to their
neighbours — `unknown-key` displaying `[]`, `literal` displaying
`("unknown key wat")`, and so on down the file — and `--check` reported
`0 cell errors`.

The cause is the id a cell gets. A markdown fence carries its attributes as
TOKENS (```` ```beam-lisp id=ports-list silent ````), not as a map: the
`{:id "…"}` I had written was ignored, so each cell was auto-named `cellN` by
position, or after its own first `def`. A cell's name and its result's name
therefore move TOGETHER when a cell is inserted or removed — the pair stays
self-consistent, the text compares equal, and the gate blesses a document that
misreports its own output.

#decision([
  Every cell names itself (`id=NAME`), results follow those names, and the
  world-dependent cells stop storing world-dependent values.
], because: [
  a check that compares text cannot see a mis-attachment when both sides derive
  from the same position. Explicit ids are what make a stored result belong to
  a cell rather than to a slot.

  The two fragile cells were fixed by construction rather than by refreshing
  them harder: the registry cell proves the claim → list → release contract on
  a name of its own (so the answer is `(true false)` whoever else is running),
  and the `ports/url` cell is `silent` — it answers nil or an ephemeral URL
  depending on the moment, so any stored result would go stale for a legitimate
  reason. Silent cells still RUN, so a broken `ports/url` still fails the check.

  #ran("mix bl doc run docs/dev/env.bl.md --check",
  "7 cells, 0 cell errors (checked, unchanged)")

  An orphan `bl-result cell5` from an earlier revision went too: the writer
  rewrites the ids it is handed and cannot remove a span whose cell is gone.
])

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
  [A test that looked its session up by NAME. A port claim's file is named by
    the name alone, so `:ui` is global to the user: another tree's session (or a
    parallel test run) can hold it, and the lookup answers with ITS port. The
    test was green until the day two sessions ran at once. Fixed by asking for
    the claim whose root is this tree — and by dropping an
    `assert port_of(:ui) == port_of(:ui)` that tested nothing at all. (W3)],
  [The daemon, dead from a one-line stray edit in the file of the session
    working beside this one: `owns-process?` had acquired a fragment above its
    `let` referencing `cmd` before it was bound, and the daemon asks that
    function about EVERY request, so nothing ran at all. Repaired to the intent
    plainly there (`gateway` owns its process, like `repl`/`serve`/`mcp`).
    (shared tree)],
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

#gap(id: "G3", title: "one mid-write source file stops every command")[
  A `bl` command cannot run while ANY source file in the tree is malformed or
  half-written — `mix bl version` included, and the daemon too. The chain, read
  from the source rather than guessed: `app.start` runs the project's compilers;
  `Mix.Tasks.Compile.BeamLisp` calls `build/run`; that driver records a file it
  cannot READ as an error rather than skipping it; a non-empty error list makes
  the compiler fail, so `bl.cli/run-argv` is never reached. The output names the
  offending file but never says the command did not run — it reads like the
  command failed.

  This is the same law this report established for `env.bl` — *a broken file
  degrades, never stops a command* — violated one layer down, where it costs
  more, because it takes the warm session's own daemon with it. Observed live
  while a second session was editing this repository (13 unreadable sources).

  Filing it rather than patching it: the honest fix narrows what the Mix
  compiler treats as fatal (an ordinary source that cannot be read should be
  skipped, and its dependents fail on their `require` — which is what the build
  driver already does and what its own comment argues for), and that is a change
  to global build semantics and CI gates. FUP-050 carries the mechanism, the
  reproduction and the options.
]

= The red test that turned out to be a bug

One case kept failing only inside the full suite — a `bl test` run inside a
long-running VM — while passing four times out of four on its own. Passing
standalone is not evidence of correct; it is evidence that the trigger lay
elsewhere.

Printing the state AT THE FAILURE SITE, instead of guessing at suite order, gave
the answer in one run:

#ran("the diagnostic, printed by the failing case in a real suite run",
"DIAG exit=1  is-report/4=false  guard=true  beam=.../ebin/Elixir.BeamLisp.Ns.Core.beam")

The assertion runtime was MISSING FROM THE COMPILED CORE MODULE while the check
that guards it said everything was fine. `ward`'s `deftest-available?` asked only
whether `deftest` resolves in core's ENV — but a compiled test file does not call
an env var: `is` expands into a call to `BeamLisp.Ns.Core."is-report"/4`, and
`deftest` into `test-record/6`. Those live in the MODULE, and a later reload of
`core` puts the module back from its beam (which carries `core.bl` alone — the
test library is not in it) while core's env keeps the macro's home. The guard
said "available", `ensure-test-lib!` skipped the load, and every file in the run
died on a function the guard had just certified.

#decision([
  The guard now requires the env AND the compiled module
  (`assertion-runtime-loaded?` — `function_exported/3` for `is-report/4` and
  `test-record/6`).
], because: [
  the env is where the macro LIVES; the module is what a compiled file CALLS. A
  check that sees only one of them certifies a library that cannot run.

  Reproduced deterministically — purge core, load it back from its beam, run
  `bl test` in-VM — and that reproduction is now a regression test rather than a
  suite-order mystery:

  #ran("mix test test/beam_lisp/test_verb_test.exs",
  "8 passed",
  note: "including `a test library that vanished from core's MODULE is re-loaded`")

  The suite went from 1535–1541 of 1541 (this class failing intermittently) to
  *1542 passed, 0 failures* — and faster, 234s against 421s, because every file
  had been paying for a library that was never loaded.
])

= What is not done



#list(
  [G1, above — the dashboard is server-rendered: one read-model, no keyed
    diffs, no convergence between tabs.],
  [G2, above — `u/kw` silently drops what it cannot express.],
  [G3, above — one mid-write source file stops every `bl` command, the daemon
    included. FUP-050 has the mechanism and the reproduction.],
  [The dashboard REPL pane (FUP-038) and the editing/file-browsing spike
    (FUP-039) remain follow-ups, as planned.],
  [The plan listed five walkthroughs (`env.bl`, `daemon`, `tasks`, `ports`,
    `ui`); two shipped, covering the same ground in one pass each. The verb
    livebooks (`bl.env`, `bl.test`, `bl.ports`) are the other half of that
    documentation.],
)

= The red corpus, attributed

The corpus (`bl test test/bl/`) is red as this report is written, and the
attribution matters more than the count. Of 168 files: 156 pass, 4 fail, 12 are
incoherent — and every one of those is a symptom of the *other* session editing
this same checkout at the same time. The AOT loader names the cause itself, one
line per file:

#ran("mix bl test test/bl/", "156 passed, 4 failed, 12 incoherent  (one run; the counts move with their edits)")

#list(
  [The failures are theirs, by their assertions: `build.test` / `poisoned-manifest-is-ignored` (`b/read-manifest` → `%ArgumentError{}`), `datom.blanalysis-cache.test` / `hit-returns-identical-answers`, `live.session.test` / `session-conn-dies-with-owner` (`ets/info tbl :owner` → `:undefined`), `ns-interface.test` / `real-prelude-body-edit-rebuilds-one` (a `Reader.SyntaxError` — reading a file mid-write).],
  [The 12 incoherent files are theirs, by their own message: `⊘ INCOHERENT — test file declares no (ns …) form` — new test files being written right now (`z3_concurrent_test.bl`, `mcp_z3_port_test.bl`, `daemon_names_test.exs`).],
  [Not one failure text mentions this work's surfaces, and the suites that exercise them are green *through* the breakage — which is the useful half of the observation.],
)

That last point is the one worth keeping: the warm runner stayed green for this
work while the tree around it was broken, because a verb loads by name and the
broken files were in namespaces this work does not touch.

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
