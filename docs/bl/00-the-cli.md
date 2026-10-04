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

## The warm VM

The drop's launcher first looks for a **warm VM for the caller's project** and
forwards the command to it over a Unix socket. A served command returns in tens
of milliseconds instead of the ~1s a cold VM boot costs. With no warm VM, the
launcher cold-boots the release and runs the command there — same result, just
slower.

Three global flags choose the mode (they may appear anywhere before `--`):

| flag | meaning |
|---|---|
| `--cold` | run this command in a fresh VM; never use a warm one |
| `--warm` | use the warm VM, starting one if none runs |
| `--root DIR` | act as if the command ran in `DIR`: the project, and so the warm VM, it belongs to |
| `--share-vm` | use the one VM this build shares between projects |
| `--own-vm` | use this project's own VM (wins over `--share-vm`) |

A project declares its own default in `env.bl`, and the machine in
`~/.config/bl/config.bl`, with `:warm "off" | "attach" | "start"`. Precedence:
flag > `env.bl` > `config.bl` > the built-in default. The default depends on
whether the project shares its VM (below): a project with its own VM `attach`es —
it uses a running warm VM and never starts one, because that would be a VM per
directory — while a project that shares its build's VM `start`s it, because that is
one process however many projects use it.

### One VM per project, or one shared

By default a project has its own warm VM. A project that has checked it can live
beside others declares it in `env.bl`:

```clojure
{:name "notes"
 :vm "shared"}     ; "own" (the default) | "shared"
```

Every project on one build that says `"shared"` then uses a single VM, and each
command finds its project from the directory it runs in (the nearest `env.bl`
at or above it). `bl realm stop` in such a project closes that project's realm and
leaves the VM and the other projects running; `bl realm members` lists what a
project owns, `bl realm restart` closes and reopens it; `bl vm stop` ends the VM itself.

Sharing is a choice because the VM keeps one copy of each namespace: two shared
projects that both define a namespace named `app` share it. A source checkout is
never shared. `--share-vm` and `--own-vm` decide for one command; precedence is
flag > `env.bl` > own.

With `start`, the command that finds no warm VM runs cold, right away, and starts
a warm VM in the background for the next one. It never waits for the VM. What the
background VM prints goes to `~/.local/state/beam-lisp/logs/` (read it with
`bl vm logs`), and a second command that arrives while one is starting does not
start another.

`bl realm start`, `stop` and `show` are the lifecycle — see
[03-the-live-loop.md](03-the-live-loop.md) for the reload loop and
[06-the-warm-daemon.md](06-the-warm-daemon.md) for the whole warm-VM DX: named
ports, the gateway that resolves the names, and the live dashboard.

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

The session is one thing shown three ways:

```sh
$ bl repl            # a native window on the session's /repl page (default)
$ bl repl --web      # that page in your browser
$ bl repl --terminal # the read-eval-print loop in this terminal
```

The default window needs the native WebView backend —
`priv/native/wry_webview.so`, built from `native/wry_webview` against GTK3,
WebKitGTK, and libgtk-layer-shell — and a display server (`WAYLAND_DISPLAY` or
`DISPLAY`). A host that lacks either falls back to the terminal loop. On
Wayland the window is content-only: the app fills the surface and no GTK
title/header bar is drawn. On X11 the window manager frames it as usual. The
window and `--web` alike attach to the tree's running session when one exists,
and boot one when none does. After updating the REPL on disk, restart an older
running warm VM (`bl realm stop`, then `bl realm start`) before reopening the
page: its HTTP router remains the version loaded at boot. `bl doctor` reports
the native backends this host can build.

```sh
$ bl repl --terminal
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

### test · examples · check · lint · fix · ask

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

`bl ward` is gone — `bl test` runs every file in its own isolated fork by
default, and `--shared` runs them all in one image.

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

A source question (`symbols`, `dead-code`) is answered from an ANALYSIS of each
file — its document symbols — and that analysis is remembered per source
revision, beside the stores, under the project the sources belong to (the same
rule as everything else here: the PATH decides, not the shell). Asking twice over
an unchanged file pays for that analysis once; an edit is a new entry, because
the name is the content hash. `symbols` and `dead-code` share the one analysis,
which is why `dead-code` — two analyses' worth of work — costs one.

### override

The `.bl` the compiler ships is on every tree's search path — and the search
order (tree > configured roots > shipped tiers) means a project file whose
namespace matches already shadows a shipped one. `bl override` makes that a
workflow. A tree's `overrides/` directory is a library root by convention: no
flag, no config.

#### `bl override vendor NS...`

Copy a shipped namespace's source into `overrides/` to fix a bug in it. The
copy shadows the shipped file for every command in the tree; the shipped file
is untouched.

#### `bl override apply PATCH.bl`

Apply a patch: a beam-lisp PROGRAM exporting `(transform [ctx])`, handed the
shipped sources plus the codebase database to locate its targets by structure
(`:db-for`, `:read-shipped`), returning the new sources and its test files.
Landing is all-or-nothing, verified before it takes effect:

- logical, implicit: the compiler's diagnostics must be clean on each new
  source, and each overridden namespace must load in an isolated env;
- unit, implicit: the shipped tests of each touched namespace must pass
  against the override (when a checkout's test tree is visible);
- unit, explicit: the patch's own tests must pass.

Any failure rolls every written file back and exits `1`.

```sh
$ bl override apply patches/edn_tagged_readers.bl
wrote overrides/clojure/edn.bl
✓ override applied — 1 file(s), 2 test file(s) passed
```

#### `bl override list · diff NS · revert NS...`

See what this tree shadows and whether it drifted, diff an override against
the shipped source, or drop an override and return to shipped behavior.

See research/p17_overrides/ for a worked patch (teaching clojure.edn tagged
literals via :readers/:default).

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

### watch · monitor · serve

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

write `(bl.serve/port :web 4043)` and the port comes from the project's
`:ports {:web 4000}` (`--port N` still wins), claimed in the session's registry
and registered with the name it answers to — so the app is reachable at
`http://web.<project>.test` and no human reads the number. A port another live
process holds is an error naming the owner, never a silent move.

```clojure
(web/serve {:port (bl.serve/port :web 4043) :plug router})
```

```clojure
(ns mini-server
  (:require [web]))

(defn router [_conn]
  {:status 200 :body "hello from bl serve"})

(web/serve {:port (bl.serve/port 4043) :plug router})
```
`bandit`, which the release ships.

### vm · realm

Two nouns, one rule: **`bl realm` is about the project in front of you; `bl vm`
is about the machine.** Every flag belongs to the shared argv table (see
[Global flags](#global-flags)). The full command set is in
[../design/realm/commands.md](../design/realm/commands.md).

#### `bl vm [--all] [--json]`

The tree: VMs → realms → routes. Every port a realm has claimed, name first:
the host it answers at, the number behind it, the VM that owns it and its pid. A
claim with no name — a port nobody declared — still lists, with its loopback
address. `--all` adds records whose VM is gone; `--json` prints
`{vms, attention}`.

```sh
$ bl vm
VM               ROLE     BUILD     UP      MEM    STATE
a238fa91-4821    warm     a238fa91  4h      212M   up
  blueprint  ui      http://blueprint.test/
  knowledger ui      http://knowledger.test/
gateway-3302     gateway  a238fa91  4h      18M    up
c7704-12         warm     277640b0  2d15h   7.0G   up (old)

! 2 name(s) are claimed, and nothing answers them
    → bl vm start gateway
```

The address shows the port when it has to and no port when it does not: the one
HTTP port a URL may leave out is 80, so a gateway standing on 80 (or one fronted
by `bl install redirect`) prints `http://web.beam-lisp.test/`, and anything else
prints the port — an address that omitted the port nothing is listening on would
look clickable and refuse. With no gateway at all the names print bare, and the
hint above says what is missing.

The last two lines appear only when names are registered and nothing is
listening for them. Exit `0`; an empty registry prints one line saying so.

#### `bl vm show ID [--json]` · `bl vm stop ID… | --all [--force]` · `bl vm prune [--dry-run]`

`show` is one VM in full; `stop` asks then TERMs (`--force` adds KILL), and
never includes the VM the command itself runs in; `prune` removes what dead VMs
left behind. `ID` is an id, a pid, a unique id prefix, a label, or a build that
exactly one VM runs — nothing guesses. Exit `1` on no match, ambiguity, or a
refusal. See [../design/realm/commands.md](../design/realm/commands.md).

#### `bl realm [show] [--json]`

This project's realm: its VM, its routes, its address. `bl realm` defaults to
`show`.

#### `bl realm start|stop`

Start this project's warm VM explicitly (`start` blocks; the launcher runs it
detached), or drain the realm and remove its socket. In day-to-day use the
launcher starts the warm VM on demand, so `start` is rarely typed.

#### `bl realm open NAME [--open] [--port N]`

The address behind a port name — the everyday verb, so nobody reads a number.
It prints the name and the loopback address it routes to; `--open` hands the
first one to the desktop's opener. `NAME` is a project port name (`web`) or a
raw port number. Exit `1` when nothing live holds the name, `2` with no
argument.

```sh
$ bl realm open web
http://web.beam-lisp.test:7777/
  → http://127.0.0.1:4000/
```

One URL, and the port in it is the one that works: with the gateway answering on
port 80 — itself or through `bl install redirect` — it is
`http://web.beam-lisp.test/` instead.

#### `bl vm ui [--open]`

The session's own address — the page and its `/mcp` endpoint, one URL. Exactly
`bl realm open ui`: one implementation, so the terminal and the dashboard cannot
disagree about where the session is. Exit `1` when no session is running for
this tree.

#### `bl vm start|stop gateway`

The one listener that answers NAMES: one per user, holding the port a URL may
leave out (80 when it can), reading `Host:` and splicing the connection to the
port that registered that name. `bl vm` lists it with the routes it answers.

```sh
bl vm start gateway                # start it (a systemd user unit when installed; detaches otherwise)
bl vm stop gateway                 # stop the running one
bl vm start gateway --foreground   # the foreground process the unit execs (blocks)
```

The port the gateway holds is the one thing a developer cannot read off the
routes: it is probed, not configured, and when nothing answers on 80 the
listing points at `bl install redirect` instead. `--foreground` blocks, and a
pinned `--port N` it cannot bind is an error rather than a silent move.

Exit `0` when the gateway is up; `stop` exits `1` when none was running; `2` on
an unknown subcommand.

Port 80 is the only piece that needs root. Two ways to get it, and either one
ends with every printed address losing its port:

```sh
bl install redirect          # loopback-only nftables redirect + a system unit — recommended
# or hand the gateway the port itself:
printf 'net.ipv4.ip_unprivileged_port_start=80\n' | sudo tee /etc/sysctl.d/60-beam-lisp-gateway.conf
sudo sysctl --system
```

Which one is in force is not configured and not guessed: the gateway probes port
80 and prints the address that answers. `bl vm` shows the port it holds.

Names are derived from the tree, so the whole story is in
[../dev/names.bl.md](../dev/names.bl.md): `<port>.<project>.test` and its
`.localhost` twin, qualified by `:instance` when two checkouts of one project
want different names.

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

#### `bl lsp hover FILE LINE COL`

Print exactly what an editor's tooltip shows at a source position (1-based),
so the hover card is testable without an editor. A call names its callee and
carries the fn's whole proof card — docstring, signature, inferred return,
purity/effects, termination, recursion growth class, native eligibility. A
position on a parameter, a literal, or an operator answers as that thing.

````sh
$ bl lsp hover src/ledger.bl 24 18
### total — function

> Sum the ledger's entries.

```beam-lisp
(total entries)
```

- **returns** `float | int`
- **pure** — it touches no state, so a call to it may be reordered or dropped
- **terminates** — every loop in it halts
- **grows** `O(n)` — self-recursive; that is its recursion's cost shape
- **native-eligible** — pure ∧ terminating, a candidate for native offload
````

#### `bl lsp actions FILE LINE COL [--json]`

The quick-fixes and refactors offered at a position: one `fix: …` per
diagnostic on the line, `compile '<fn>' to native` when the enclosing fn is
pure ∧ terminating, and `annotate '<fn>' — returns …` when the inferred return
type is narrower than `any` (the edit inserts the `^{:args … :ret …}` metadata
the typed checker consumes).

#### `bl lsp complete FILE LINE COL [--json]`

The completion candidates at a position, each with its proven detail
(`→ float | int · pure ↓`).

#### `bl lsp symbols FILE [--json]`

The document outline: every definition with its inferred return, purity,
termination, and recursion growth class.

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
`code/ask`, `code/verify`, `code/subscribe` and `code/poll`; the resources are
`code://beam-lisp/schema` and `code://beam-lisp/namespaces`. The server also
speaks `prompts/list` + `prompts/get` — `beam-lisp/onboarding`,
`beam-lisp/usage`, `beam-lisp/protocol`, each assembled by datalog from the
`:instr/*` facts mounted in the same database — and `server/discover` carries
the onboarding prompt as its `instructions` key. See
[04-editors-and-agents.md](04-editors-and-agents.md).

Starting the server mounts the codebase it serves — `codebase.bl` and
`typed.bl`, resolved through the load path (the priv tiers ship them) rather
than the working directory — so `bl mcp` answers the same facts from anywhere,
with no checkout, arguments or `--path` needed. The mount is paid once, at
startup (a few seconds); every request after that reads the conn it built.

### install

#### `bl install [TARGET [DIR]] [--check] [--remove] [--json]`

Install beam-lisp into your tools. With no TARGET, lists the targets. A target
writes what the tool needs and reports each step; `--check` verifies an
installation without writing anything; `--remove` undoes what a target wrote.

```sh
$ bl install doom
bl install doom

  ok   module    ~/.config/doom/modules/lang/beamlisp (7 files)
  ok   grammar   ~/.config/emacs/.local/etc/tree-sitter/libtree-sitter-beamlisp.so
  ok   init.el   already wired
  ok   next      doom sync, then restart Emacs
```

`doom` vendors the Doom module (major mode, LSP, warm REPL, codebase
questions, literate `.bl.md`/`.bl.org` support) into the Doom user directory,
compiles the tree-sitter grammar with `cc`, and adds
`(beamlisp +lsp +literate)` under `:lang` in `init.el` — idempotently, in
place. The Doom directory resolves from the argument, `$DOOMDIR`,
`~/.config/doom`, `~/.doom.d`.

`mcp` assembles the agent instructions from the instruction corpus — the
same facts the MCP server serves over `prompts/get` — and writes
`beam-lisp-mcp.onboarding.md` and `beam-lisp-mcp.usage.md` into DIR (default
`.`), with the client registration snippet in each. An agent reads the files;
a client can also just run the server.

`gateway` writes a systemd **user** unit so the name gateway starts at login.

`redirect` makes port 80 answer for the gateway without giving anything else on
the machine the right to: one nftables table sends packets addressed to
`127.0.0.0/8:80` and `[::1]:80` to the port the gateway already holds, plus a
system unit that reapplies it at boot. It is the recommended way to get a
portless address (loopback only, removable with `--remove`), and it is the one
target that needs root, so it runs its script with `sudo` when it can and
otherwise prints exactly what to paste:

```sh
$ bl install redirect
bl install redirect

this one needs root — run it:

set -e
install -D -m644 ~/.local/state/beam-lisp/redirect/redirect.nft /etc/bl-gateway-redirect.nft
…
systemctl enable --now bl-gateway-redirect.service

  --   ruleset     needs root — the script printed above
  --   port 80     not answered — run: bl install redirect (loopback only, removable), or: sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
  ok   gateway port on the fallback port 7777 — the boot rule stays right
```

Exit `0` when every step is ok, `1` when one failed, `2` on a bad invocation.

The rule is unconditional for loopback destination port 80, so **if something
else already answers there, the redirect takes it**: a request to whatever holds
it — `http://localhost/`, or by address — lands on the gateway instead. The
report says which of the three states it found (answered by a gateway, answered
by something else, not answered) rather than assuming the port is free, and
`bl install redirect --remove` gives it back.

`--json` keys: `target`, `ok`, `steps` (each `name`, `ok`, `detail`).

### doctor · version · help

#### `bl doctor [--json]`

Report what this host can do: the language, OTP and Elixir, the native tiers
(`datom_fjall`, `explorer`, `code_embed`, `lazy_memo`, `wry`), the solver, the
warm VM, the search and code paths, the embedding weights (which of the three
copies is answering), and the checkout's own markers. Two probes are required —
the language evaluates, and the LazyMemo fast lane answers. An absent optional
native is a line in the table, never a crash.

```sh
$ bl doctor
beam-lisp doctor

  ok   language          (+ 1 2) → 3
  ok   otp               29
  ok   elixir            1.20.2
  ok   beam-lisp         0.1.0
  ok   search-paths      0 roots
  ok   code-paths        44 dirs
  ok   datom_fjall       loaded
  ok   explorer          loaded
  ok   code_embed        loaded
  ok   lazy_memo         65536 bytes fast lane
  ok   z3                sat
  ok   wry               loaded
  --   daemon            not running (:no_socket)
  --   src/              absent
  ok   .bl-check.edn     present
  ok   .local/bl/cache/  present
  ok   embedding         present (ships with this bl: ~/.local/share/drop/<payload>/lib/beam_lisp-0.1.0/priv/embed/potion-code-16M-v2)

  ✓ 2 required probes ok; 2 optional absent
```

#### `bl cache status | prune [--max-mb N] [--dry-run]`

The analysis store is content-addressed: one artifact per source *revision*,
which is what makes a stale one unreachable — and also what makes them pile up.
`status` says what this tree's stores hold, per directory, and whether the total
is over the cap; `prune` deletes the OLDEST first, never the newest (the one the
run that just finished wrote), until it is under.

An ENTRY is one artifact: a store — `<ns>.<sha>.fjall` with its `.blobs` sibling,
which holds the values too large to inline — or a remembered per-file analysis,
`<kind>.<sha>.term`, which the source questions leave behind. Counting one kind
and not the other would let a capped cache grow through the files the cap does
not see. `--dry-run` reports and deletes
nothing, `--max-mb` overrides the cap for one run, and `BL_CACHE_MAX_MB`
(default 512) for every run. `BL_CACHE_DIR` moves the store itself — every tier
below it is skipped — which is what a CI job or a container wants: the analysis
goes on a volume, or into a directory the job deletes, and the model stays where
it is. Relative values resolve against the command's cwd. `bl search` prunes
after it indexes, so the ceiling holds without anyone remembering it.

```sh
$ bl cache status
  10 entries  65 MB  /home/user/code/undefine/beam-lisp--semantic/.local/bl/cache
total 65 MB · cap 512 MB (under)
```

A store per source revision means nothing here is precious: every one can be
rebuilt from the source it came from, and the only thing pruning costs is the
next run's time. Where they live is a project question — see
`docs/code-semantic-search.md`.

Exit `0` when the required probes pass, `1` otherwise.

`--json` is one object: `ok`, and `probes` — each `name`, `ok`, `detail`,
`required`.

#### `bl version [--short] [--json]`

The version, and where this build came from: commit (`+dirty` when its inputs
had uncommitted changes), branch, worktree, build time, build id. `--short` is
the version alone; `--json` is the whole `BUILD_INFO.bl` record.

```sh
$ bl version
beam-lisp 0.1.0 · 1cf72d26+dirty (main) · ~/code/undefine/beam-lisp · built 2026-09-24T08:58:37Z · build 6da863d2
$ bl version --short
beam-lisp 0.1.0
```

#### `bl which` · `bl self-update [NAME]` · `bl self-install` · `bl hooks install` · `bl self-gc`

The PATH launcher's own verbs: which build runs here and why, getting builds
(`stable`, `latest`, `v2026.4`, `commit:SHA`, `bleeding-edge[:DIR]`),
installing the launcher, automatic builds and the `latest` push guard, and
the store's cleanup. See [native-bundler §15](../native-bundler.md).

A project picks its build in `env.bl`:

```clojure
{:name "my-app"
 :bl "latest"}          ; or "stable", "v2026.4", "commit:1cf72d26"
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
| `--check` | doc: report drift without writing; install: verify, don't write |
| `--remove` | install: undo what a target wrote |
| `--native` | build: also emit native modules |
| `--install-hook` | check: install the pre-commit hook |
| `--json` | machine-readable output where a command offers it |
| `--cold` | run in a fresh VM; never use a warm one |
| `--warm` | use the warm VM, starting one if none runs |
| `--root DIR` | the project root the warm VM is keyed on |
| `--idle SECONDS` | `realm start`: stop the VM after this long unused (default 28800; 0 never) |
| `--log PATH` | `realm start`: where the VM writes what it prints |
| `--lines N` | `vm logs`: how many lines to show (default 50) |
| `--follow` | `vm logs`: keep printing as the VM writes |
| `-h, --help` | show help |
| `--version` | print the version |
| `--` | everything after this goes to the program |

## Environment variables

Every variable `bl` reads, once. A preference belongs in `env.bl`, `~/.config/bl/config.bl` or a flag; a variable is here only as an override, a handoff between the launcher and the VM, a test seam, or a standard one. `test/bl/env_vars_test.bl` diffs this table against what the code reads, so a variable cannot be read without being listed or listed without being read.

| variable | kind | meaning |
|---|---|---|
| `BEAM_LISP_PATH` | override | colon-separated extra library roots, searched after the cwd and before the shipped tiers (`env.bl :paths` is the declared form) |
| `BEAM_LISP_CODE_PATH` | override | colon-separated directories of prebuilt AOT beams to add to the VM code path |
| `BEAM_LISP_AOT_CACHE` / `BEAM_LISP_AOT_CACHE_DIR` | override | turn the AOT cache off; move it |
| `BEAM_LISP_AOT_REPAIR` / `BEAM_LISP_AOT_STRICT` | override | whether a stale library beam is repaired in place; whether staleness is an error |
| `BEAM_LISP_DEV` / `BEAM_LISP_RELOAD` / `BEAM_LISP_IMAGE` | declaration | what a tree says about itself to the reloader and the image builder |
| `BEAM_LISP_MODEL_DIR` | override | where the embedding model's weights live |
| `BEAM_LISP_Z3` / `BEAM_LISP_Z3_FORCE` | workaround | z3 provisioning (to be fixed, then deleted) |
| `BEAM_LISP_NIF_TRACE` | test | trace native calls |
| `BL_USE` | override | the build to run here, overriding every other rule (`stable`, `latest`, `commit:SHA`, …) |
| `BL_BUILD` | override | `never`: a missing build fails instead of being fetched or built |
| `BL_AUTOBUILD` | override | `off`: git hooks queue no builds |
| `BL_ALLOW_UNPUSHED_LATEST` | override | `1`: the `latest` pre-push guard lets the push through |
| `BL_DROP_KEEP_DAYS` / `BL_DROP_GRACE_HOURS` | override | how long an unreferenced build is kept (14 days since last use / 24 h) |
| `BL_BUILD_TIMEOUT_MIN` | override | a build step is stopped after this many minutes (45) |
| `BL_INSTALL_BIN` | override | where `self-install` puts the launcher |
| `BL_CACHE_DIR` / `BL_CACHE_MAX_MB` | override | where the analysis store lives (overrides every tier, relative to the cwd) and its cap in MB (512) |
| `BL_CATALOG_DIR` / `BL_CATALOG_LIB` | override | the component catalog's examples and vocabulary directories (`env.bl :catalog` is the declared form) |
| `BL_HOTPATCH` | override | hot-patching of a running VM |
| `BL_INDEX_WORKERS` | override | how many workers the code index uses |
| `BL_NAMES_SUFFIXES` | override | the host-name suffixes a route may claim |
| `BL_ORACLE_SESSIONS` | override | where the oracle looks for sessions |
| `BL_SEED_EBIN` / `BL_SEED_EBIN_FALLBACK` | override | the beam directory `bl seed` reads (`--ebin` is the flag) |
| `BL_BIN` / `BL_ROOT` / `BL_BUILD_ID` / `BL_BOOT_REEXECED` / `BL_EBIN` | protocol | the launcher's handoff to the VM: which launcher, which tree, which build. Do not set these |
| `BL_TEST_TIMEOUT` / `BL_TEST_TIMES` / `BL_TEST_UID` / `BL_SELFBUILD_GATE` | test | test-runner seams |
| `BL_Z3_TIMEOUT` / `BL_Z3_READ_TIMEOUT` | override | the z3 solver's time limits |

`BL_VERSION` is not here: only the release workflow sets it, to stamp `env.bl :app :vsn`; nothing reads it at run time.

## Where a namespace is found

When a program requires a namespace, the loader searches, nearest first:

1. **pushed paths** — directories a running program added at runtime;
2. **the current directory**;
3. **`-p` / `--path` roots**, then `BEAM_LISP_PATH`;
4. **the shipped tiers** under `priv/` — `boot`, `std`, `lib`, `compat`, `build`.

A project file shadows a shipped library of the same name. Inside the beam-lisp
checkout the shipped tiers are already on the search path, so no extra root is
needed.

A process **bundle** lives at `priv/std/proc/<name>.bl` and declares
`(ns proc.<name>)` — the path and the namespace are one fact, so a bundle has
exactly one home. `priv/std/proc.bl` is the tier's door: `(:require [proc :as proc])`
reaches every bundle's verbs through it, while `(:require [proc.tick])` still
loads one bundle on its own.

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
