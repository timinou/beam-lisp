#import "../_preamble.typ": *

#wave("W2 · W4", "Tasks, and one runner instead of two", status: "shipped")[

= The project declares its verbs

`env.bl` names the things a developer types. `bl tasks` lists them; `bl dev`
runs one; the dashboard offers them as buttons. Dispatch is a FALLTHROUGH —
builtins first, the project's tasks after — so `bl test` keeps meaning `bl test`
whatever a file declares. A task that DOES collide is dropped and reported
rather than silently losing:

#ran("bl tasks   (this repository's own env.bl)",
"  demo    — the Pulse walkthrough: one app, backend and frontend
      /home/user/code/undefine/beam-lisp/examples/live/11-pulse-app.bl
  runner  — the isolated test runner, running four adversarial files
      /home/user/code/undefine/beam-lisp/examples/reload/10-ward-warm-runner.bl")

#decision([
  A task is a saved INVOCATION, not a second execution model: it runs its file
  the way `bl run FILE` does, through the CLI's own path — the daemon's intent
  endpoint calls exactly that, so there is no second implementation of "run a
  task".
], because: [
  Every extra implementation is a place for the two to disagree, and a task that
  behaves differently warm and cold is a bug nobody would think to look for.
])

= ward's interface, without ward

`bl ward` is gone. Its semantics are what `bl test` IS: each file in its own env
fork off one warm image, coherence-checked, contained — a file that explodes at
load cannot take the run down, and one file's world is invisible to the next.

#ran("bl test test/bl/system/tasks_test.bl",
`── ward: warm isolated test run ──

  ✓ system.tasks-test  8 passed

  1 file(s) passed, 0 failed, 0 incoherent
  ✓ all green`)

#decision([
  `bl ward` answers with ONE line pointing at `bl test` and exits 2.
], instead: [
  an alias, which would keep two names alive for one thing — the shape this
  work exists to remove,
], because: [
  the migration note costs a line and the alias costs a permanent second word.

  #ran("bl ward x.bl",
  "bl: ward is now `bl test` — every file in its own isolated fork is the default (--shared opts out)")
])

#law("one runner, two escapes")[
  `--shared` runs every file in one image (the old behavior, for a suite that
  genuinely needs a shared world) and `--async` selects the concurrent runner.
  Both are documented where the command is; neither is the default, because
  neither is what a test wants.
]

#proof("The retired verb left the command table")[
  `test/bl/system/test_verb_test.bl` asserts `commands` has `test` and has no
  `ward`, and that the help text names `--shared`. The runner's own shapes are
  exercised in `test/beam_lisp/test_verb_test.exs`, seven cases: a green suite,
  a failing one with the why, a load crash contained beside a passing sibling,
  two files that cannot see each other's world, `--shared`, `--json`, and the
  same suite served warm through the daemon.

  That split is not tidiness: **the isolated runner is not reentrant on itself**.
  A bl-language test file may not start a suite inside a suite — the first
  version of this test did, and hung until the timeout — so the runner's own
  tests live where no outer ward is running.
]

]

#wave("W5 · W6", "One read-model, and the dashboard that renders it", status: "shipped")[

`bl daemon status` and the session page are two RENDERINGS of one value built by
`BeamLisp.Daemon.Inspect`:

#ran("bl daemon status",
"bl daemon
  tree          beam-lisp  (/home/user/code/undefine/beam-lisp)
  pid           2252356
  tree_id       57461829a20cc2af
  uptime_ms     33000
  port          ui = 35969  (beam-lisp, pid 2252356)
  ui            http://127.0.0.1:35969/
  mcp           http://127.0.0.1:35969/mcp  (the same MCP `bl mcp` serves over stdio)
  tasks         demo · runner
  queue_depth   0")

The model answers, in one value: identity (tree, pid, age, compiler key), ports
(every live claim), tasks (what the project declares), queue (is the session
busy), and — when the language side has it loaded — the reload image.

#decision([
  The model lives in Elixir (`BeamLisp.Daemon.Inspect`), not in a `bl.daemon.inspect`
  namespace as the plan sketched.
], because: [
  its sources are Elixir-side (ports, the worker queue, the listeners); the one
  language-side source, `reload/inspect`, is reached through the runtime. A bl
  namespace would have had to reach the other way, through four bridges, to say
  less.
])

#proof("A test compares the two faces rather than trusting them")[
  `test/beam_lisp/daemon_inspect_test.exs` builds the model once and asserts both
  renderings against it: every live port appears in the text AND in the JSON with
  the same number, the session URL and its `/mcp` line reach both, and the JSON
  is JSON-safe (string keys, no structs). A field that reached one face and not
  the other fails there rather than in a browser.
]

= The dashboard

#figure(
  image("../img/dashboard.png", width: 100%),
  caption: [The session page for this checkout: tasks with run buttons, the port table, the reload image (not loaded here — and the page says so), the worker, and the transports.],
)

Clicking `run` is an INTENT: `POST /intent` names a task, the daemon runs it on
its single worker — the same FIFO every client's command takes, so an intent
never races a reload or a run — and the output comes back into the page.

#figure(
  image("../img/dashboard-intent.png", width: 100%),
  caption: [The `runner` task, run from the page: the isolated runner's own report, exit 0, inline. The failure it reports is the `print_str` fix from the first wave — an error value printed as a value instead of crashing the printer.],
)

#decision([
  The write path requires the daemon's own token in `x-bl-token`, and the page
  carries it (server-rendered).
], because: [
  the listener is loopback-only, and loopback is not a trust boundary: any page
  a developer visits can `POST` to `127.0.0.1`, and running a project's tasks on
  someone else's say-so is exactly the hole this face must not open. A
  cross-origin caller cannot read the token (no CORS) and cannot send a custom
  header without a preflight this server never approves. `test/beam_lisp/daemon_ports_test.exs`
  asserts the refusal.
])

#gap(id: "G1", title: "The dashboard is server-rendered, not diff-live")[
  The plan promised a pulse-architecture client: a datom read-model, a pure view
  over it, minimal keyed patches, several viewers converging through the log.
  What shipped is the honest 80%: one read-model, server-rendered, with intents
  on the worker and a token guard. What is missing is the CLIENT half — no
  socket, no keyed diffs, no convergence between tabs.

  The read-model is the part that had to be right, and it is: `GET /model` is the
  same value the page renders, so a live client is an addition rather than a
  rewrite. The dashboard REPL pane (FUP-038) waits on the same socket.
]


#dogfooded[
  Every screenshot in this report is a daemon for THIS checkout, and the tasks in
  it are this repository's own `env.bl`. The `runner` task's output in the second
  shot is the ward example exercising the isolated runner — the same tool the
  test suites in these waves were verified with.
]

]
