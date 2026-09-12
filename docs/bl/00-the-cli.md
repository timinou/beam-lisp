# bl — the command

`bl` is the one interface to beam-lisp. It runs a program, evaluates an
expression, opens a session, runs the tests, measures the source, proves what it
can, serves the language and the codebase to editors and agents, builds,
documents, and ships.

Inside a checkout you run it as `mix bl`. The distributable drop is a single
binary called `bl`:

```sh
mix bl run examples/hello.bl     # in a checkout
bl run examples/hello.bl         # the drop, anywhere
```

Both forms take the same arguments and give the same output — `mix bl` is a
shim that calls the same entry point the drop's launcher calls.

Every command answers with an exit code:

| code | meaning |
|---|---|
| `0` | ok |
| `1` | a runtime failure — a diagnostic, a regression, a failing test, a stale doc |
| `2` | a usage error — an unknown flag, a missing argument |
| `141` | the reader on the other end of stdout went away (`bl examples | head`) |

Run `bl help` for the verb list, or `bl help COMMAND` for one line about a verb.

Diagnostics are written to **stderr**; stdout carries only a command's data. That
is what makes `--json` pipeable — one JSON object, nothing else. It is also why
`bl help | head` ends as a plain `141` instead of an `error:` report about the
pipe the caller closed: a command that loses its reader stops, and stops
without pretending something went wrong.

## The warm daemon

The drop's launcher first looks for a **warm `bl daemon` for the caller's tree**
and forwards the command to it over a Unix socket. A served command returns in
tens of milliseconds instead of the ~1s a cold VM boot costs. When no daemon is
up, the launcher cold-boots the release and runs the command there — same
result, just slower.

```
BL_DAEMON=off    every command cold-boots; no daemon is consulted
BL_DAEMON=auto   a missing daemon is started detached, then the command is retried once
```

`bl daemon start`, `stop` and `status` are the lifecycle — see
[03-the-live-loop.md](03-the-live-loop.md).

## Commands

### run · eval · repl

#### `bl run FILE|- [-- args...]`

Run a program. The last value is printed. `-` reads the program from standard
input. Arguments after `--` reach the program through `BeamLisp/argv`.

```sh
$ bl run hello.bl
hello from beam-lisp
42
```

```sh
$ printf '(println "from stdin")\n(+ 20 22)\n' | bl run -
from stdin
42
```

Exit `0` when the program returns, `1` when it raises.

#### `bl eval EXPR|-`

Evaluate one expression and print its value. Positional arguments are joined
with spaces, so a shell-split expression still arrives whole.

```sh
$ bl eval '(+ 1 2)'
3
$ bl eval '(map inc [1 2 3])'
(2 3 4)
```

`--json` is not offered here; the value is printed.

#### `bl repl`

An interactive session, and the default when `bl` is given no command. A form
may span lines — the prompt continues while a form is open. The last three
results stay reachable: `*1` is the last value, `*2` the one before it, `*e` the
last error.

```sh
$ bl repl
beam-lisp on the BEAM — Ctrl+D to exit
user=> (+ 1 2)
3
user=> (* *1 10)
30
user=> (map (fn [x] (* x x))
     [1 2 3])
(1 4 9)
user=>
```

### test · examples · ward · check · lint · fix · ask

#### `bl test [PATH...] [--async] [--json]`

Run `.bl` tests. With no PATH it runs `test/`. `--async` runs files
concurrently, one environment per file.

```sh
$ bl test
Testing hello-test

Ran 1 tests containing 2 assertions.
0 failures, 0 errors.
```

Exit `0` when nothing failed, `1` when a test failed or errored.

`--json` keys: `tests`, `pass`, `fail`, `error`, `files`.

A test file that requires a namespace outside the library tiers needs that root
on the search path — `bl test test/bl/datom/shape_test.bl -p examples`, because
`semantic.shape` is an example. The file's own `Run:` line names the flags it
needs.

#### `bl examples [GLOB...] [--json]`

Run the example programs, each in its own ward fork: isolated from its
siblings, under a deadline, and skipped (not failed) when an optional
dependency this host lacks is missing. With no GLOB it runs `examples/**/*.bl`.

```sh
$ bl examples examples/hello.bl
…
  ✓ examples/hello.bl

  1 passed, 0 skipped, 0 failed
  ✓ all green (skips are not failures)
```

Exit `0` when nothing failed, `1` when an example failed, `2` when no glob
matched.

`--json` keys: `files` (`path`, `status`), `passed`, `skipped`, `failed`, `ok`.

#### `bl ward FILE...`

Run files in isolated, coherence-gated forks. Each file must declare a
namespace; a file whose definitions do not cohere is reported as incoherent
rather than run.

```sh
$ bl ward ns_hello.bl
ward fork ran

Testing ns-hello
── ward: warm isolated test run ──

  ✓ ns-hello  0 passed

  1 file(s) passed, 0 failed, 0 incoherent
  ✓ all green
```

Exit `0` when every file passed, `1` otherwise.

#### `bl check [PATH...] [--changed] [--update] [--fix] [--json] [--install-hook]`

The gate. Measure every source with the compiler's own analyses, compare
against the committed baseline `.bl-check.edn`, and fail when anything got
worse. With no PATH it checks `.`; `_build`, `deps`, `research`, `.git` and
`test/fixtures` are skipped.

```sh
$ bl check
src/ledger.bl  diags=0 smells=0 fns=9 pure=8 eligible=8
no baseline: run bl check --update to create .bl-check.edn
ok
```

`--update` records the current state as the baseline; `--changed` measures only
sources whose content moved since the baseline was written; `--fix` applies the
safe rewrites first; `--install-hook` writes `.git/hooks/pre-commit`.

Exit `0` when nothing regressed (and when no baseline exists — the first run is
a measurement, not a verdict), `1` on a regression — or when `--install-hook`
finds a foreign pre-commit hook it refuses to overwrite — `2` on a usage error.

`--json` keys: `files` (per file: `path`, `sha`, `diagnostics`, `smells`,
`fns`, `pure`, `terminates`, `eligible`, `unreadable`, `pure-fns`,
`terminates-fns`, `eligible-fns`, `fn-info`), `metrics` (the aggregate),
`ok`, `regressions`; `note` when there is no baseline, `updated` after
`--update`.

#### `bl lint [PATH...] [--tier safe|idiomatic|every] [--json]`

Report the `deodorant` smells — spellings the language already has a shorter
word for. With no PATH it lints `src/`. `--tier` picks the rule set: `safe`
(value-identical), `idiomatic` (the default, safe + idiomatic), `every` (the
reinvention rules too).

```sh
$ bl lint
src/demo.bl:4  if→if-not [safe]
    (if (not (< n 0)) true false)
  → (if-not (< n 0) true false)
…
4 smells in 2 files
```

A smell carries either a fix or a **note**. Advisory rules describe a shape
whose correction is a restructure rather than a local rewrite, so they print
what to change and offer no `after` text:

```sh
$ bl lint src/ledger.bl
src/ledger.bl:12  datalog/nested-scan [idiomatic]
  note: A nested :not/:not-join/:or/:or-join sub-query re-runs per outer row, so
        a clause that binds a VALUE over an unindexed attribute re-reads that
        whole column once per row. Fix: index the attribute (:db/index true, or
        :db/unique) so AVET exists, or build the sub-query's answer ONCE
        outside the loop (a set / memo / index! step). A :db.type/ref
        attribute, and any indexed or unique one, already prefix-scans — when
        the schema is not in this file, confirm with `datom/explain` against
        the live conn.
1 smell in 1 file
```

Exit `0` when clean, `1` when any smell is reported, `2` on a usage error.

`--json` keys: `files` (per file: `path`, `smells` — each `name`, `tier`,
`line`, `before`, `after`, `note`), `total`.

#### `bl fix [PATH...] [--tier safe|idiomatic|every]`

Apply the safe rewrites in place. Trivia-preserving: only the tokens a rule
spells change, so the diff shows the shortcuts and nothing else. Only plain
`.bl` sources are rewritten; a literate `.bl.md` / `.bl.org` document is
skipped (the fixer works on whole file text). Standard input is refused.

```sh
$ bl fix
fixed src/demo.bl (1)
1 file changed, 0 literate files skipped
```

Exit `0` when the sweep completed, `1` when a file could not be read, `2` on a
usage error.

`--json` keys: `files` (`path`, `changed`, `applied`), `changed`, `skipped`,
`failed`.

#### `bl ask QUESTION [TARGET] [PATH...] [--json]`

Answer a named question about a body of code. With no PATH it reads `src/`.
A question that names one function takes a TARGET next.

| question | target | answers |
|---|---|---|
| `impact` | fn | every fn that transitively calls TARGET — what breaks if it changes |
| `callers` | fn | direct callers of TARGET, each with its call line |
| `reachable` | fn | every fn TARGET transitively calls |
| `returns-type` | type tag | fns whose return may include the tag (e.g. `string`) |
| `arity-mismatches` | — | calls whose callee is defined but never at the called arity |
| `unknown-callees` | — | calls to names never defined, not core, not interop |
| `dead-code` | — | fns unreachable from a file's own top-level entry points |
| `symbols` | — | every definition with its proven summary: returns, purity, termination |

```sh
$ bl ask callers fee src/ledger.bl
callers fee
charged?	15
receipt	19
total	12
```

Rows are tab-separated. Exit `0` for any valid question, even one with no rows;
`2` for a bad invocation.

`--json` keys: `question`, `target`, `rows`, `count`.

### build

#### `bl build PATH... [--out DIR] [--force] [--jobs N] [--native]`

AOT-compile namespaces to `.beam` files. Sources compile in dependency order,
in parallel waves; a manifest in the output directory keys freshness, so a
second run is a no-op and a body edit rebuilds one file. `--force` rebuilds
everything, `--jobs N` sets the parallel width, `--native` also emits native
modules. `--out` defaults to `build`.

```sh
$ bl build src --out build
beam-lisp AOT: building 2 source(s)
  …/src/math.bl
  …/src/demo.bl
$ bl build src --out build
beam-lisp AOT: up to date
```

Exit `0` when every source built, `1` when any failed, `2` on a usage error.

### watch · monitor · serve · daemon

#### `bl watch FILE|DIR`

Watch a file or directory and reload it on save. The watcher stages each save,
runs the coherence check, commits, and prints one line per commit.

```sh
$ bl watch src
bl watch: watching src — Ctrl+C to stop
```

It runs until interrupted. Live reload needs the `:file_system` application,
which the release ships. The path is the directory to watch (a file's directory
when FILE is given), resolved against the current directory.

#### `bl monitor DIR`

The same watcher, painted instead of logged: clear the screen and re-render the
live image after every commit — the namespaces in the running system, their
vars, and the reload journal.

```sh
$ bl monitor src
beam-lisp reload monitor — watching /…/src  (Ctrl-C to stop)

── live image  [· empty] ──

  namespaces (3):
    anf  (42 vars)
    …
```

It parks until interrupted, and returns `1` when the watcher cannot start.

#### `bl serve FILE [--port N]`

Run a program, then park the VM so the server it started keeps answering until
Ctrl+C. The file stays an ordinary program: it starts its server and returns; the
parking lives here. Post-`--` arguments reach the program as `bl run` delivers
them.

```sh
$ bl serve server.bl
Running … with Bandit 1.12.4 at 0.0.0.0:4043 (http)
bl serve: server.bl running — Ctrl+C to stop
```

`--port N` moves the port through one cooperative call: write
`(bl.serve/port 4043)` where the literal port would go, and the flag makes that
call answer `N`:

```clojure
(ns mini-server
  (:require [web]))

(defn router [_conn]
  {:status 200 :body "hello from bl serve"})

(web/serve {:port (bl.serve/port 4043) :plug router})
```

Exit `1` when the program raises, `2` when no FILE is given. The web layer needs
`bandit`, which the release ships.

#### `bl daemon start|stop|status`

The warm-VM dev loop, one daemon per tree. `start` becomes the daemon (it
blocks; the drop's launcher runs it detached); `stop` drains and exits; `status`
reports a running daemon or says none is running.

```sh
$ bl daemon status
bl daemon
  pid           1812553
  tree          57461829a20cc2af
  compiler_key  3ac9ac2ebd0b84e00a2b27f98efd9e0c15834b2348d3ee9522781918bd709ec6
  build_id      2026.0.0
  uptime_ms     706826
  queue_depth   0
```

`status` exits `0` when a daemon answers, `1` when none is running.

### doc

#### `bl doc run FILE... [--check]`

Run a livebook's cells in order, in one namespace, and write each result back
into the file as an owned result span. Prose and cells are preserved
byte-for-byte. `--check` writes nothing and fails when the stored results are
stale — the CI gate that keeps a document's narrative and its code from
drifting.

```sh
$ bl doc run guide.bl.md
bl doc run: guide.bl.md — 2 cells, 0 cell errors
$ bl doc run guide.bl.md --check
bl doc run: guide.bl.md — 2 cells, 0 cell errors (checked, unchanged)
```

Exit `0` when every cell ran (and, with `--check`, nothing drifted), `1` when a
cell errored or a document drifted, `2` on a usage error.

#### `bl doc build TARGET... [--out DIR]`

Render `.bl.md` / `.bl.org` documents to static HTML. `TARGET` is a file or a
directory; `--out` defaults to `site`.

```sh
$ bl doc build . --out site
bl doc build: guide.bl.md → site/guide.html (2 cells)
bl doc build: 1 page → site
```

Exit `0` when every document rendered, `1` when a cell errored, `2` when no
document matched.

### lsp · mcp

#### `bl lsp check FILE [--json]`

Analyze a file the way an editor would: the diagnostics, then every definition
with the facts the compiler **proved** about it — its return type, whether it is
`pure` or has `effects`, whether it `terminates`, and a `◆ native` badge when it
is eligible to compile to a native NIF. See
[02-the-verify-loop.bl.md](02-the-verify-loop.bl.md) for the badge tour.

```sh
$ bl lsp check src/ledger.bl
── ledger ──
  diagnostics: none
  symbols (9):
    announce
        → …  effects  terminates  ·
        calls: bill
    bill
        → …  pure  terminates  ◆ native
        calls: total
    …
```

Exit `0` when the file has no diagnostics, `1` when it has some.

`--json` keys: `diagnostics`, `symbols` (each `name`, `returns`, `pure`,
`terminates`, `calls`).

#### `bl lsp serve`

Speak LSP on stdin/stdout — the language server an editor starts. It advertises
its capability set on `initialize`, publishes diagnostics on open and change,
and answers hover, definition, references, highlights, symbols, completion,
signature help, inlay hints and code actions. The proof-backed queries have no
standard LSP method and are reachable as `$/beamlisp/proof`,
`$/beamlisp/nativeEligible`, `$/beamlisp/impact` and `$/beamlisp/deadCode`.
See [04-editors-and-agents.md](04-editors-and-agents.md).

#### `bl mcp`

Serve the codebase as a fact database over the Model Context Protocol on
stdin/stdout, one JSON object per line. The tools are `code/list`, `code/query`,
`code/ask`, `code/verify`, `code/subscribe` and `code/poll`. See
[04-editors-and-agents.md](04-editors-and-agents.md).

### doctor · version · help

#### `bl doctor [--json]`

Report what this host can do: the language, OTP and Elixir, the native tiers
(`datom_fjall`, `explorer`, `lazy_memo`, `wry`), the solver, the daemon, the
search and code paths, and the checkout's own markers. Two probes are required —
the language evaluates, and the LazyMemo fast lane answers. An absent optional
native is a line in the table, never a crash.

```sh
$ bl doctor
beam-lisp doctor

  ok   language       (+ 1 2) → 3
  ok   otp            29
  ok   elixir         1.20.2
  ok   beam-lisp      2026.0.0
  ok   search-paths   0 root(s)
  ok   code-paths     44 dir(s)
  ok   datom_fjall    loaded
  ok   explorer       loaded
  ok   lazy_memo      65536 bytes fast lane
  ok   z3             sat
  ok   wry            loaded
  --   daemon         not running (:no_socket)
  --   src/           absent
  --   .bl-check.edn  absent (run `bl check --update`)

  ✓ 2 required probes ok; 3 optional absent
```

Exit `0` when the required probes pass, `1` otherwise.

`--json` is one object: `ok`, and `probes` — each `name`, `ok`, `detail`,
`required`.

#### `bl version`

Print the version this build reports.

```sh
$ bl version
beam-lisp 2026.0.0
```

#### `bl help [COMMAND]`

Print the verb list, or one command's line.

```sh
$ bl help check
bl check [PATH...] [--changed] [--update] [--fix] [--json] [--install-hook]
```

## Global flags

Flags may appear anywhere before `--`.

| flag | meaning |
|---|---|
| `-p, --path DIR` | add a library root (repeatable; `BEAM_LISP_PATH` also works) |
| `--code-path DIR` | put a directory of AOT beams on the VM code path (repeatable) |
| `--out DIR` | build / doc output directory |
| `--async` | test: run files concurrently, one env per file |
| `--force` | build: rebuild every source |
| `--jobs N` | build: parallel width per wave (default: schedulers) |
| `--tier V` | lint / fix: `safe` \| `idiomatic` \| `every` |
| `--port N` | serve: TCP port |
| `--changed` | check: only sources changed since the last run |
| `--update` | check: record the new baseline |
| `--fix` | check: apply the safe rewrite |
| `--check` | doc: report drift without writing |
| `--native` | build: also emit native modules |
| `--install-hook` | check: install the pre-commit hook |
| `--json` | machine-readable output where a command offers it |
| `-h, --help` | show help |
| `--version` | print the version |
| `--` | everything after this goes to the program |

## Environment variables

| variable | meaning |
|---|---|
| `BEAM_LISP_PATH` | colon-separated extra library roots — searched after the cwd and before the shipped tiers |
| `BEAM_LISP_CODE_PATH` | colon-separated directories of prebuilt AOT beams to add to the VM code path |
| `BL_DAEMON` | `off` skips the daemon fast path; `auto` starts a missing daemon and retries once |
| `BL_DAEMON_ROOT` | the tree root the daemon serves (default: the current directory) |
| `BL_DAEMON_IDLE_SECONDS` | stop an idle daemon after this many seconds; default `28800` (8 hours), `0` disables the timer |
| `BL_VERSION` | stamps a release build; `bl version` reports it |

## Where a namespace is found

When a program requires a namespace, the loader searches, nearest first:

1. **pushed paths** — directories a running program added at runtime;
2. **the current directory**;
3. **`-p` / `--path` roots**, then `BEAM_LISP_PATH`;
4. **the shipped tiers** under `priv/` — `boot`, `std`, `lib`, `compat`, `build`.

A project file shadows a shipped library of the same name. Inside the beam-lisp
checkout the shipped tiers are already on the search path, so no extra root is
needed.

The loader reads `.bl` sources and literate `.bl.md` / `.bl.org` documents; a
namespace may live in any of them.

## `-` reads standard input

`bl run -` runs the program on standard input; `bl eval -` evaluates it. Both
read to end of input, so a pipeline works:

```sh
$ echo '(* 6 7)' | bl eval -
42
```

## The baseline and the pre-commit hook

`bl check --update` writes `.bl-check.edn` at the command's working directory.
It is meant to be committed: it holds each source's sha256, its diagnostics and
smell counts, and the **names** of its pure, terminating and native-eligible
functions. A reviewer sees a regression when the file and the code disagree, and
a lost proof names the function that lost it.

`bl check --install-hook` writes one line to `.git/hooks/pre-commit`:

```sh
#!/bin/sh
exec bl check --changed
```

It is idempotent, and it refuses to overwrite a hook that is not this one.
