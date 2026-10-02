# bl vm — every bl VM on this machine

A **vm** is an operating-system process: one `beam.smp` running one build of bl.
Some are warm VMs that serve your projects, one is the gateway that routes names to
ports, and a few are long-running jobs. `bl vm` lists them all, with the realms
(projects) and routes (names) inside each, and stops them.

`bl vm` is about the machine. `bl realm` is about the project in front of you.

Cells marked **Live** read this machine when you run the file
(`bl doc run priv/std/bl/vm.bl.md`), so what they print is yours. Their results are
not stored in the file, because they would be one machine's pids and paths.

```
bl vm [ls] [--all] [--json]          the tree: VMs → realms → routes
bl vm show ID [--json]               one VM in full
bl vm ui [--open]                    the machine console, in a browser
bl vm start gateway [--foreground]   start the gateway (systemd unit if installed)
bl vm stop ID… | gateway | --all [--force]
bl vm prune [--dry-run]              remove what dead VMs left behind
```

`ID` is an id, a pid, a unique id prefix, a label, or a build that exactly one VM
runs. An ambiguous `ID` lists the candidates and stops none.

```beam-lisp
(ns bl.vm
  (:require [bl.util :as u] [bl.json] [bl.gateway :as gw] [bl.ports :as ports]
            [vm.inventory :as inv] [vm.registry :as registry] [vm.paths :as paths]))
```

```bl-result cell0
:bl.vm
```

## Reading the machine

Every row comes from `vm.inventory`, which joins the registry record each VM
writes at start, the claim files of the names it holds, and the gateway endpoint.
The terminal, the console page and `--json` all render these same rows.

Live: the VMs on this machine, right now.

```beam-lisp
(mapv (fn [r] (select-keys r [:id :role :build :state :uptime-s]))
      (inv/rows {}))
```

## Showing a row

Ages use the two coarsest units that matter, and memory counts what a VM holds —
resident plus swapped — because a VM idle for hours can show 8 MB resident while
hundreds sit in compressed swap.

```beam-lisp
(defn human-age
  "Seconds as the coarsest units that matter: 45s, 12m, 4h, 2d15h."
  [s]
  (cond
    (nil? s) "-"
    (< s 60) (str s "s")
    (< s 3600) (str (erlang/div s 60) "m")
    (< s 86400) (str (erlang/div s 3600) "h")
    :else (let [d (erlang/div s 86400) h (erlang/div (rem s 86400) 3600)]
            (if (= h 0) (str d "d") (str d "d" h "h")))))

(defn human-kb
  "KiB as a short size: 512K, 212M, 1.4G."
  [kb]
  (cond
    (nil? kb) "-"
    (< kb 1024) (str kb "K")
    (< kb 1048576) (str (erlang/div kb 1024) "M")
    :else (str (/ (erlang/round (* 10 (/ kb 1048576.0))) 10.0) "G")))
```

```bl-result human-age
&BeamLisp.Ns.Bl.Vm."human-kb"/1
```

```beam-lisp
[(human-age 45) (human-age 14400) (human-age (+ (* 2 86400) (* 15 3600)))
 (human-kb 512) (human-kb (* 212 1024)) (human-kb (* 7 1024 1024))]
```

```bl-result cell3
["45s" "4h" "2d15h" "512K" "212M" "7.0G"]
```

```beam-lisp
(defn- pad [s n] (String/pad_trailing (str s) n))

(defn- state-word [row]
  (cond (= :dead (:state row)) "gone"
        (:legacy row) "up (old)"
        :else "up"))

(defn route-line
  "One route as `name  url  (port)`; the port only when the url hides it."
  [rt]
  (str (pad (:name rt) 8) (:url rt)
       (if (= (:url rt) (:loopback rt)) "" (str "  (" (:port rt) ")"))))

(defn- render-row [row]
  (let [head (str (pad (:id row) 16) " "
                  (pad (name (:role row)) 8) " "
                  (pad (:build row) 9) " "
                  (pad (human-age (:uptime-s row)) 7) " "
                  (pad (human-kb (:memory-kb row)) 6) " "
                  (state-word row)
                  (if (:self row) "  (this command)" ""))]
    (concat
      (list head)
      (map (fn [rm] (str "  " (:name rm)
                         (if (empty? (:routes rm)) ""
                           (str "  " (join "   " (map route-line (:routes rm)))))))
           (:realms row))
      ;; a route whose root no realm claimed (a claim without a .meta): still shown
      (map (fn [rt] (str "  " (route-line rt)))
           (filter (fn [rt] (not (some (fn [rm] (= (:root rm) (:root rt))) (:realms row))))
                   (:routes row))))))

(defn render
  "The tree as lines. Pure: rows and attention notes in, strings out."
  [rows notes]
  (if (empty? rows)
    (list "bl vm: nothing is running"
          "  start one, in a project: bl realm start")
    (concat
      (list (str (pad "VM" 16) " " (pad "ROLE" 8) " " (pad "BUILD" 9) " "
                 (pad "UP" 7) " " (pad "MEM" 6) " STATE"))
      (mapcat render-row rows)
      (if (empty? notes)
        (list)
        (concat (list "")
                (map (fn [n] (str (if (= :warn (:level n)) "! " "- ")
                                  (:text n) "\n    → " (:fix n)))
                     notes))))))
```

```bl-result pad
&BeamLisp.Ns.Bl.Vm.render/2
```

Live: `bl vm` as this machine prints it.

```beam-lisp
(join "\n" (to-list (render (inv/rows {}) (inv/attention (inv/rows {})))))
```

## ls

```beam-lisp
(defn- cmd-ls [st]
  (let [rows (inv/rows {:all (:all st)})
        notes (inv/attention rows)]
    (if (:json st)
      (println (bl.json/encode {:vms rows :attention notes}))
      (u/each println (to-list (render rows notes))))
    0))
```

## show

```beam-lisp
(defn- resolve-or-say
  "{:ok row}, or prints why not and returns {:exit n}."
  [q]
  (let [r (inv/resolve (inv/rows {}) q)]
    (cond
      (contains? r :ok) r
      (= :no-such-vm (first (:error r)))
      (do (u/io-err (str "bl vm: no VM matches \"" q "\" — `bl vm` lists them")) {:exit 1})
      :else
      (do (u/io-err (str "bl vm: \"" q "\" matches more than one VM: "
                         (join ", " (nth (:error r) 2))))
          {:exit 1}))))

(defn- cmd-show [args st]
  (if (empty? args)
    (u/usage-error "usage: bl vm show ID")
    (let [r (resolve-or-say (first args))]
      (if (:exit r)
        (:exit r)
        (let [row (:ok r)]
          (if (:json st)
            (println (bl.json/encode row))
            (do
              (println (str (:id row) "   " (name (:role row)) "   " (state-word row)))
              (println (str "  build    " (:build row)))
              (println (str "  pid      " (:pid row)))
              (println (str "  up       " (human-age (:uptime-s row))))
              (println (str "  memory   " (human-kb (:memory-kb row))))
              (when (:log row) (println (str "  log      " (:log row))))
              (u/each (fn [rm]
                        (println (str "  realm    " (:name rm) "  " (:root rm)))
                        (u/each (fn [rt] (println (str "    route  " (route-line rt))))
                                (to-list (:routes rm))))
                      (to-list (:realms row)))))
          0)))))
```

## ui

The console is a page on a warm VM's own server. `bl vm ui` prints its address —
the name when the gateway answers it, the loopback address always — and `--open`
hands it to the desktop.

```beam-lisp
(def CONSOLE-PATH "/machine")

(defn console-url
  "The console's address on the VM serving the first route named `ui`, or nil when
   no VM serves one. The loopback form: it needs no gateway and no DNS."
  []
  (let [rt (first (filter (fn [r] (= "ui" (:name r)))
                          (mapcat (fn [r] (:routes r)) (inv/rows {}))))]
    (when rt (str (String/trim_trailing (:loopback rt) "/") CONSOLE-PATH))))

(defn- cmd-ui [st]
  (let [url (console-url)]
    (if (nil? url)
      (do (u/io-err "bl vm ui: no warm VM is running — start one in a project: bl realm start")
          1)
      (do (println url)
          (when (:open st) (ports/open-external url))
          0))))
```

Live:

```beam-lisp
(console-url)
```

## start

A warm VM is started in a project: `bl realm start`. The only VM `start` names
here is the gateway, which is machine-wide. It prefers the systemd unit when one is
installed, so the service manager keeps owning its lifecycle.

```beam-lisp
(defn- cmd-start [args st]
  (let [what (first args)]
    (cond
      (= what "gateway") (if (:foreground st) (gw/run-run args st) (gw/run-start args st))
      (nil? what) (u/usage-error "usage: bl vm start gateway [--foreground]")
      :else (u/usage-error (str "bl vm start: \"" what "\" — a project's VM starts with `bl realm start`")))))
```

```bl-result cmd-start
&BeamLisp.Ns.Bl.Vm."cmd-start"/2
```

## stop

The ladder: ask the VM, which drains and removes its own files; then `SIGTERM`, but
only to a pid that is provably a bl node; then `SIGKILL`, only with `--force`. The
VM a command is running inside is never stopped by that command. The gateway is
stopped through the service manager when one owns it.

```beam-lisp
(defn- how-word [how]
  (case how
    :asked "stopped (it drained itself)"
    :terminated "stopped (SIGTERM)"
    :killed "killed (SIGKILL)"
    :gone "already gone"
    (str how)))

(defn- stop-one [row st]
  (if (= :gateway (:role row))
    (gw/run-stop nil st)
    (let [r (inv/stop! row {:force (:force st)})]
      (if (contains? r :ok)
        (do (println (str "bl vm: " (:id row) " " (how-word (:ok r)))) 0)
        (do (u/io-err (str "bl vm: " (:id row) " — "
                           (let [e (:error r)]
                             (if (tuple? e) (nth e 1) (str e)))
                           (if (= :still-running (:error r)) " (try --force)" "")))
            1)))))

(defn- cmd-stop [args st]
  (let [rows (inv/rows {})
        targets (cond
                  (:all st) (to-list (filter (fn [r] (not (:self r))) rows))
                  (empty? args) nil
                  :else (to-list (map (fn [q] (resolve-or-say q)) args)))]
    (cond
      (nil? targets) (u/usage-error "usage: bl vm stop ID… | --all [--force]")
      (empty? targets) (do (println "bl vm: nothing to stop") 0)
      :else
      (let [codes (map (fn [t]
                         (cond (:exit t) (:exit t)
                               (:ok t) (stop-one (:ok t) st)
                               :else (stop-one t st)))
                       targets)]
        (if (every? zero? codes) 0 1)))))
```

## prune

Removes registry records whose VM is gone, and the endpoint files of warm VMs that
accept nobody. A VM that is still starting — socket not up yet, process alive — is
never touched. `--dry-run` lists and removes nothing.

```beam-lisp
(defn- cmd-prune [st]
  (let [r (inv/prune! {:dry-run (:dry_run st)})
        n (count (:removed r))]
    (u/each (fn [f] (println (str "  " f))) (to-list (:removed r)))
    (println (str (if (:dry-run r) "would remove " "removed ") (u/plural n "file")))
    0))
```

Live: what a prune would remove from this machine, without removing it.

```beam-lisp
(select-keys (inv/prune! {:dry-run true}) [:dry-run :removed])
```

## The verb

```beam-lisp
(defn run
  "`bl vm [ls|show|ui|start|stop|prune]`."
  [args st]
  (let [args (u/to-list args)
        sub (or (first args) "ls")
        more (rest args)]
    (cond
      (= sub "ls")    (cmd-ls st)
      (= sub "show")  (cmd-show more st)
      (= sub "ui")    (cmd-ui st)
      (= sub "start") (cmd-start more st)
      (= sub "stop")  (cmd-stop more st)
      (= sub "prune") (cmd-prune st)
      :else (u/usage-error "usage: bl vm [ls [--all] | show ID | ui [--open] | start gateway [--foreground] | stop ID…|gateway|--all [--force] | prune [--dry-run]]"))))
```

```bl-result run
&BeamLisp.Ns.Bl.Vm.run/2
```
