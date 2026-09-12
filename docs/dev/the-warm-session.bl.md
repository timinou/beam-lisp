# The warm session

A daemon is a VM that stays up so the next command is fast. One per project
tree. It is not a background service you have to think about: you start it, it
prints where it is, and everything else in `bl` gets faster without changing
what it means.

```beam-lisp {:silent? true}
(ns dev.session-doc
  (:require [bl.ports :as ports] [bl.env :as env] [bl.util :as u]))
```

```bl-result cell0
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
never fight over a number nobody chose. `:ports {:ui 7700}` in `env.bl` says you
want that one specifically, and if it is taken the session says so — naming
whoever holds it — instead of quietly serving somewhere else:

```beam-lisp {:id "ports-list"}
(ports/list-ports)
```

```bl-result cell1
()
```

## What a port costs when it is taken

A port claim is a file, and the file names its owner. That is what makes the
refusal useful:

```beam-lisp {:id "claim-and-refuse"}
(let [name (str "doc-" (erlang/unique_integer (list :positive)))]
  (try
    (let [[t1 p1] (BeamLisp.Daemon.Ports/claim name 0 (u/kw [:root "/tmp/doc-tree"]))
          [t2 e] (BeamLisp.Daemon.Ports/claim name 0
                   (u/kw [:root "/tmp/other-tree"] [:pid 4194303]))]
      (list t1 t2 (:root (erlang/element 2 e))))
    (finally (BeamLisp.Daemon.Ports/release name))))
```

```bl-result cell2
(:ok :error "/tmp/doc-tree")
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

```beam-lisp {:id "url"}
(ports/url)
```

```bl-result cell3
nil
```

`bl ui` prints that URL; `bl ui --open` hands it to the desktop's opener. When
no session is running for the tree, both say so rather than inventing one.

## Tasks

The dashboard's Tasks pane is the project's `env.bl` `:tasks` map — the same
value `bl tasks` lists and `bl <name>` runs. This repository declares two:

```beam-lisp {:id "tasks"}
(keys (:tasks (env/project (BeamLisp/cwd))))
```

```bl-result cell4
("demo" "runner")
```

## What stays cold

Two things keep their own process and therefore do NOT run through the session:
`bl serve` (a server), `bl monitor` (a repainting watcher), `bl mcp` (an agent
transport), `bl repl`, and any task declared `:watch true`. The daemon has ONE
worker; parking it would block every later client, so it refuses them by name
and says why. `bl watch` is the exception — the daemon HOSTS that watcher, so
its reload commits ride the same worker as everything else and nothing races.

```beam-lisp {:id "owns-process"}
(list ((BeamLisp.Env/fetch! "bl.cli" "owns-process?") (list "repl") (BeamLisp/cwd))
      ((BeamLisp.Env/fetch! "bl.cli" "owns-process?") (list "test") (BeamLisp/cwd)))
```

```bl-result cell5
(true false)
```
