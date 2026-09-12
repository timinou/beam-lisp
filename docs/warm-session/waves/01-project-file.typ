#import "../_preamble.typ": *

#wave("W1", "The project file — env.bl read cold and warm", status: "shipped, 13 tests")[

A tree can now describe itself in one file at its root. The file is beam-lisp,
its last form is a map, and every command reads it before it does anything:

```clojure
{:name  "pulse"
 :paths ["src" "priv"]                  ; library roots — replaces -p flags
 :tasks {:dev  {:run "src/main.bl" :watch true :doc "the dev loop"}
         :seed "scripts/seed.bl"}
 :ports {:web 4000 :metrics {:port 0}}  ; named; 0 = the OS chooses
 :env   {"PULSE_ENV" "dev"}}
```

= The three rules that make it trustworthy

#decision([
  Discovery walks *up* from the command's own directory.
], because: [
  `bl` typed three levels down finds the same file a command at the root finds,
  so no command ever needs a path to its own configuration — direnv's rule, and
  the reason the file belongs to a tree rather than a directory.
])

#decision([
  The file has two readers that cannot disagree: a *data* read (parse the last
  form, evaluate nothing) and a *fork* read (evaluate the file in its own env).
], because: [
  Tooling that must not run project code — the doctor, the language server, an
  editor — still sees exactly what a run sees. A file whose value is computed
  reports `:dynamic` from the cheap read, and the caller falls back to the fork.
])

#decision([
  Every shape problem is collected into `:errors` as data, and the project map
  is always the right shape.
], because: [
  A configuration bug that silently does nothing is the worst kind. A file with
  six mistakes reports six, and the command that read it still runs — with the
  paths, tasks and ports it could understand.

  #ran("bl eval '(... (bl.env/project \"…\"))'  — a deliberately broken env.bl",
    `{:name nil, :paths [], :tasks {}, :ports {}, :env {},
 :errors ("...:paths must be a list of strings"
          "...:name must be a string"
          "task \"a\" must be a file name or a map"
          "port \"w\" must be a number or {:port N}"
          "...:env must be a map of name → string"
          "unknown key wat")}`,
    note: "six problems, one pass, nothing raised, no valid key discarded")
])

= What a command binds

`bl.cli` reads the project once per command, before dispatch, and binds two
things: the declared roots onto the loader's search path, and the declared
environment into the process. Cold and warm both come through this one door.

#proof("A library resolves from a declared root, with no flags")[
  A scratch tree with `env.bl` declaring `:paths ["src"]`, a namespace at
  `src/lib/thing.bl`, and a program requiring it. Run from a directory three
  levels below the root:

  #ran("mix bl run ../../src/app.bl   (from <tree>/sub/dir)",
    `hi from lib, mode=engaged`,
    note: "the root came from env.bl; the mode came from :env — neither from a flag")
]

#proof("The same tree through the daemon")[
  `test/beam_lisp/daemon_env_test.exs` boots a real daemon for this repository
  and sends protocol requests whose CLIENTS sit in a scratch tree — including
  from a subdirectory. Both assertions are about the client's project, not the
  daemon's checkout:

  #ran("mix test test/beam_lisp/daemon_env_test.exs",
    `02 tests, 0 failures · the daemon bound the CLIENT's env.bl`)
]

= The bug this wave uncovered

The daemon binds a request's roots through `Loader.with_ambient_dirs/2` — the
client's cwd plus its `-p` paths — because the daemon VM's own cwd is the
checkout, not the client's tree. That binding *replaced* the standalone capture
`[File.cwd!() | extra_dirs()]`, and `extra_dirs()` is where a session's
configured search paths live. A search path added inside a daemon request —
which is exactly what a project's `:paths` are — was therefore invisible to the
load: `add_search_path` writes into the request's *fork*, while the
`Loader.Server` that loads namespaces reads its own env's paths.

#decision([
  The capture is now additive: the caller's bound roots *plus* its configured
  search paths, in either mode.
], because: [
  One expression, both hosts. The alternative — teaching the daemon's Elixir
  side to compute project roots itself — would have put the same logic in two
  places and let the two hosts drift, which is precisely what the whole design
  forbids.
], instead: [
  making the Elixir executor read `env.bl` and append paths to
  `ambient_dirs/1` (a second implementation of "which roots apply").
])

#law("the fork is not a sound barrier")[
  Configuration a request binds for itself must reach the component that acts on
  it, even when that component runs in another process on a different env. A
  search path is session configuration, not process state.
]

= Numbers, and how they were checked

#measure("new namespace", "priv/std/bl/env.bl.md — bl.env (~250 lines, livebook)",
  note: "find · literal · evaluate · normalize · project")

#measure("tests", "11 tests · 33 assertions (test/bl/system/env_test.bl)",
  note: "discovery at depth · both reads · fork isolation · shape errors · normalization · cold binding · a broken file that still runs")

#measure("warm-path test", "2 ExUnit cases (test/beam_lisp/daemon_env_test.exs)",
  note: "a real daemon, real protocol frames, the client's tree")

#measure("neighbouring suites", "38 ExUnit (daemon) · 334 bl tests (system)",
  note: "re-run after the loader change; 0 failures")

#dogfooded[
  Every test in this wave was run through the warm runner under construction —
  `bl test …` — not only through `mix test`, and the daemon cases drive the same
  `run-argv` entry a `bl` invocation uses. The next wave wires the daemon's own
  task and port surface; the report will show those running through the session
  they describe.
]

]
