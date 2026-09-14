# The warm session

A daemon is a VM that stays up so the next command is fast. One per project
tree. It is not a background service you have to think about: you start it, it
prints where it is, and everything else in `bl` gets faster without changing
what it means.

```beam-lisp id=require
(ns dev.session-doc
  (:require [bl.ports :as ports] [bl.env :as env] [bl.util :as u]))
```

```bl-result require
:dev.session-doc
```

## Starting it

```
bl daemon start      # become the session (blocks; the launcher detaches it)
bl daemon status     # what the running session IS
bl daemon stop       # drain and exit
```

Starting prints the thing you will want later:

```
bl daemon up for /home/user/code/undefine/beam-lisp
  ui:   http://127.0.0.1:35969   (ephemeral — pin it in env.bl with :ports {:ui 7700})
  mcp:  http://127.0.0.1:35969/mcp   (the same MCP `bl mcp` serves over stdio)
```

The port is EPHEMERAL unless the project pins it: two trees on one machine must
never fight over a number nobody chose. So every checkout gets its own session
page, at the same time, without anyone arranging ports. `:ports {:ui 7700}` in
`env.bl` says you want that one specifically — a promise about a number, which
the whole machine keeps once — and if it is taken the session says so, naming
whoever holds it, instead of quietly serving somewhere else:

```beam-lisp id=ports-list
;; A name nobody else uses, so the answer does not depend on which sessions are
;; running. What this proves is the registry's contract: a claim shows up, and
;; release takes it away. Claim and release name the same tree because that is
;; what the claim belongs to.
(let [name (str "doc-list-" (erlang/unique_integer (list :positive)))
      root "/tmp/doc-tree"
      listed? (fn [] (not (nil? (some (fn [c] (= name (:name c))) (ports/list-ports)))))]
  (try
    (BeamLisp.Daemon.Ports/claim name 0 (u/kw [:root root]))
    (let [claimed (listed?)]
      (BeamLisp.Daemon.Ports/release name (u/kw [:root root]))
      (list claimed (listed?)))
    (finally (BeamLisp.Daemon.Ports/release name (u/kw [:root root])))))
```

```bl-result ports-list
(true false)
```

## What a port costs when it is taken

A port claim is a file, and the file names its owner. That is what makes the
refusal useful — and it is the CHOSEN number that is refused, because a chosen
number is a promise about a port: two trees cannot both keep it. (An ephemeral
name is the other way round: nobody chose that number, so each session gets one
and nobody is refused.)

```beam-lisp id=claim-and-refuse
(let [name (str "doc-" (erlang/unique_integer (list :positive)))
      ;; a port the OS just handed out and nobody bound, so it is provably free
      [_t free] (BeamLisp.Daemon.Ports/claim name 0 (u/kw [:root "/tmp/doc-tree"]))
      pinned (str name "-pin")]
  (try
    (let [[t1 p1] (BeamLisp.Daemon.Ports/claim pinned free (u/kw [:root "/tmp/doc-tree"]))
          [t2 e] (BeamLisp.Daemon.Ports/claim pinned free
                   (u/kw [:root "/tmp/other-tree"] [:pid 4194303]))]
      (list t1 (= free p1) t2 (:root (erlang/element 2 e))))
    (finally
      (BeamLisp.Daemon.Ports/release name (u/kw [:root "/tmp/doc-tree"]))
      (BeamLisp.Daemon.Ports/release pinned (u/kw [:root "/tmp/doc-tree"]))
      (BeamLisp.Daemon.Ports/release pinned (u/kw [:root "/tmp/other-tree"])))))
```

```bl-result claim-and-refuse
(:ok true :error "/tmp/doc-tree")
```

The second claim is refused with `{:taken, claim}`, and the claim carries the
other tree's root and pid. An error that says *whose* port it is beats an
address-in-use.

## One address for the session

The `:ui` port answers for the whole session:

```
GET  /          the dashboard: tasks, ports, the reload image, the worker
GET  /model     the read-model the page is rendered from, as JSON
GET  /ports     the port table alone
POST /mcp       the same MCP server `bl mcp` serves over stdio
POST /intent    run a project task on the session's single worker
```

An editor, an agent and a browser need one address, not a registry of them.

```beam-lisp id=url silent
;; No stored result on purpose: this answers nil or a URL depending on whether a
;; session is up right now, and the port is ephemeral. Storing either would go
;; stale for a legitimate reason. The cell still RUNS, so a broken `ports/url`
;; fails the check.
(ports/url)
```


`bl ui` prints that URL; `bl ui --open` hands it to the desktop's opener. When
no session is running for the tree, both say so rather than inventing one.

## Tasks

The dashboard's Tasks pane is the project's `env.bl` `:tasks` map — the same
value `bl tasks` lists and `bl <name>` runs. This repository declares two:

```beam-lisp id=tasks
(keys (:tasks (env/project (BeamLisp/cwd))))
```

```bl-result tasks
("demo" "runner")
```

## What stays cold

Two things keep their own process and therefore do NOT run through the session:
`bl serve` (a server), `bl monitor` (a repainting watcher), `bl mcp` (an agent
transport), `bl repl`, and any task declared `:watch true`. The daemon has ONE
worker; parking it would block every later client, so it refuses them by name
and says why. `bl watch` is the exception — the daemon HOSTS that watcher, so
its reload commits ride the same worker as everything else and nothing races.

```beam-lisp id=owns-process
(list ((BeamLisp.Env/fetch! "bl.cli" "owns-process?") (list "repl") (BeamLisp/cwd))
      ((BeamLisp.Env/fetch! "bl.cli" "owns-process?") (list "test") (BeamLisp/cwd)))
```

```bl-result owns-process
(true false)
```
