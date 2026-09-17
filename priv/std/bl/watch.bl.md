# bl.watch — live-reload a directory on save

`bl watch FILE|DIR` watches a directory and, on every `.bl` save, stages and
commits the edit through the coherent reload loop — so the running image follows
the source with no restart. Each commit prints one rendered line: the file that
changed, whether the bundle applied or was held, and the namespaces it touched.

## Two hosts, ONE renderer

The verb runs in one of two places, and they share every line of output.

* **A warm daemon hosts the watcher.** `bl watch` reaches the daemon as a
  request; the watcher's rendering streams back over the socket. Every reload
  commit rides the daemon's sequencer (`vm.exec/run-reload`), so it is ordered
  against the runs and tests the daemon is serving — a reload never races a
  program mutating the same image.
* **Without a daemon the verb owns its process.** A standalone `bl watch`
  starts a `BeamLisp.ReloadWatcher` bound to this VM and parks; every commit
  prints here, in the CLI's own process.

The daemon calls `render` through the runtime (`Loader.ensure_loaded` +
`Env.fetch!`), a standalone run calls it in process — the same beam-lisp
function either way, so a commit line cannot drift between the two hosts.

## The reload contract

A save does not mutate the image directly. The changed source is staged into a
pending bundle; a commit proves the whole bundle coherent (no dangling caller,
no type break, no unmet promise contract) and then applies it atomically. A
coherent bundle becomes live in one step; an incoherent one is HELD — the old
code keeps serving and the reason is printed. The image is therefore coherent
AFTER EVERY COMMIT, which is the point: `bl monitor` paints that coherent image
(`reload/inspect`), and this verb prints the same commits as a log.

The live-reload engine needs the `:file_system` application, which turns a save
into an event. Its absence surfaces as an EXIT signal to this linked process —
uncatchable by `try` — so `run` traps exits and reports the failure as a value.
`bl doctor` reports the dependency.

## The result shape

A watch result is the `reload/commit` status map plus `:path`:

    {:path    "…/foo.bl"       ; the file that was saved
     :status  :applied         ; :applied | :held | :blocked | :empty | :error | :removed
     :bundle  ["app.foo"]      ; namespaces staged in this commit
     :applied ["app.foo"]      ; namespaces now live (on :applied)
     :errors  [...]}           ; reasons, each {:kind … :msg …} (on :held)

`reload/commit` returns the status map; `:path` is attached at the watcher's
`:apply` seam, because that is the one place that sees the saved path — the
daemon's registry does it in Elixir, `run` here does it locally.

```beam-lisp
(ns bl.watch
  (:require [bl.util :as u]))
```

## The rendering

One line per commit, led by a status glyph so a long watch scans at a glance:
the outcome, the saved path, then the namespaces the commit touched. A hold adds
one indented line per reason, so a held edit explains itself without a second
command. It is a rendering, not a printed map: nothing here dumps the result.

```beam-lisp
(defn- glyph
  "One status marker, so a stream of commits scans without reading every word."
  [status]
  (cond
    (= status :applied) "✓"
    (= status :held)    "✗"
    (= status :blocked) "⊘"
    (= status :error)   "!"
    (= status :removed) "−"
    :else               "·"))

(defn render
  "The ONE rendering of one watch result — the line(s) a watcher commit prints.
   `r` is a watch result (see the shape above): status, saved path, namespaces,
   and — for a hold — the reasons. Returns a string with no trailing newline."
  [r]
  (let [status (:status r)
        path   (or (:path r) "<unknown>")
        applied (:applied r)
        nses   (if (or (nil? applied) (empty? applied)) (:bundle r) applied)
        head   (str (glyph status) " " (name (or status :empty)) "  " path
                    (if (or (nil? nses) (empty? nses))
                      ""
                      (str "  [" (join " " nses) "]")))
        errs   (:errors r)]
    (if (or (nil? errs) (empty? errs))
      head
      (join "\n"
            (concat [head]
                    (map (fn [e] (str "    [" (name (:kind e)) "] " (:msg e))) errs))))))

(defn with-path
  "Attach the saved file's `:path` to a commit result — the local host's half of
   the apply seam (the daemon's registry does the same in Elixir). A result that
   is not a map — the watcher's `{:error, msg}` when a stage/commit raised — is
   normalized to an `:error` result, so `render` always has one shape."
  [r path]
  (if (map? r)
    (assoc r :path path)
    {:path path :status :error :errors [{:kind :error :msg (str r)}]}))
```

## The command

`run` resolves the target against the command's cwd, starts the watcher with the
rendering as its result callback, and parks. `FILE` is a convenience — the
source you are editing names its own directory — so `bl watch foo.bl` and
`bl watch .` are the same watch. A missing target is a usage error (2); a
watcher that cannot start returns 1 with the reason. It never halts: the daemon
calls this same namespace's `run` for the local path.

```beam-lisp
(defn- why
  "A caught value as one line: an exception's message, else its printed form."
  [r]
  (try (ex-message r) (catch _ (pr-str r))))

(defn- watch-error
  "Report a watcher that could not start and return the failure exit code. Never
   halts: under the daemon this runs inside the warm VM. The :file_system hint
   only fires when the reason IS the missing application — printed beside an
   unrelated failure (e.g. a name clash) it sends the reader to the wrong fix."
  [r]
  (u/io-err (str "bl watch: cannot start the watcher: " (why r)))
  (if (and (string? (why r)) (re-find #"file_system" (why r)))
    (u/io-err "  the live-reload engine needs the :file_system application; run `bl doctor`.")
    nil)
  1)

(defn- apply-fn
  "The watcher's apply seam, local to this VM: run the default stage→commit and
   tag the result with the saved path, so `render` sees the same shape the
   daemon's registry produces."
  [source path commit?]
  (with-path (BeamLisp.ReloadWatcher/apply_change source path commit?) path))

(defn- watch
  "Start the watcher on `dir` (absolute) and park this process on it. Returns
   the watcher's failure code when it cannot start."
  [dir st]
  (u/register-paths st)
  ;; FileSystem's :undef inside the watcher's init surfaces as an EXIT SIGNAL to
  ;; this linked process — uncatchable by try. Trap exits so the failure comes
  ;; back as a value instead.
  (Process/flag :trap_exit true)
  (try
    (let [[tag detail]
          (BeamLisp.ReloadWatcher/start_link
            (u/kw [:dirs (u/to-list [dir])]
                  [:auto_commit true]
                  [:apply apply-fn]
                  [:on_result (fn [r] (println (render r)))]))]
      (if (= :ok tag)
        (do (println (str "bl watch: watching " dir " — Ctrl+C to stop"))
            ;; `bl watch` IS this process.
            (Process/sleep :infinity)
            0)
        (watch-error detail)))
    (catch e (watch-error e))))

(defn run
  "`bl watch FILE|DIR`. Watch FILE's directory (or DIR) and print one rendered
   line per committed save. PARKS on success; 2 for a bad invocation, 1 when the
   watcher cannot start."
  [args st]
  (if (empty? args)
    (u/usage-error "usage: bl watch FILE|DIR")
    (let [target (u/resolve (first args))]
      (cond
        (File/dir? target)     (watch target st)
        (File/regular? target) (watch (u/dirname target) st)
        :else                  (u/usage-error (str "bl watch: not a directory: " (first args)))))))
```
