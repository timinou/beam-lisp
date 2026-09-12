# bl.doctor — the environment report

`bl doctor` answers the first question a machine raises: what can this host
actually do? A native tier that is absent, a solver binary that is missing, a
daemon that is not running — each is a fact about the environment,
not a defect in the program about to run. The command collects those facts in
one place, so a user learns them from the tool instead of from a stack trace.

The report is a flat list of probes. A probe is a name, an honest yes/no, and a
line of detail; the detail is what a person acts on — a version, a count, the
reason a native is absent. Nothing here halts. A missing NIF must read as
`false`, never as a crash, and the exit code summarizes the probes rather than
an exception.

Two probes are REQUIRED: the language evaluates, and the LazyMemo fast lane
answers. A build without them is not a working beam-lisp. Every other probe
reports an optional capability, so an absent native is a line in the table and
still exits 0.

```beam-lisp
(ns bl.doctor
  (:require [bl.util :as u]))
```

## A probe never crashes

`probe` is the whole safety story. A NIF that did not load raises
`:nif_not_loaded` the moment it is called; here that raise becomes a result
map with `ok=false` and the message as the detail. The report is therefore
total: every probe contributes a line, whatever the host is missing.

`probes` is the only place that knows which facts matter, and each fact is a
small function of its own. `:required` marks the two that must pass.

```beam-lisp
(defn- why
  "A caught value as one line: an exception's message, else its printed form."
  [e]
  (or (ex-message e) (pr-str e)))

(defn probe
  "Run one probe. `f` returns `{:ok bool :detail str}`. Any raise becomes
   `ok=false` with the reason as the detail, so a missing native is a report
   line and never a crash."
  [name required? f]
  (try
    (let [r (f)]
      {:name name
       :ok (boolean (get r :ok))
       :detail (str (or (get r :detail) ""))
       :required required?})
    (catch e
      {:name name :ok false :detail (why e) :required required?})))

(defn- as-text
  "An Erlang string (a charlist) or a binary as a binary."
  [x]
  (if (string? x) x (erlang/list_to_binary x)))

(defn- native-line
  "The detail for a native tier: loaded, or absent with its reason implied —
   the tier is optional, so absence is a fact and not a failure."
  [ok?]
  (if ok? "loaded" "absent (optional)"))

(defn- native-tier
  "Whether the native tier behind `expr` loaded. `expr` is evaluated fresh —
   the same expression a program writes — so the probe reports what a caller
   sees rather than a compile-time artifact of this file."
  [expr]
  (BeamLisp/eval expr))
```

## The probes

The probes read in dependency order: the runtime, the loader's view of the
disk, the native tiers, the solver, the GUI backend, the daemon, then the
checkout's own markers.

`--code-path` directories matter because Mix prunes the VM code path when the
project loads; `code/get_path` is the honest count of what a program can
actually load. `search-paths` is the loader's own list of extra roots.

The daemon probe asks the tree's socket whether a warm VM answers for this
checkout. A daemon that is not running is the normal state of a standalone
invocation, so it reports `not running` and changes nothing.

```beam-lisp
(defn probes
  "Every fact `bl doctor` reports, in reading order. `:required` marks the
   probes whose failure is a broken beam-lisp rather than a missing optional."
  []
  [(probe "language" true
     (fn []
       (let [v (BeamLisp/eval "(+ 1 2)")]
         {:ok (= 3 v) :detail (str "(+ 1 2) → " v)})))

   (probe "otp" false
     (fn [] {:ok true :detail (as-text (erlang/system_info :otp_release))}))

   (probe "elixir" false
     (fn [] {:ok true :detail (System/version)}))

   (probe "beam-lisp" false
     (fn [] {:ok true :detail (u/version)}))

   (probe "search-paths" false
     (fn [] {:ok true :detail (u/plural (count (BeamLisp.Env/search_paths)) "root")}))

   (probe "code-paths" false
     (fn [] {:ok true :detail (u/plural (count (code/get_path)) "dir")}))

   (probe "datom_fjall" false
     (fn [] (let [ok? (native-tier "(datom.store-fjall/available?)")]
              {:ok ok? :detail (native-line ok?)})))

   (probe "explorer" false
     (fn [] (let [ok? (datom.frame/available?)]
              {:ok ok? :detail (native-line ok?)})))

   (probe "lazy_memo" true
     (fn [] (let [n (BeamLisp.LazyMemo/fast_lane_bytes)]
              {:ok (int? n) :detail (str n " bytes fast lane")})))

   (probe "z3" false
     (fn [] (let [p (z3/open)
                  r (z3/check p "(assert true)")]
              {:ok (= "sat" r) :detail (pr-str r)})))

   (probe "wry" false
     (fn [] (let [ok? (native-tier "(wry/available?)")]
              {:ok ok? :detail (native-line ok?)})))

   (probe "daemon" false
     (fn []
       (let [[tag detail] (BeamLisp.Daemon/probe (BeamLisp/cwd))]
         (if (= :ok tag)
           {:ok true :detail "running (warm VM for this tree)"}
           {:ok false :detail (str "not running (" (pr-str detail) ")")}))))

   (probe "src/" false
     (fn [] (let [ok? (File/dir? (u/resolve "src"))]
              {:ok ok? :detail (if ok? "present" "absent")})))

   (probe ".bl-check.edn" false
     (fn [] (let [ok? (File/regular? (u/resolve ".bl-check.edn"))]
              {:ok ok? :detail (if ok? "present" "absent (run `bl check --update`)")})))

   (probe ".blanalysis/" false
     (fn [] (let [ok? (File/dir? (u/resolve ".blanalysis"))]
              {:ok ok? :detail (if ok? "present" "absent (created by the first codebase read)")})))])
```

## The report

The table is two fixed columns and a detail: `ok` or `--`, the name padded to
the longest one, then the fact. The verdict line says whether the required
probes passed and how many optional ones are absent, so the count of missing
natives is visible without reading every row.

```beam-lisp
(defn render
  "The human report: one aligned line per probe, then the verdict. The detail
   carries the reason, so `--` is a fact and not a mystery."
  [d]
  (let [ps (:probes d)
        w  (reduce (fn [m p] (max m (count (:name p)))) 8 ps)
        line (fn [p]
               (str "  " (if (:ok p) "ok" "--") "   "
                    (String/pad_trailing (:name p) w) "  " (:detail p)))
        required (filter (fn [p] (:required p)) ps)
        failed (filter (fn [p] (and (:required p) (not (:ok p)))) ps)
        absent (count (filter (fn [p] (and (not (:required p)) (not (:ok p)))) ps))]
    (join "\n"
      (concat
        ["beam-lisp doctor" ""]
        (map line ps)
        [""]
        (if (:ok d)
          [(str "  ✓ " (u/plural (count required) "required probe") " ok; "
                (if (> absent 0) (str absent " optional absent") "every optional present"))]
          [(str "  ✗ required probes failing: "
                (join ", " (map (fn [p] (:name p)) failed)))])))))
```

## The command

`run` glues: collect the probes, decide the verdict, print, and hand back an
exit code. The text printer and the JSON printer read the same value, so
`--json` is one object with the same facts.

```beam-lisp
(defn run
  "`bl doctor [--json]`. Every probe runs; the exit code is 0 when the required
   probes pass, 1 otherwise. An absent optional native is reported, never
   failed."
  [args st]
  (if (empty? args)
    (do (u/register-paths st)
        (let [ps  (probes)
              bad (filter (fn [p] (and (:required p) (not (:ok p)))) ps)
              d   {:ok (empty? bad) :probes ps}]
          (u/emit st d render)
          (if (:ok d) 0 1)))
    (u/usage-error "usage: bl doctor [--json]")))
```
