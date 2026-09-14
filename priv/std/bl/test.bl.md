# bl.test — the suite runner, isolated by default

`bl test` runs a tree's tests. Each FILE runs in its own env fork, off one warm
image, coherence-checked, contained: a file that crashes at load cannot take
the run down, and a file that mutates the world cannot reach the next one. That
is what `ward` was, and it is now simply how `bl test` works — there is no
second runner to choose between.

```beam-lisp silent
(ns bl.test
  (:require [bl.util :as u]))
```

## The three shapes

**Isolated (the default).** Every file forks; a misbehaving file is contained.
Warm because the image the forks come from is the one this process already has.

**`--shared`.** Every file runs in ONE image, one after another, sharing what
the files set up between them — the old behavior. The image is forked from this
one first, so a run is the files you named and not every suite this process has
already run. Reach for it when a suite genuinely needs a shared world — and
expect the failure modes isolation exists to prevent.

**`--async`.** The concurrent runner: files run at once, each in its own env.
Faster on a big corpus; it buys concurrency with a shared image, so a suite
that mutates globals wants the default instead.

```beam-lisp silent
(defn files
  "A command's path arguments → the source files to run, in sorted order. A
   directory expands to the sources beneath it; no arguments means `test`.
   Public because it answers \"what would run?\" — a question a dashboard, a
   `--changed` mode and a test all ask without wanting to run anything."
  [args]
  (mapcat u/expand-targets (map u/resolve (if (empty? args) ["test"] args))))

(defn- totals
  "The suite's aggregate, from ward's per-file results."
  [result]
  (let [fs (:files result)]
    {:tests (reduce (fn [n f] (+ n (get-in f [:totals :tests] 0))) 0 fs)
     :pass  (reduce (fn [n f] (+ n (get-in f [:totals :pass] 0))) 0 fs)
     :fail  (reduce (fn [n f] (+ n (get-in f [:totals :fail] 0))) 0 fs)
     :error (reduce (fn [n f] (+ n (get-in f [:totals :error] 0))) 0 fs)
     :files (count fs)}))

(defn- sources [paths] (map (fn [p] (File/read! p)) paths))
```

## The verb

Report in both directions: ward's report for a human (a glyph line per file,
then the why of every failure), and the aggregate for a gate — `--json` for
anything reading the number rather than the picture.

```beam-lisp silent
(defn run-isolated
  "Run files through the isolated runner and report. Returns an exit code."
  [paths st]
  (BeamLisp.Loader/ensure_loaded "reload")
  (BeamLisp.Loader/ensure_loaded "reload.ward")
  (let [ward (BeamLisp.Env/fetch! "reload.ward" "run")
        report (BeamLisp.Env/fetch! "reload.ward" "report")
        result (ward (to-list (sources paths)))]
    (if (:json st)
      (u/emit st (assoc (totals result) :ok (get result :ok?)) nil)
      (println (report result)))
    (if (:ok? result) 0 1)))

(defn run-shared
  "The shared-image runner: one image, every file in it."
  [paths st]
  (let [totals (if (:json st)
                 (u/silent
                   (fn [] (BeamLisp.TestRT/run_suite (u/to-list paths) (u/kw [:async (:async st)]))))
                 (BeamLisp.TestRT/run_suite (u/to-list paths) (u/kw [:async (:async st)])))]
    (when (:json st)
      (u/emit st {:tests (get totals :tests) :pass (get totals :pass)
                  :fail (get totals :fail) :error (get totals :error)
                  :files (count paths)} nil))
    (if (BeamLisp.TestRT/passed? totals) 0 1)))

(defn run
  "`bl test [PATH...] [--shared] [--async] [--json]`. Isolated forks are the
   default: `ward`'s semantics, one runner, no second word to learn."
  [args st]
  (u/register-paths st)
  (let [paths (files args)]
    (if (empty? paths)
      (u/usage-error "bl test: no .bl test files found")
      (if (or (:shared st) (:async st))
        (run-shared paths st)
        (run-isolated paths st)))))
```
