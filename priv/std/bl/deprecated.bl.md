# bl.deprecated — the old commands, and what replaced them

Five words used to name one subsystem: `daemon`, `ports`, `open`, `ui`, `gateway`.
The subsystem is now two nouns. A **vm** is an operating-system process running one
build. A **realm** is a project alive inside it. `bl vm` is about the machine;
`bl realm` is about the project in front of you.

An old spelling still runs. It prints one line to stderr naming the new spelling,
and then does the new thing. This file is the whole mapping, as data, so the
dispatcher, the tests and the docs read the same table.

```beam-lisp
(ns bl.deprecated
  (:require [bl.util :as u]))
```

```bl-result cell0
:bl.deprecated
```

## The table

A row is `[old-argv new-argv]`. `old-argv` is the verb and the subcommand words
that identify the old spelling. `new-argv` is what it runs instead: the words that
replace the matched prefix. Anything after the matched prefix (names, flags)
carries over unchanged.

```beam-lisp silent
(def TABLE
  [[["daemon" "start"]  ["realm" "start"]]
   [["daemon" "stop"]   ["realm" "stop"]]
   [["daemon" "status"] ["realm" "show"]]
   [["daemon"]          ["realm" "show"]]
   [["ports"]           ["vm"]]
   [["open"]            ["realm" "open"]]
   [["ui"]              ["vm" "ui"]]
   [["gateway" "status"] ["vm"]]
   [["gateway" "start"] ["vm" "start" "gateway"]]
   [["gateway" "stop"]  ["vm" "stop" "gateway"]]
   [["gateway" "run"]   ["vm" "start" "gateway" "--foreground"]]
   [["gateway"]         ["vm"]]])
```

Longer prefixes come first on purpose: `daemon start` must match before bare
`daemon`, or every `daemon` command would become `realm show`.

```beam-lisp silent
(defn- prefix? [pre argv]
  (and (>= (count argv) (count pre))
       (= pre (vec (take (count pre) argv)))))

(defn match
  "The table row `argv` matches, or nil. First row wins, and the table is ordered
   so the most specific prefix is first."
  [argv]
  (let [argv (vec argv)]
    (first (filter (fn [row] (prefix? (first row) argv)) TABLE))))

(defn forward
  "`argv` rewritten to the new spelling, or `argv` itself when nothing matches.
   The words after the matched prefix carry over."
  [argv]
  (let [argv (vec argv)
        row (match argv)]
    (if row
      (vec (concat (second row) (drop (count (first row)) argv)))
      argv)))

(defn notice
  "The one line printed when an old spelling is used, or nil when `argv` is not
   an old spelling."
  [argv]
  (let [row (match argv)]
    (when row
      (str "bl: `bl " (join " " (first row)) "` is deprecated; use `bl "
           (join " " (second row)) "`"))))
```

## Finding an old spelling in text that outlives a release

A systemd unit, a shell alias or a script is text, not argv. `stale-in` says which
old spelling a command line uses, so `bl doctor` can report a unit the installer
wrote before the rename. It compares the words after the executable, and only the
table's own rows count, so a new spelling is never reported.

```beam-lisp silent
(defn stale-in
  "The old spelling a command line `text` runs, as {:old \"gateway run\" :new
   \"vm start gateway --foreground\"}, or nil. `text` is what follows `ExecStart=`
   or `alias x=`: the executable first, then the words."
  [text]
  (let [words (vec (rest (filter (fn [w] (not= "" w)) (String/split (str text) " "))))
        row (match words)]
    (when row
      {:old (join " " (first row)) :new (join " " (second row))})))
```

```beam-lisp
[(stale-in "/home/u/.local/bin/bl gateway run")
 (stale-in "/home/u/.local/bin/bl vm start gateway --foreground")
 (stale-in "/usr/bin/bl daemon start")]
```

## Live

What each old spelling becomes, computed from the table above:

```beam-lisp
(mapv (fn [row] {:old (join " " (first row)) :new (join " " (second row))}) TABLE)
```

```bl-result cell3
[{:new "realm start", :old "daemon start"} {:new "realm stop", :old "daemon stop"} {:new "realm show", :old "daemon status"} {:new "realm show", :old "daemon"} {:new "vm", :old "ports"} {:new "realm open", :old "open"} {:new "vm ui", :old "ui"} {:new "vm", :old "gateway status"} {:new "vm start gateway", :old "gateway start"} {:new "vm stop gateway", :old "gateway stop"} {:new "vm start gateway --foreground", :old "gateway run"} {:new "vm", :old "gateway"}]
```


A name after the verb carries over, and flags are untouched:

```beam-lisp
[(forward ["open" "web" "--open"])
 (forward ["gateway" "run" "--port" "0"])
 (forward ["vm" "stop" "abc"])]
```

```bl-result cell4
[["realm" "open" "web" "--open"] ["vm" "start" "gateway" "--foreground" "--port" "0"] ["vm" "stop" "abc"]]
```


The last row is not an old spelling, so it is returned as it was. That is the rule
that makes it safe to run every command through `forward`.

```beam-lisp
(notice ["ports"])
```

```bl-result cell5
bl: `bl ports` is deprecated; use `bl vm`
```


## Removing a row

A row goes when nothing installed or documented still spells the old command. Two
places outlive a release: a systemd unit that `bl install gateway` wrote
(`ExecStart=… gateway run`) and a script someone else owns. `bl doctor` reports a
unit that still uses an old spelling, and a test fails if `docs/` teaches one.
Neither is a date; both are facts a build can check.
