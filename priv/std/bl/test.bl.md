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
  (let [ps (mapcat u/expand-targets (map u/resolve (if (empty? args) ["test"] args)))]
    (if (empty? args)
      ; No arguments means the CONVENTIONAL corpus — `test/**/*_test.bl` — the
      ; same rule ExUnit uses for `.exs`. 340 `.bl` files live under test/ and
      ; only 176 are tests: the rest are fixtures, and running a fixture as a
      ; suite is a failure with a misleading name.
      (filter (fn [p] (ends-with? p "_test.bl")) ps)
      ps)))

(defn- exs-under
  "The `*_test.exs` files under one path: a file contributes itself when that is
   what it is, a directory contributes what is beneath it. `files` above answers
   for `.bl` sources, whose expansion the loader owns; `.exs` is ExUnit's format,
   so it is discovered here and nowhere else."
  [p]
  (cond
    (File/regular? p) (if (ends-with? p "_test.exs") [p] [])
    (File/dir? p)
    (mapcat (fn [n] (exs-under (str p "/" n)))
            (filter (fn [n] (not (starts-with? n ".")))
                    (sort-by identity (File/ls! p))))
    :else []))

(defn exs-files
  "The `.exs` tests a command's arguments name, in sorted order."
  [args]
  (vec (sort (mapcat exs-under
                     (map u/resolve (if (empty? args) ["test"] args))))))

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

(defn- compile-test-support!
  "`test/support/*.ex` compiled into a scratch dir on the code path. Two suites
   ask it for helpers, and Mix used to compile it; with no Mix, the runner does."
  []
  (let [support (Path/wildcard "test/support/*.ex")]
    (when (not (empty? support))
      (let [out "/tmp/bl-test-support"]
        (File/mkdir_p! out)
        (Kernel.ParallelCompiler/compile_to_path
          (to-list support) out (list (erlang/list_to_tuple (list :return-diagnostics true))))
        (erlang/apply :code :add_patha (list (String/to_charlist out)))))))

(defn run-exunit
  "The `.exs` half: ExUnit on whatever Elixir is running this VM — the same
   framework `mix test` used, with no Mix underneath it.

   `test_helper.exs` runs first, because it is where ExUnit starts; it starts
   ExUnit with `autorun: false` so the only report is this run's. With `--json`
   the whole run is silenced and one object is emitted: a caller reading a number
   must not have to skip past a report.

   ExUnit keeps global state, so this runs AFTER the isolated `.bl` files, never
   between them."
  [paths st]
  (compile-test-support!)
  (let [run! (fn []
               (when (File/regular? "test/test_helper.exs")
                 (Code/require_file "test/test_helper.exs"))
               (start-exunit st)
               (u/each (fn [f] (Code/require_file f)) paths)
               (ExUnit/run))
        r (if (:json st) (u/silent run!) (run!))]
    (when (:json st)
      (u/emit st {:tests (:total r)
                  :pass (- (:total r) (:failures r))
                  :fail (:failures r)
                  :files (count paths)} nil))
    (if (= 0 (:failures r)) 0 1)))

(defn- start-exunit
  "`ExUnit.start` with the tag flags. Options must be a KEYWORD LIST, which in bl
   is a list of two-element tuples — a bl map would arrive as a struct and ExUnit
   would ignore it."
  [st]
  (let [inc (:include st)
        exc (:exclude st)
        opts (concat (list (erlang/list_to_tuple (list :autorun false)))
                     (if (nil? inc) [] [(erlang/list_to_tuple (list :include (to-list inc)))])
                     (if (nil? exc) [] [(erlang/list_to_tuple (list :exclude (to-list exc)))]))]
    (ExUnit/start (to-list opts))))

(defn run
  "`bl test [PATH...] [--shared] [--async] [--include TAG] [--json]`. Both halves
   of the suite, in one command and with no Mix: `.bl` files through `ward`
   (isolated forks are the default; one runner, no second word to learn), `.exs`
   files through ExUnit."
  [args st]
  (u/register-paths st)
  (let [bls (files args)
        exs (exs-files args)]
    (cond
      (and (empty? bls) (empty? exs)) (u/usage-error "bl test: no test files found")
      :else
        (let [a (if (empty? bls)
                  0
                  (if (or (:shared st) (:async st))
                    (run-shared bls st)
                    (run-isolated bls st)))
              b (if (empty? exs) 0 (run-exunit exs st))]
          (if (= 0 (+ a b)) 0 1)))))
```
