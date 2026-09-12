# bl.ports — the tree's named ports, as the session holds them

A project declares the ports it serves on. `env.bl` names them:

```beam-lisp
{:ports {:web 4000 :metrics {:port 0} :ui 7700}}
```

A number is a preference: if that port is taken, the session SAYS so rather
than quietly serving somewhere else. `{:port 0}` means the OS chooses, and
whoever asks gets the number it chose. The registry behind this is files under
the runtime dir (see `BeamLisp.Daemon.Ports`), which is what lets one tree's
session see what ANOTHER tree's session holds — the collision worth catching is
between trees, and an in-VM table cannot see across.

`bl ports` prints them. `bl ui` prints (or opens) the session's own URL: the one
address that answers for the whole session — the page, and the MCP endpoint.

```beam-lisp
(ns bl.ports
  (:require [bl.util :as u]))
```

## Reading

`list` is the registry as data, oldest name first. `port-of` is the one answer a
program needs: the number behind a name. Both read whatever is LIVE — a claim
whose owner is gone is swept as it is met, so a crashed session never blocks the
next one.

```beam-lisp
(defn list-ports
  "Every live claim: a list of maps with :name :port :root :tree_id :pid."
  []
  (to-list (BeamLisp.Daemon.Ports/list)))

(defn port-of
  "The port behind `name`, or nil when nothing live holds it."
  [name]
  (BeamLisp.Daemon.Ports/port_of (name-str name)))

(defn- name-str [n] (if (keyword? n) (name n) (str n)))
```

## The verbs

`run` is the verb entry the CLI loads on first use, so `bl ports` costs nothing
until someone asks for it.

```beam-lisp
(defn run
  "`bl ports` — name · port · owning tree · pid, one per line."
  [_args _st]
  (let [ps (list-ports)]
    (if (empty? ps)
      (println "bl ports: no session has claimed a port")
      (u/each
        (fn [p]
          (println (str "  " (:name p) "  " (:port p)
                        "  " (Path/basename (:root p)) " (pid " (:pid p) ")")))
        (sort-by (fn [p] (:name p)) ps)))
    0))
```

`bl ui` prints the session's URL. With `--open` it hands it to the desktop's
opener — the same URL, never a second address.

```beam-lisp
(defn url
  "The session's own address, or nil when this tree has no live session."
  []
  (let [p (port-of "ui")]
    (if (nil? p) nil (str "http://127.0.0.1:" p "/"))))

(defn run-ui
  "`bl ui [--open]` — the session's URL, printed; `--open` hands it to the
   desktop's opener. One address for the whole session: the page and /mcp."
  [args _st]
  (let [u (url)]
    (if (nil? u)
      (do (u/io-err "bl ui: no session is running for this tree (bl daemon start)")
          1)
      (do (println u)
          (when (some (fn [a] (= a "--open")) args)
            (System/cmd (str "xdg-open " u)))
          0))))
```
