# bl.check — the gate that says a change did not regress the proofs

`bl check` is the one command a developer runs before committing, and the one
a git hook runs for them. It reads every source, measures it with the
compiler's own analyses, compares the measurement against a committed
baseline, and answers one question: **is anything worse than the baseline?**

The measurement per file:

- **diagnostics** — the warnings the compiler and its engines produce
  (`lsp/diagnostics`).
- **smells** — the default deodorant set, safe + idiomatic (`bl lint`'s count).
- **functions** — every top-level definition, with the facts the compiler
  PROVED about it: is it pure? does it terminate? what does it return? is it
  native-eligible? A function is native-eligible when it is pure AND
  terminating — the two theorems that make a native offload sound — so the
  count is derived from the same summary the other two badges read.

The baseline lives in `.bl-check.edn`, keyed by path relative to the command's
cwd. It is meant to be committed: it is the record of the accepted state, and
a reviewer sees a regression when this file and the code disagree. The file
holds the aggregate metrics, each source's sha256 (so `--changed` can tell
which sources moved), and the NAMES of the pure, terminating and
native-eligible functions (so a lost proof names the function that lost it).

The regression rule, applied per file:

- more diagnostics than the baseline → fail;
- more smells than the baseline → fail;
- a file the baseline parses and the run does not → fail;
- a function the baseline records as pure, terminating or native-eligible that the run does not →
  fail, named.

Improvements never fail. `--update` records the current state as the new
baseline. With no baseline at all, `bl check` prints the metrics and tells you
to create one; that first run is a measurement, not a verdict.

```beam-lisp
(ns bl.check
  (:require [bl.util :as u] [bl.lint :as lint] [bl.fix :as fix] [deodorant] [lsp]))
```

## Which sources a check reads

A directory argument expands to every loader source beneath it. A build
output, a dependency checkout, vendored research and test fixtures are not
the project's own source, so the walk skips them: a gate measures the code
you own.

```beam-lisp
(def baseline-name
  "The committed baseline, at the command's cwd."
  ".bl-check.edn")

(defn- skipped-path?
  "A path a check never reads: build output, dependencies, vendored research,
   the git directory, and test fixtures."
  [p]
  (or (some (fn [seg] (includes? p (str "/" seg "/")))
            ["_build" "deps" "research" ".git"])
      (includes? p "/test/fixtures/")))

(defn collect-paths
  "Expand PATH arguments into the sources a check reads, in order, dropping the
   directories a gate never looks at."
  [args]
  (into [] (filter (fn [p] (not (skipped-path? p)))
                   (mapcat u/expand-targets (map u/resolve args)))))
```

## One source, every proven fact

`analyze-source` produces one file's metrics. The namespace comes from the
leading `(ns …)` form — the reader's own convention, shared with `bl lsp`.
A source the compiler cannot parse is not an error here: it is a metric,
`:unreadable true`, which the regression rule treats as a failure the moment
it appears where the baseline records a readable file.

The eligible count is the conjunction of the two badges rather than a second
call into `lsp/native-eligible`: that function answers exactly `pure ∧
terminates` for a function, and reading it off the two facts already in hand
keeps the cost one analysis per file instead of one per function.

```beam-lisp
(defn sha256
  "The lowercase hex sha256 of `s` (core `sha256-hex`) — a source's content identity, recorded in
   the baseline so `--changed` can select what moved."
  [s]
  (sha256-hex s))

(defn- fn-facts
  "One top-level definition's proven facts: name, purity, termination, its
   return tagset, and native-eligibility (pure ∧ terminates)."
  [s]
  (let [pure (:pure s)
        terminates (:terminates s)]
    {:name (:name s)
     :pure pure
     :terminates terminates
     :returns (:returns s)
     :eligible (and pure terminates)}))

(defn- unreadable-metrics
  "The metrics of a source the compiler cannot read or parse: zero counts and
   `:unreadable true`, which the regression rule treats as a failure."
  [path digest]
  {:path path :sha digest :unreadable true
   :diagnostics 0 :smells 0 :fns 0 :pure 0 :terminates 0 :eligible 0
   :pure-fns [] :terminates-fns [] :eligible-fns [] :fn-info []})

(defn analyze-source
  "The metrics for one source text: diagnostics, smells, and the per-function
   facts. `:unreadable true` when the compiler cannot parse the text; the
   counts are then zero and the file is a failure on its own."
  [path src]
  (let [digest (sha256 src)]
    (try
      (let [ns (u/ns-of src)
            fns (into [] (map fn-facts (lsp/document-symbols src)))
            with (fn [k] (into [] (map (fn [f] (:name f)) (filter (fn [f] (get f k)) fns))))]
        {:path path :sha digest :unreadable false
         :diagnostics (count (lsp/diagnostics src ns))
         :smells (lint/smell-count (deodorant/all-rules) src)
         :fns (count fns)
         :pure (count (filter (fn [f] (:pure f)) fns))
         :terminates (count (filter (fn [f] (:terminates f)) fns))
         :eligible (count (filter (fn [f] (:eligible f)) fns))
         :pure-fns (with :pure)
         :terminates-fns (with :terminates)
         :eligible-fns (with :eligible)
         :fn-info fns})
      (catch _ (unreadable-metrics path digest)))))

(defn- source-metrics
  "Read one path and measure it. A file that cannot be read at all is a metric,
   never a crash: the gate must survive the one bad file among a thousand."
  [p]
  (try
    (analyze-source (u/rel-path p) (BeamLisp.Loader/read_source p))
    (catch _ (unreadable-metrics (u/rel-path p) nil))))

(defn- sum-by [k files]
  (reduce + 0 (map (fn [f] (get f k)) files)))

(defn analyze-paths
  "Analyze every path: `{:files [...] :metrics {...}}`. The metrics are the
   aggregate a baseline records."
  [paths]
  (let [files (into [] (map source-metrics paths))]
    {:files files
     :metrics {:files (count files)
               :fns (sum-by :fns files)
               :pure (sum-by :pure files)
               :terminates (sum-by :terminates files)
               :eligible (sum-by :eligible files)
               :diagnostics (sum-by :diagnostics files)
               :smells (sum-by :smells files)
               :unreadable (count (filter (fn [f] (:unreadable f)) files))}}))
```

## The baseline on disk

The baseline is the accepted metrics plus the per-file facts a regression is
named from. It is written with `pr-str` and read back with the compiler's own
data reader — the same shapes on both sides — and each path key is relative to
the command's cwd, so the file survives a move to another checkout.

```beam-lisp
(defn baseline-of
  "The value written to `.bl-check.edn`: the aggregate metrics and, per source,
   its sha, diagnostics, smell count, unreadable flag, and the NAMES of its
   pure, terminating and eligible functions."
  [report]
  {:version 1
   :metrics (:metrics report)
   :files (reduce (fn [m f]
                    (assoc m (:path f)
                           (select-keys f [:sha :diagnostics :smells :unreadable
                                           :pure-fns :terminates-fns :eligible-fns])))
                  {} (:files report))})

(defn read-baseline
  "The baseline map at `path`, or nil when the file is absent or unreadable."
  [path]
  (when (File/exists? path)
    (try (first (BeamLisp.Compiler/read_all_data (File/read! path))) (catch _ nil))))

(defn write-baseline!
  "Write `report` as the committed baseline at `path`."
  [path report]
  (File/write! path (str (pr-str (baseline-of report)) "\n")))
```

## The regression rule

Per file. Comparing a subset against the whole would invent regressions the
moment `--changed` analyzes fewer files, so a file absent from the report is
never compared — this run does not measure it. A file the baseline
does not know is measured against zero: a brand-new file that arrives with
diagnostics or smells fails the gate, and it has no proofs to lose yet.

```beam-lisp
(defn- lost
  "The names in `before` that are absent from `after`."
  [before after]
  (let [s (set after)]
    (into [] (filter (fn [n] (not (contains? s n))) before))))

(defn file-regressions
  "The named regressions in one file: a diagnostics count up, a smell count up,
   an unreadable file the baseline reads, and any function that lost a proof.
   A nil `base` is a file the baseline does not know — measured against zero."
  [base now]
  (let [path (:path now)
        base (or base {:diagnostics 0 :smells 0 :unreadable false
                       :pure-fns [] :terminates-fns [] :eligible-fns []})
        named (fn [kind names] (str "✗ " kind " lost: " (join ", " names) " (" path ")"))
        pure (lost (:pure-fns base) (:pure-fns now))
        terminates (lost (:terminates-fns base) (:terminates-fns now))
        eligible (lost (:eligible-fns base) (:eligible-fns now))]
    (into []
          (concat
           (if (> (:diagnostics now) (:diagnostics base))
             [(str "✗ diagnostics " (:diagnostics base) " → " (:diagnostics now) " (" path ")")] [])
           (if (> (:smells now) (:smells base))
             [(str "✗ smells " (:smells base) " → " (:smells now) " (" path ")")] [])
           (if (and (:unreadable now) (not (:unreadable base)))
             [(str "✗ unreadable (" path ")")] [])
           (if (empty? pure) [] [(named "pure" pure)])
           (if (empty? terminates) [] [(named "terminates" terminates)])
           (if (empty? eligible) [] [(named "eligible" eligible)])))))

(defn regressions
  "Every named regression of `report` against `base`, in file order."
  [base report]
  (let [known (:files base)]
    (into [] (mapcat (fn [f] (file-regressions (get known (:path f)) f))
                     (:files report)))))
```

## `--changed` selects by content

`system.incr` re-proves only the functions whose body changed, but it holds no
source-path index a command can ask. The baseline already records each
source's sha256, so the honest and cheap selector is the content of the file:
a source is changed when its sha differs from the recorded one, or when the
baseline has never seen it. Selecting by content is also more accurate than a
`git diff` — an edit made and undone reads as unchanged, which is the truth a
gate wants.

```beam-lisp
(defn- content-sha
  "The sha256 of a source's loadable content, or nil when the file cannot be
   read at all — a nil never matches a recorded sha, so the file counts as
   changed and the analysis reports it as unreadable."
  [p]
  (try (sha256 (BeamLisp.Loader/read_source p)) (catch _ nil)))

(defn changed-paths
  "The paths whose content differs from the baseline's recorded sha, or that the
   baseline does not know. The selector `bl check --changed` uses."
  [base paths]
  (let [known (:files base)]
    (into [] (filter (fn [p]
                       (let [e (get known (u/rel-path p))]
                         (or (nil? e) (not= (:sha e) (content-sha p)))))
                     paths))))
```

## The hook

`--install-hook` writes the one-line git hook that runs the gate over what
changed. It is idempotent: running it again writes the same file.

```beam-lisp
(defn install-hook
  "Write `.git/hooks/pre-commit` to run `bl check --changed`, executable. Idempotent
   — running it again writes the same line. A pre-commit hook that is not this
   one is left alone and reported, so installing never destroys a hook someone
   else put there. Returns the exit code."
  [st]
  (let [dir (u/resolve ".git/hooks")
        path (str dir "/pre-commit")]
    (cond
      (not (File/dir? dir))
      (u/usage-error "bl check: no .git/hooks directory here — run this inside a git checkout")

      (and (File/exists? path) (not (includes? (File/read! path) "bl check")))
      (do (u/io-err (str "bl check: " path " exists and is not a bl check hook — merge it by hand"))
          1)

      :else
      (do (File/write! path "#!/bin/sh\nexec bl check --changed\n")
          (File/chmod path 493)
          (u/emit st {:path path :installed true} (fn [r] (str "installed " (:path r))))
          0))))
```

## The report

One metrics line per file, then the no-baseline note when there is none, then
each named regression, then the verdict.

```beam-lisp
(defn- file-line
  "One file's metrics, as `path  diags=N smells=N fns=N pure=N eligible=N`."
  [f]
  (str (:path f) "  diags=" (:diagnostics f) " smells=" (:smells f)
       " fns=" (:fns f) " pure=" (:pure f) " eligible=" (:eligible f)))

(defn render
  "The human report: a metrics line per file, the note when there is no
   baseline, every regression, then the verdict."
  [report]
  (let [note (if (:note report) [(:note report)] [])
        regs (:regressions report)
        verdict (if (:ok report) "ok" (str "✗ " (u/plural (count regs) "regression")))]
    (join "\n" (concat (map file-line (:files report)) note regs [verdict]))))
```

## The command

`run` resolves the targets, optionally repairs the safe smells first, selects
the sources to analyze, and compares. `--update` analyzes everything and writes
the baseline; with no baseline the run is a measurement; otherwise the exit
code carries the verdict.

```beam-lisp
(defn run
  "`bl check [PATH…] [--changed] [--update] [--fix] [--json] [--install-hook]`.
   Exit 0 when nothing regressed, 1 when something did, 2 on a usage error."
  [args st]
  (u/register-paths st)
  (if (:install-hook st)
    (install-hook st)
    (let [targets (if (empty? args) ["."] args)
          paths (collect-paths targets)]
      (if (empty? paths)
        (u/usage-error "bl check: no source files found")
        (do
          ;; --fix first, safe tier only: repair the mechanical smells, then
          ;; measure what remains. A file the fixer cannot read is reported and
          ;; the check continues.
          (when (:fix st)
            (let [fixed (fix/fix-paths (lint/tier-rules "safe") paths)]
              (u/each (fn [f] (u/io-err (str "bl check --fix: " (:path f) ": " (:error f))))
                      (:failed fixed))))
          (let [baseline-path (u/resolve baseline-name)
                base (read-baseline baseline-path)
                selected (cond
                           (:update st) paths
                           (:changed st) (if (nil? base) paths (changed-paths base paths))
                           :else paths)
                report (analyze-paths selected)]
            (cond
              (:update st)
              (do (write-baseline! baseline-path report)
                  (u/emit st (assoc report :updated true :ok true :regressions [])
                          (fn [r] (str "wrote " (u/rel-path baseline-path)
                                       " (" (count (:files r)) " files)")))
                  0)

              (nil? base)
              (do (u/emit st (assoc report :ok true :regressions []
                                    :note "no baseline: run bl check --update to create .bl-check.edn")
                          render)
                  0)

              :else
              (let [regs (regressions base report)
                    ok (empty? regs)]
                (u/emit st (assoc report :ok ok :regressions regs) render)
                (if ok 0 1)))))))))
