# bl.override — vendoring and patching the beam-lisp you run

The `.bl` the compiler ships — the toolchain in `boot/`, the stdlib in
`std/`, the batteries in `lib/`, the Clojure compat layer in `compat/` — is
on every tree's search path by default; no `--path` flag, no configuration.
That is what makes it *overridable*: the loader's search order is

```
pushed  >  cwd  >  env.bl :paths / BEAM_LISP_PATH  >  priv tiers
```

so a project file whose declared namespace matches already shadows the
shipped one. This verb turns that property into a workflow:

```
bl override vendor NS...    copy a shipped namespace into overrides/ to edit it
bl override apply PATCH.bl  run a patch program — verified, rolled back on failure
bl override list            what this tree overrides, and whether it drifted
bl override diff NS         the override against the shipped source
bl override revert NS...    drop an override, back to shipped
```

Two use cases, two mechanisms:

- **Vendor** (fix a bug): the shipped file lands in this tree's
  `overrides/` directory — mirrored against the tier roots, so
  `clojure.edn` becomes `overrides/clojure/edn.bl` — and `with-project`
  puts `overrides/` on the search path for every command, ahead of `priv`.
  Edit the copy; every `bl run` / `bl test` in the tree sees it.
- **Apply** (lastingly add a feature a package needs): the patch is a
  *program*, not a diff — beam-lisp source that receives the shipped source
  plus the **codebase database** (every definition and call of every tier,
  as datalog facts) and returns the new sources. A patch that names no
  line numbers cannot rot silently against a drifting upstream: it *finds*
  its targets by structure and *raises* when they are gone.

Every applied override is verified before it lands, and landing is
all-or-nothing:

- **logical, implicit** — the compiler's own analysis (`lsp/diagnostics`,
  the proof-backed one `bl lsp check` prints) must be clean on each new
  source, and each overridden namespace must load in an isolated env.
- **unit, implicit** — the shipped test files that require each touched
  namespace (found in the checkout's `test/` tree) must pass *against the
  override*.
- **unit, explicit** — the tests the patch ships must pass.

Any failure rolls every written file back and exits `1`: a patch that
breaks what it touches does not get to stay.

```beam-lisp
(ns bl.override
  (:require [bl.util :as u] [bl.ask] [typed] [codebase]))
```

## Where the shipped source lives

A namespace's shipped file is `<tier-dir>/<ns with dots as slashes><ext>`,
trying each tier dir and each document extension in order — the same
resolution the loader's `find_file` performs, read from the same tables
(`BeamLisp.Tiers/dirs`, `BeamLisp.Loader/doc_extensions`) so this verb can
never disagree with the loader about where a namespace comes from.

```beam-lisp
(defn- ns->base [ns] (String/replace ns "." "/"))

(defn shipped-file
  "The shipped source of namespace `ns`: {:path :ext}, or nil when no tier
   ships it."
  [ns]
  (let [base (ns->base ns)
        dirs (u/to-list (BeamLisp.Tiers/dirs))
        exts (u/to-list (BeamLisp.Loader/doc_extensions))]
    (first
     (filter some?
             (for [d dirs e exts]
               (let [p (str d "/" base e)]
                 (if (File/regular? p) {:path p :ext e} nil)))))))

(defn overrides-dir
  "This tree's overrides directory (whether or not it exists yet)."
  []
  (u/resolve "overrides"))

(defn- override-path
  "Where namespace `ns` lives (or would live) under overrides/, as a plain
   `.bl` file: transformed sources are always plain source."
  [ns]
  (str (overrides-dir) "/" (ns->base ns) ".bl"))
```

## vendor — copy a namespace down to edit it

Vendoring is deliberately a *copy*, not a move: the shipped file stays
untouched, the copy wins by search order, and `revert` is a delete. The
copy lands byte-identical — a vendor with no edit applied is a no-op
override, which `list` reports as `:identical`.

```beam-lisp
(defn- vendor-one
  "Copy the shipped source of `ns` into overrides/. Returns :ok, or prints
   why not and returns :error."
  [ns]
  (let [dst (override-path ns)]
    (cond
      (File/exists? dst)
      (do (u/io-err (str "bl override: " ns " is already vendored at " dst
                         " — edit it there, or `bl override revert " ns "` first"))
          :error)

      :else
      (let [f (shipped-file ns)]
        (if (nil? f)
          (do (u/io-err (str "bl override: no shipped namespace \"" ns "\" (searched the tier dirs)"))
              :error)
          (do (File/mkdir_p (u/dirname dst))
              (File/write! dst (File/read! (:path f)))
              (println (str "vendored " ns))
              (println (str "  from  " (:path f)))
              (println (str "  to    " dst "  (shadows the shipped file; edit freely)"))
              :ok))))))

(defn- cmd-vendor [args]
  (if (empty? args)
    (u/usage-error "usage: bl override vendor NS...")
    (let [results (map vendor-one (u/to-list args))]
      (if (some (fn [r] (= :error r)) results) 1 0))))
```

## list · diff · revert — seeing and undoing what a tree shadows

```beam-lisp
(defn- override-files
  "Every plain `.bl` file under overrides/, sorted."
  []
  (let [d (overrides-dir)]
    (if (File/dir? d)
      (sort (u/to-list (Path/wildcard (str d "/**/*.bl"))))
      [])))

(defn- rel->ns [rel] (String/replace (String/replace rel ".bl" "") "/" "."))

(defn- cmd-list [_args]
  (let [files (override-files)]
    (if (empty? files)
      (do (println "no overrides/ in this tree") 0)
      (do
        (u/each
         (fn [p]
           (let [rel (String/replace p (str (overrides-dir) "/") "")
                 ns (rel->ns rel)
                 f (shipped-file ns)
                 status (cond
                          (nil? f) "added (no shipped counterpart)"
                          (= (File/read! p) (File/read! (:path f))) "identical to shipped"
                          :else "SHADOWS shipped")]
             (println (str "  " ns "  —  " status "  (" rel ")"))))
         files)
        0))))

(defn- cmd-diff [args]
  (if (empty? args)
    (u/usage-error "usage: bl override diff NS")
    (let [ns (first args)
          f (shipped-file ns)
          ovr (override-path ns)]
      (cond
        (nil? f) (u/usage-error (str "bl override diff: no shipped namespace \"" ns "\""))
        (not (File/exists? ovr)) (u/usage-error (str "bl override diff: " ns " is not vendored here"))
        :else
        (let [r (System/cmd "diff" (u/to-list ["-u" (:path f) ovr]))]
          (println (erlang/element 1 r))
          0)))))

(defn- cmd-revert [args]
  (if (empty? args)
    (u/usage-error "usage: bl override revert NS...")
    (let [results
          (map (fn [ns]
                 (let [p (override-path ns)]
                   (if (File/exists? p)
                     (do (File/rm p)
                         ;; drop the now-empty ns directory, if that is what
                         ;; it became (File/rmdir refuses a non-empty dir)
                         (File/rmdir (u/dirname p))
                         (println (str "reverted " ns " — shipped source is in effect again"))
                         :ok)
                     (do (u/io-err (str "bl override: " ns " is not vendored here"))
                         :error))))
               (u/to-list args))]
      (if (some (fn [r] (= :error r)) results) 1 0))))
```

## apply — a patch is a program

A patch file is beam-lisp source: a namespace exporting `(transform [ctx])`.
It runs as code — not a restricted data DSL — because the transformation a
package needs is rarely expressible as "match this s-expr, splice that
one"; but it is handed everything it needs to *find* its targets instead of
hardcoding positions:

```clojure
{:db-for        (fn [ns-list] → conn)   ; the codebase database over exactly the
                                        ; shipped sources named — the patch scopes
                                        ; its facts to its targets
 :read-shipped  (fn [ns] → {:path :source} | nil)
 :overrides-dir "…"     ; where the returned files will land
 :cwd           "…"}
```

`transform` returns the override, as data:

```clojure
{:files {"clojure.edn" "…full new source…"}   ; written to overrides/<ns>.bl
 :tests ["tagged_readers_test.bl"]            ; explicit unit tests,
                                              ; relative to the patch file
 :doc   "what this patch is for"}             ; optional, printed on apply
```

The contract a correct patch upholds: the sources in `:files` are complete
(replacements, not fragments) and self-sufficient (they keep the namespace's
ns form and its requires). `apply` enforces the rest.

```beam-lisp
(defn- db-for
  "A codebase-database connection over the shipped sources of `namespaces` —
   the patch scopes its facts to its targets. Facts are indexed per source and
   cached by content hash, so re-applying a patch re-asks nothing.

   Scoped on purpose: a patch needs facts about what it transforms, and
   full-corpus tier indexing is both slow on a cold cache and currently
   fragile (see the FUP this verb's prototype filed)."
  [namespaces]
  (let [sigs (merge typed/core-sigs typed/core-seeds-v2 typed/host-seeds)
        paths (filter some? (map (fn [ns]
                                   (let [f (shipped-file ns)]
                                     (if (nil? f) nil (:path f))))
                                 namespaces))]
    (:conn (bl.ask/connect-set! sigs (u/to-list paths)))))

(defn- read-shipped
  "The {:path :source} of a shipped namespace, or nil — the patch's window
   onto what it is transforming."
  [ns]
  (let [f (shipped-file ns)]
    (if (nil? f)
      nil
      {:path (:path f) :source (File/read! (:path f))})))

(defn- run-patch
  "Evaluate the patch file and call its `transform` with the context.
   Evaluation is fresh on every apply (no registry caching), so editing the
   patch and re-applying picks the edit up."
  [patch-path]
  (let [src (File/read! patch-path)
        ns-name (u/ns-of src)]
    (if (nil? ns-name)
      (throw (str "bl override apply: " patch-path " declares no (ns …)"))
      (do
        (BeamLisp/eval src)
        (let [transform (BeamLisp.Env/fetch! ns-name "transform")]
          (transform {:db-for db-for
                      :read-shipped read-shipped
                      :overrides-dir (overrides-dir)
                      :cwd (BeamLisp/cwd)}))))))
```

## Verification — implicit and explicit, logical and unit

`apply` raises when verification fails. Four gates, in order; the failing
gate's evidence goes to stderr, every written file is rolled back, and the
exit code is `1`.

```beam-lisp
(defn- checkout-test-root
  "The beam-lisp checkout's test/bl tree, or nil when this bl is a drop
   running away from its checkout — implicit unit tests are a checkout
   feature. priv/ is resolved through the symlink Mix makes from _build,
   then tested for the test tree's presence."
  []
  (let [priv (BeamLisp.Tiers/priv_root)
        real (let [r (File/read_link priv)]
               (if (and (tuple? r) (= :ok (erlang/element 1 r)))
                 (let [target (erlang/element 2 r)]
                   (if (= "/" (subs target 0 1))
                     target
                     (str (Path/dirname priv) "/" target)))
                 priv))
        tdir (str (Path/dirname real) "/test/bl")]
    (if (File/dir? tdir) tdir nil)))

(defn- implicit-tests
  "Shipped test files that require one of the touched namespaces — the
   behavior the override must not lose."
  [namespaces]
  (let [root (checkout-test-root)]
    (if (nil? root)
      {:paths [] :note "implicit unit tests skipped: no checkout test tree (drop without the checkout)"}
      (let [all (u/to-list (Path/wildcard (str root "/**/*.bl")))
            hits (filter (fn [p]
                           (let [src (File/read! p)]
                             (some (fn [ns] (some? (index-of src (str "[" ns))))
                                   namespaces)))
                         all)]
        {:paths (u/to-list hits) :note nil}))))
```

The gates themselves:

```beam-lisp
(defn- verify-logical
  "Logical gates: clean compiler diagnostics on each new source, and each
   overridden namespace loads in an isolated env. Returns a list of failure
   strings — empty when the override is logically sound."
  [files]
  (BeamLisp.Loader/ensure_loaded "lsp")
  (let [diagnostics (BeamLisp.Env/fetch! "lsp" "diagnostics")]
    (mapcat
     (fn [ns]
       (let [src (get files ns)
             diags (u/to-list (diagnostics src ns))
             diag-fails (map (fn [d] (str ns ": " (pr-str d))) diags)
             load-fail (try
                         ;; the ns must LOAD in a clean-room env, forked and
                         ;; destroyed around the require: diagnostics analyze
                         ;; text; this catches load-time failure (a bad value
                         ;; def, a missing require) without touching this
                         ;; process's registry — a warm daemon stays clean
                         (BeamLisp.Env/isolated
                          :global
                          (fn []
                            (BeamLisp/eval (str "(ns override-probe (:require [" ns "]))"))))
                         nil
                         (catch e (str ns ": does not load: " e)))]
         (concat diag-fails (if (some? load-fail) [load-fail] []))))
     (u/to-list (keys files)))))

(defn- verify-unit
  "Unit gates: the shipped tests of every touched namespace (implicit) and
   the patch's own tests (explicit), run against the override — per-file
   isolated envs, so a warm daemon's registry is never polluted by what a
   patch loads."
  [implicit-paths explicit-paths]
  (let [paths (concat implicit-paths explicit-paths)]
    (if (empty? paths)
      {:ok true :note "no unit tests apply"}
      (let [totals (BeamLisp.TestRT/run_suite (u/to-list paths) (u/kw [:async true]))]
        {:ok (BeamLisp.TestRT/passed? totals)
         :note (str (count paths) " test file(s)")}))))
```

## The apply command

```beam-lisp
(defn- rollback!
  "Undo every write: restore the previous content where a file existed,
   delete where the write created the file."
  [written]
  (u/each (fn [entry]
            (let [path (first entry) old (second entry)]
              (if (nil? old)
                (do (File/rm path)
                    ;; the vendored layout creates directories; leave none
                    ;; behind empty (File/rmdir answers an error tuple for a
                    ;; non-empty dir — exactly the case to keep)
                    (File/rmdir (u/dirname path)))
                (File/write! path old))))
          written))

(defn- cmd-apply [args]
  (if (empty? args)
    (u/usage-error "usage: bl override apply PATCH.bl")
    (let [patch-path (u/resolve (first args))
          patch-dir (u/dirname patch-path)]
      (if (not (File/exists? patch-path))
        (u/usage-error (str "bl override apply: no such patch: " (first args)))
        (let [result (run-patch patch-path)
              files (:files result)
              nss (u/to-list (keys files))
              explicit (u/to-list (map (fn [t] (str patch-dir "/" t))
                                       (u/to-list (or (:tests result) []))))]
          (when (some? (:doc result)) (println (str "patch: " (:doc result))))
          ;; The override goes on the search path FIRST, so verification —
          ;; and every command after — sees the new sources.
          (BeamLisp.Env/add_search_path (overrides-dir))
          ;; The map is FORCED with to-list: beam-lisp seqs are uniformly
          ;; lazy, and `written` is otherwise realized only by rollback! —
          ;; the writes would happen at rollback time, after verification
          ;; had already run against a file that did not exist yet.
          (let [written (u/to-list (map (fn [ns]
                               (let [src (get files ns)
                                     path (override-path ns)
                                     old (if (File/exists? path) (File/read! path) nil)]
                                 (File/mkdir_p (u/dirname path))
                                 (File/write! path src)
                                 (println (str "wrote overrides/" (ns->base ns) ".bl"))
                                 [path old]))
                             nss))
                logical-fails (u/to-list (verify-logical files))]
            (if (not (empty? logical-fails))
              (do
                (u/io-err "bl override apply: LOGICAL verification failed — rolling back:")
                (u/each (fn [f] (u/io-err (str "  " f))) logical-fails)
                (rollback! written)
                1)
              (let [implicit (implicit-tests nss)
                    _ (when (some? (:note implicit)) (println (str "  note: " (:note implicit))))
                    unit (verify-unit (:paths implicit) explicit)]
                (if (:ok unit)
                  (do
                    (println (str "✓ override applied — " (count nss) " file(s), "
                                  (:note unit) " passed"))
                    (println "  note: a warm `bl daemon` that already loaded an overridden namespace")
                    (println "        keeps its image; `bl daemon stop` to reload from source.")
                    0)
                  (do
                    (u/io-err "bl override apply: UNIT verification failed — rolling back (see the test report above)")
                    (rollback! written)
                    1))))))))))

;; ── dispatch ──────────────────────────────────────────────────────────

(def subcommands
  {"vendor" "bl override vendor NS...    copy a shipped namespace into overrides/ to edit it"
   "apply"  "bl override apply PATCH.bl  apply a patch program (verified, all-or-nothing)"
   "list"   "bl override list            what this tree overrides"
   "diff"   "bl override diff NS         the override against the shipped source"
   "revert" "bl override revert NS...    drop an override"})

(defn run
  "`bl override SUBCOMMAND ...` — see `bl override help`."
  [args _st]
  (let [sub (if (empty? args) "help" (first args))
        rest-args (if (empty? args) args (rest args))]
    (cond
      (= sub "vendor") (cmd-vendor rest-args)
      (= sub "apply")  (cmd-apply rest-args)
      (= sub "list")   (cmd-list rest-args)
      (= sub "diff")   (cmd-diff rest-args)
      (= sub "revert") (cmd-revert rest-args)
      (= sub "help")
      (do (println "bl override — vendoring and patching the beam-lisp you run")
          (u/each (fn [k] (println (str "  " (get-in subcommands [k]))))
                  ["vendor" "apply" "list" "diff" "revert"])
          0)
      :else
      (do (u/io-err (str "bl override: unknown subcommand \"" sub "\" (vendor|apply|list|diff|revert)"))
          2))))
```
