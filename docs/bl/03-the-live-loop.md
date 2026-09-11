# The live loop

beam-lisp keeps a VM alive and adds code to it. `bl` has a verb for each way
that pays off: a **daemon** that makes every command fast, a **watcher** that
reloads a file the moment you save it, a **dashboard** that re-renders the
running image, a **server runner** that parks the VM after a program starts a
web server, and **`bl doc`**, which runs a document's cells and writes their
results back into the file.

Nothing here needs a restart.

## The daemon

Every `bl` command pays a VM boot unless one is already warm. `bl daemon` keeps
one warm, per tree.

```sh
$ bl daemon start      # become the daemon (blocks; the launcher runs it detached)
$ bl daemon status
bl daemon
  pid           1812553
  tree          57461829a20cc2af
  compiler_key  3ac9ac2ebd0b84e00a2b27f98efd9e0c15834b2348d3ee9522781918bd709ec6
  build_id      2026.0.0
  uptime_ms     706826
  queue_depth   0
$ bl daemon stop
bl daemon: stopped (…/beam-lisp)
```

- **One daemon per tree.** A tree is a checkout or an extracted drop payload.
  The daemon is keyed by the tree root, so two terminals in the same tree share
  one warm VM and never contend.
- **The socket is discovery; an authenticated hello is authority.** A client
  connects over a Unix socket and presents the tree's token; only then does the
  daemon run its command.
- **One worker.** Commands run one at a time, because a beam-lisp program shares
  VM-global state with the daemon. Two `bl run`s from two terminals queue.
- **Staleness is a restart, never a hot-swap.** The daemon freezes the compiler
  key it booted with. When the checkout changes under it — or a client presents
  a different key — it refuses work with `restart_required`; the launcher stops
  that VM and a fresh one loads one coherent image. A stale VM never serves.
- **It stops itself when idle.** `BL_DAEMON_IDLE_SECONDS` (default `28800`, 8
  hours; `0` disables) bounds how long a quiet daemon lives.

The drop's launcher uses the daemon automatically: a served command returns in
tens of milliseconds instead of ~1s. `BL_DAEMON=off` skips the daemon entirely;
`BL_DAEMON=auto` starts one detached when none is up. Inside a checkout the same
lifecycle works through `mix bl daemon …`.

`bl daemon status` exits `0` when a daemon answers, `1` when none is running.

## Watch: reload on save

`bl watch FILE|DIR` watches a path, stages every save, runs the coherence check,
commits, and prints a line per commit. It runs until you stop it.

```sh
$ bl watch src
bl watch: watching src — Ctrl+C to stop
```

A save that does not cohere is held back with its reason; the old code keeps
serving. That is the same stage → check → commit pipeline the daemon and the
monitor use.

Live reload needs the `:file_system` application, which the release ships.

## Monitor: the live image, repainted

`bl monitor DIR` is the watcher with a screen instead of a log: after every
commit it clears the terminal and re-renders the running system — the loaded
namespaces, their vars, and the reload journal.

```sh
$ bl monitor src
beam-lisp reload monitor — watching /…/src  (Ctrl-C to stop)

── live image  [· empty] ──

  namespaces (3):
    anf  (42 vars)
    lower  (42 vars)
    reload  (42 vars)
```

The terminal dashboard and the web monitor read the same model
(`reload/inspect`), so they never disagree.

## Serve: run, then keep the VM alive

A program that starts a web server and returns leaves nothing holding the BEAM
open. `bl serve FILE` supplies the missing half: it runs the file, then parks
the VM so the server keeps answering until Ctrl+C.

```sh
$ bl serve server.bl
Running … with Bandit 1.12.4 at 0.0.0.0:4043 (http)
bl serve: server.bl running — Ctrl+C to stop
```

The file is an ordinary program — the same file runs to completion under
`bl run`. `--port N` moves the port through one cooperative call:

```clojure
(ns mini-server
  (:require [web]))

(defn router [_conn]
  {:status 200 :body "hello from bl serve"})

(web/serve {:port (bl.serve/port 4043) :plug router})
```

`(bl.serve/port 4043)` answers `4043` normally and `N` under `bl serve --port
N`. A program that writes a bare literal simply ignores the flag. The web layer
needs `bandit`, which the release ships.

Exit `1` when the program raises, so a broken file never looks like a running
server.

## Ward: isolated, coherence-gated runs

`bl ward FILE...` runs each file in its own fork. Definitions cannot leak
between files, and a file whose definitions do not cohere is reported instead
of run.

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

## Examples: the same forks, for `examples/`

`bl examples` is ward applied to the examples directory. Each example gets
isolation, a deadline, and optional-dependency awareness: an example that needs
a binary or library this host lacks is **skipped** with its reason, not failed.

```sh
$ bl examples examples/hello.bl
…
  ✓ examples/hello.bl

  1 passed, 0 skipped, 0 failed
  ✓ all green (skips are not failures)
```

With no argument the glob is `examples/**/*.bl`. A glob that matches nothing is
a usage error, because an empty selection is almost always a typo.

## Documents: run, write back, check

A `.bl.md` or `.bl.org` file is a program wearing prose. `bl doc run` evaluates
its cells in order, in one namespace, and writes each cell's result back into
the file as an owned span.

```sh
$ bl doc run guide.bl.md
bl doc run: guide.bl.md — 2 cells, 0 cell errors
```

Only the result spans move; prose and cells are preserved byte-for-byte. After
the cell

````markdown
```beam-lisp
(+ 1 2)
```
````

the run adds

````markdown
```bl-result cell0
3
```
````

`--check` runs the cells but writes nothing, and fails when the stored results
differ from a fresh run — the CI gate that keeps a document honest:

```sh
$ bl doc run guide.bl.md --check
bl doc run: guide.bl.md — 2 cells, 0 cell errors (checked, unchanged)
```

Change the code without refreshing the result and the same command exits `1`
with `stored results are stale`.

`bl doc build TARGET... --out DIR` renders the same documents to static HTML. A
target is a file or a directory; `--out` defaults to `site`.

```sh
$ bl doc build . --out site
bl doc build: guide.bl.md → site/guide.html (2 cells)
bl doc build: 1 page → site
```

## The whole loop

```
edit ──▶ bl watch / bl monitor ──▶ stage ──▶ coherence check ──▶ commit
                                              │
                    bl daemon ◀── warm VM ────┘
```

Read [00-the-cli.md](00-the-cli.md) for the flags of each verb, and
[04-editors-and-agents.md](04-editors-and-agents.md) for the editor and agent
surfaces.
