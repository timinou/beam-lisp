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
disk, the native tiers, the solver, the GUI backend, the daemon, the embedding
weights, then the checkout's own markers.

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

   (probe "code_embed" false
     (fn [] (let [ok? (native-tier "(code.embed/nif?)")]
              {:ok ok? :detail (native-line ok?)})))

   (probe "lazy_memo" true
     (fn [] (let [n (BeamLisp.LazyMemo/fast_lane_bytes)]
              {:ok (int? n) :detail (str n " bytes fast lane")})))

   (probe "z3" false
     (fn [] (let [p (z3/open)
                  r (z3/check p "(assert true)")]
              ;; The solver answers with a STATUS MAP on the oracle tier and a
              ;; bare string on the older port; a probe that accepted only one
              ;; shape reported a working solver as absent (measured: `--` beside
              ;; a `:status :sat`).
              {:ok (= :sat (if (map? r) (:status r) r)) :detail (pr-str r)})))

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

   (probe ".local/bl/cache/" false
     (fn [] (let [forced (System/get_env "BL_CACHE_DIR")
                  dir (if (nil? forced)
                        (u/resolve ".local/bl/cache")
                        (Path/expand forced (BeamLisp/cwd)))
                  ok? (File/dir? dir)]
              {:ok ok?
               :detail (cond
                         (and (some? forced) ok?) (str "present (" dir " — BL_CACHE_DIR)")
                         (some? forced) (str dir " (BL_CACHE_DIR; created on first use)")
                         ok? "present"
                         :else "absent (created by the first codebase read)")})))

   ; The embedding weights are the one asset a program needs BEFORE it can run
   ; (`bl search` reads them on first use), and they can arrive three ways: this
   ; `bl` may carry them, the machine's cache may hold them, or the caller pinned
   ; a directory. Which one answered is the fact worth reporting — "present"
   ; alone would hide a drop built `--no-embed` that is silently degraded.
   (probe "embedding" false
     (fn []
       (let [m    (BeamLisp/eval "code.embed/MODEL")
             tier (BeamLisp.Model/tier m)
             dir  (BeamLisp.Model/dir m)]
         (case tier
           :bundled {:ok true :detail (str "present (bundled: " dir ")")}
           :env     {:ok true :detail (str "present (BEAM_LISP_MODEL_DIR: " dir ")")}
           :ambient {:ok true :detail (str "present (fetched into the cache: " dir ")")}
           {:ok false
            :detail (str "absent — `bl search` needs it; looked in "
                         (join ", " (BeamLisp.Model/searched_dirs m)))}))))])
```

## The deep probes

`--deep` asks a different question. The probes above are about the HOST — can
this machine run a beam-lisp? The deep probes are about the TOOLCHAIN: does this
`bl` need Mix, what is left of Mix in the tree, is the dependency declaration
intact, what kind of image is this, was the bootstrap floor built by this
toolchain, and does the library store hold what the lock names. A user asking
whether their program can run should not have to read any of it, which is why it
is opt-in.

`mix` is REQUIRED here and passes when Mix is ABSENT: this is the one place the
deletion is observable, and a `bl` that needed Mix would be the failure the whole
programme exists to remove. Residue is reported and NOT required — `mix.exs`,
`mix.lock`, `lib/mix/tasks/` and `deps/` stay until a locked library can be
compiled onto the code path without Mix (FUP-050), and a REQUIRED probe this
repository cannot pass would be a probe that lies about the tree it is reporting
on. It says what is left and why, which is the fact a reader acts on.

Nothing here infers an answer it could read. The image kind is asked
(`BeamLisp.Image/kind`, the one implementation), the floor's provenance is read
from the manifest the floor shipped with (`Bootstrap/manifest`), and the seed's
verdict is `Bootstrap/key_matches?/1` rather than a second copy of the rule.

```beam-lisp
(defn- mix-loaded?
  "Whether the Elixir build tool is RUNNING in this VM. Not a signal this
   toolchain needs — `BeamLisp.Image/kind` answers the questions that used to be
   asked of Mix — but the honest answer to \"does this `bl` depend on Mix?\".

   RUNNING, not loadable, and the difference is the whole probe: `mix/ebin` ships
   with Elixir and sits on the code path of any Elixir VM, so asking whether the
   module can be loaded answers yes under `bl` too — measured, and it made this
   required probe fail in the image it exists to clear. What means \"this build
   depends on Mix\" is that Mix is STARTED.

   The module is named as a STRING and turned into an atom: `Elixir.Mix` written
   as a bare symbol is a var this compiler resolves at compile time, and with no
   Mix in the image that resolution fails — the probe reported `undefined var:
   bl.doctor/Elixir.Mix` (measured) instead of the fact it exists to report. A
   question about a module that may not be there cannot require it to be there."
  []
  (Enum/any? (Application/started_applications)
             (fn [t] (= :mix (erlang/element 1 t)))))

(defn- residue
  "What is left of Mix in this tree, as named pieces. A directory is named with
   its file count, because `lib/mix/tasks (6 files)` is a different fact from
   `lib/mix/tasks (0 files)`."
  []
  (let [files (filter (fn [p] (File/regular? p)) ["mix.exs" "mix.lock"])
        tasks (if (File/dir? "lib/mix/tasks")
                (count (Path/wildcard "lib/mix/tasks/*.ex"))
                0)]
    (concat files
            (if (> tasks 0) [(str "lib/mix/tasks (" tasks " files)")] [])
            (if (File/dir? "deps") ["deps/"] []))))

(defn- lock-line []
  (let [p "bl.lock"]
    (if (not (File/exists? p))
      {:ok false :detail "absent (no bl.lock in this tree)"}
      (let [n (count (filter (fn [l] (includes? l "[:dep "))
                             (String/split (File/read! p) "\n")))]
        {:ok true :detail (str n " declared")}))))

(defn- store-line
  "What the store holds against what the lock names. The `deps` namespace is
   loaded on demand, because a namespace that is not in this image is a fact to
   report and not a reason to fail."
  []
  (do (BeamLisp.Loader/ensure_loaded "deps")
      (let [r (BeamLisp.RT/invoke (BeamLisp.Env/fetch! "deps" "verify")
                                  (list (BeamLisp/cwd)))]
        (if (:ok? r)
          {:ok true :detail (str (:checked r) " locked, all present offline")}
          {:ok false :detail (str (:checked r) " locked, " (count (:missing r))
                                  " missing (run `bl deps fetch`)")}))))

(defn- seed-line
  "The bootstrap floor's identity: which toolchain built the beams a
   genesis-less tree boots from. A floor built by another toolchain is reported
   as such — booting from it is how a stale floor turns into a compiler that
   disagrees with its own sources."
  []
  (let [m (BeamLisp.Bootstrap/manifest)]
    (if (nil? m)
      {:ok false :detail "absent (no priv/bootstrap/seed/manifest.exs)"}
      (let [n (count (keys (get m "modules")))
            ok? (BeamLisp.Bootstrap/key_matches? m)]
        {:ok ok?
         :detail (if ok?
                   (str n " beams, built by this toolchain")
                   (str n " beams, built by ANOTHER toolchain (codegen "
                        (subs (get m "compiler_key") 0 12) "… vs "
                        (subs (BeamLisp.AOTCache/current_compiler_key) 0 12)
                        "…) — reseed with `bl seed`"))}))))

(defn- image-line []
  (let [k (BeamLisp.Image/kind)]
    {:ok true
     :detail (str k
                  (if (BeamLisp.Image/mutable?)
                    " (mutating reloads allowed)"
                    " (reloads refuse to mutate in place)"))}))

(defn deep-probes
  "The toolchain's own facts, in reading order — `bl doctor --deep`. `mix` is the
   only required one, and it passes when Mix is ABSENT."
  []
  [(probe "mix" true
     (fn [] (if (mix-loaded?)
              {:ok false :detail "loaded in this VM (bl itself does not need it)"}
              {:ok true :detail "absent — nothing here asks for it"})))

   (probe "mix-residue" false
     (fn [] (let [r (residue)]
              {:ok (empty? r)
               :detail (if (empty? r)
                         "none — no mix.exs, no mix.lock, no lib/mix, no deps/"
                         (str (join ", " r)
                              " — Mix residue; this toolchain does not need it"))})))

   (probe "bl.lock" false
     (fn [] (lock-line)))

   (probe "store" false
     (fn [] (store-line)))

   (probe "seed" false
     (fn [] (seed-line)))

   (probe "image" false
     (fn [] (image-line)))])
```

## The report

The table is two fixed columns and a detail: `ok` or `--`, the name padded to
the longest one, then the fact. The verdict line says whether the required
probes passed and how many optional ones are absent, so the count of missing
natives is visible without reading every row.

```beam-lisp
(defn render
  "The human report: one aligned line per probe, then the verdict. The detail
   carries the reason, so `--` is a fact and not a mystery. The title names the
   question that was asked, because a deep report's rows answer a different one."
  [d]
  (let [ps (:probes d)
        title (if (:deep d) "beam-lisp doctor --deep" "beam-lisp doctor")
        w  (reduce (fn [m p] (max m (count (:name p)))) 8 ps)
        line (fn [p]
               (str "  " (if (:ok p) "ok" "--") "   "
                    (String/pad_trailing (:name p) w) "  " (:detail p)))
        required (filter (fn [p] (:required p)) ps)
        failed (filter (fn [p] (and (:required p) (not (:ok p)))) ps)
        absent (count (filter (fn [p] (and (not (:required p)) (not (:ok p)))) ps))]
    (join "\n"
      (concat
        [title ""]
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
  "`bl doctor [--deep] [--json]`. Every probe runs; the exit code is 0 when the
   required probes pass, 1 otherwise. An absent optional native is reported, never
   failed; `--deep` adds the toolchain's own facts — where Mix is absent, that is
   a PASS, and where it is still present, that is reported as the residue it is
   until the dependency path no longer needs it (FUP-050)."
  [args st]
  (if (empty? args)
    (do (u/register-paths st)
        (let [ps  (concat (probes) (if (:deep st) (deep-probes) []))
              bad (filter (fn [p] (and (:required p) (not (:ok p)))) ps)
              d   {:ok (empty? bad) :probes ps :deep (boolean (:deep st))}]
          (u/emit st d render)
          (if (:ok d) 0 1)))
    (u/usage-error "usage: bl doctor [--deep] [--json]")))
```
