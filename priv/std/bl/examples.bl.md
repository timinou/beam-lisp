# bl.examples — the examples, run in isolated forks

The files under `examples/` are executable documentation: bare scripts with
side effects, often no namespace header, sometimes a live server. Running them
in one VM would let one example's definitions and state leak into the next, and
a single genuine block would wedge the whole run. `bl examples` hands them to
ward's example runner instead, which gives each file three things a `deftest`
suite already enjoys:

- **isolation** — every example runs in its own environment fork, destroyed on
  exit, so nothing it defines can reach a sibling;
- **a deadline** — a real deadlock fails that one example instead of hanging
  the run;
- **optional-dependency awareness** — an example needing a binary or library
  this host does not have is SKIPPED with its reason, never failed, because an
  absent optional dependency is an environment fact.

`examples/` goes on the loader's search path so a namespaced sibling require
resolves the same way regardless of run order, and the heavy shared libraries
the examples use most are loaded once so every fork inherits them instead of
recompiling them from source.

```beam-lisp
(ns bl.examples
  (:require [bl.util :as u]))

(def default-globs
  "The glob a bare `bl examples` runs."
  ["examples/**/*.bl"])

(defn match-paths
  "The example files the globs select: every glob expanded, deduplicated and
   sorted, so one run has one deterministic order."
  [globs]
  (sort (distinct (mapcat (fn [g] (Path/wildcard (u/resolve g))) globs))))

(defn entries
  "The entries ward's runner reads: one string-keyed map per file, the path for
   the report and the program text for the fork. `Loader/read_source` strips a
   `#!` line and reduces a literate document to its code, so a `.bl.md` example
   runs as its cells."
  [paths]
  (u/to-list (map (fn [p] {"path" p "src" (BeamLisp.Loader/read_source p)}) paths)))

(defn- preload
  "The heavy libraries most examples require, loaded once so every fork
   inherits them. Guarded: a library whose own optional dependency is absent
   stays unloaded, and the examples that need it are skipped by the runner."
  []
  (u/each (fn [ns] (try (BeamLisp.Loader/ensure_loaded ns) (catch _ nil)))
          (list "datom" "auth" "reload.migrate")))
```

## One run, one aggregate

`analyze` is the whole run as a value: ward's `run-examples` result with `:ok?`
named `:ok`, so the text report and the JSON object describe the same facts.
Nothing else in this file touches the runner.

```beam-lisp
(defn analyze
  "Run every example file through ward's isolated, timed, dep-aware runner.
   Returns `{:files [...] :passed n :skipped n :failed n :ok bool}`; `:ok` is
   true when nothing failed, because a skip is not a failure."
  [paths]
  (BeamLisp.Loader/ensure_loaded "reload")
  (BeamLisp.Loader/ensure_loaded "reload.ward")
  (preload)
  (let [r ((BeamLisp.Env/fetch! "reload.ward" "run-examples") (entries paths))]
    {:files   (:files r)
     :passed  (:passed r)
     :skipped (:skipped r)
     :failed  (:failed r)
     :ok      (:ok? r)}))

(defn render
  "The human report: one glyph line per example with its reason, then the
   totals — ward's own renderer over the aggregate."
  [d]
  ((BeamLisp.Env/fetch! "reload.ward" "report-examples")
   {:files   (:files d)
    :passed  (:passed d)
    :skipped (:skipped d)
    :failed  (:failed d)
    :ok?     (:ok d)}))
```

## The command

With no arguments the glob is `examples/**/*.bl`. A glob that matches nothing
is a usage error, not a green run over zero files: an empty selection is almost
always a typo in the pattern. The exit code follows `:ok`, so a skipped example
leaves the run green.

```beam-lisp
(defn run
  "`bl examples [GLOB...] [--json]`. Each example runs in its own ward fork, so
   no example contaminates the next or wedges the run. Exits 0 when nothing
   failed, 1 when an example did, 2 when no glob matched."
  [args st]
  (let [globs (if (empty? args) default-globs args)
        paths (match-paths globs)]
    (if (empty? paths)
      (u/usage-error (str "bl examples: no example files matched: " (join " " globs)))
      (do (u/register-paths st)
          (BeamLisp.Env/add_search_path (u/resolve "examples"))
          (let [d (if (:json st) (u/silent (fn [] (analyze paths))) (analyze paths))]
            (u/emit st d render)
            (if (:ok d) 0 1))))))
```
