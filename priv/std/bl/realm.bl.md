# bl realm — the project in front of you, alive

A **realm** is a project (a directory with an `env.bl`) running inside a VM. It is
what a developer means by "my daemon": its address, its routes, its index, its
tasks. `bl vm` shows the machine; `bl realm` shows the project, found from the
current directory.

```
bl realm [show] [--json]           this project's VM, routes and address
bl realm open [NAME] [--open]      the address of a route (default: ui)
bl realm start [--foreground]      start this project's warm VM
bl realm stop                      stop it
```

Cells marked **Live** read this machine when you run the file
(`bl doc run priv/std/bl/realm.bl.md`); their results are not stored, because they
would be one machine's paths.

Every command here takes the shared flags: `--root DIR` keys the realm on a
directory other than the current one, and `--json` prints data instead of text.

```beam-lisp
(ns bl.realm
  (:require [bl.util :as u] [bl.json] [bl.vm :as vm] [vm.inventory :as inv]
            [vm.paths :as paths] [vm.client :as client] [vm.inspect :as inspect]
            [bl.ports :as ports]))
```

```bl-result cell0
:bl.realm
```

## Finding the realm

A realm is found the way a command finds it: the nearest tree root above the
directory, or the `--root` you gave. The answer is the VM that serves that root,
and the realm inside it.

```beam-lisp
(defn root-of
  "The root `bl realm` means: `--root` when given, else the tree that encloses the
   current directory, else the directory itself."
  [st]
  (let [r (paths/resolve-root (BeamLisp/cwd) (:root st))]
    (if (contains? r :ok) (:ok r) (BeamLisp/cwd))))

(defn here
  "The realm serving `root`: {:vm row :realm realm :root root}, or nil."
  [root]
  (some (fn [row]
          (some (fn [rm] (when (= (:root rm) root) {:vm row :realm rm :root root}))
                (:realms row)))
        (inv/rows {})))
```

Live: the realm for this directory, and what the machine says about it.

```beam-lisp
(let [root (root-of {})
      h (here root)]
  {:root root
   :running (some? h)
   :vm (when h (select-keys (:vm h) [:id :role :build :state]))})
```

## show

`show` prints the VM the realm lives in, its routes, and the session's own status:
identity, build, ports, index, schedules. It is one function of the same read-model
the page at `/` renders (`vm.inspect`), so the two faces cannot disagree.

```beam-lisp
(defn- none-running [root]
  (u/io-err (str "bl realm: no realm is running for " root))
  (u/io-err "  start one: bl realm start")
  1)

(defn cmd-show [st]
  (let [root (root-of st)
        h (here root)]
    (if (nil? h)
      (none-running root)
      (let [rm (:realm h) row (:vm h)]
        (if (:json st)
          (println (bl.json/encode {:realm rm :vm (select-keys row [:id :build :pid :uptime-s :memory-kb])}))
          (do
            (println (str (:name rm) "   in " (:id row) "   up " (vm/human-age (:uptime-s row))))
            (println (str "  root     " root))
            (println (str "  build    " (:build row)))
            (u/each (fn [rt] (println (str "  route    " (vm/route-line rt))))
                    (to-list (:routes rm)))
            (println "")
            ;; the session's own account of itself, asked of the VM that holds it
            (client/status root)))
        0))))
```

```bl-result none-running
&BeamLisp.Ns.Bl.Realm."cmd-show"/1
```

## open

`open NAME` prints the address behind a route and, with `--open`, hands it to the
desktop. A raw port number works too. A name this project does not hold is looked
up across the whole machine, so you can open another project's route from anywhere.

```beam-lisp
(defn- route-named [h name]
  (first (filter (fn [r] (= (:name r) name)) (:routes (:realm h)))))

(defn- machine-route
  "A route `name` (or port number) held by any VM, for a caller outside the
   realm that owns it."
  [name]
  (let [rows (inv/rows {})
        all (mapcat (fn [r] (:routes r)) rows)]
    (first (filter (fn [rt] (or (= (:name rt) name) (= (str (:port rt)) name))) all))))

(defn cmd-open [args st]
  (let [h (here (root-of st))
        name (or (first args) "ui")
        rt (or (when h (route-named h name)) (machine-route name))]
    (if (nil? rt)
      (do (u/io-err (str "bl realm: nothing holds the name \"" name "\" — `bl vm` lists what runs"))
          1)
      (do (println (:url rt))
          (when (not= (:url rt) (:loopback rt)) (println (str "  → " (:loopback rt))))
          (when (:open st) (ports/open-external (:url rt)))
          0))))
```

## start and stop

A warm VM is one process serving one project. `start` returns once it answers; with
`--foreground` it becomes the VM and blocks, which is what a service manager wants.

The launcher recognises `realm start` before this code runs: it detaches the VM,
waits for it to answer, and reports. `--foreground` skips that, so the request
reaches here and this process *is* the VM.

```beam-lisp
(defn cmd-start [st]
  (let [root (root-of st)]
    (client/start-foreground root)
    0))

(defn cmd-stop [st]
  (client/stop (root-of st)))
```

```bl-result cmd-start
&BeamLisp.Ns.Bl.Realm."cmd-stop"/1
```

## The verb

```beam-lisp
(defn run
  "`bl realm [show|open|start|stop]`."
  [args st]
  (let [args (u/to-list args)
        sub (or (first args) "show")]
    (cond
      (= sub "show")  (cmd-show st)
      (= sub "open")  (cmd-open (rest args) st)
      (= sub "start") (cmd-start st)
      (= sub "stop")  (cmd-stop st)
      :else (u/usage-error "usage: bl realm [show | open [NAME] [--open] | start [--foreground] | stop]  [--root DIR] [--json]"))))
```

```bl-result run
&BeamLisp.Ns.Bl.Realm.run/2
```
