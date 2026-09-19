# bl.env — the project file, read once and relied on

An `env.bl` at a project's root describes the project: the library roots its
namespaces live under, the tasks a developer types as `bl <name>`, the ports it
serves on, and the environment it expects. It is a beam-lisp file whose last
form is a map — the project AS A VALUE, the same shape every other value in
this system has. A command reads it and then relies on it.

Three rules make it trustworthy:

**Discovery walks up.** `bl` typed in any subdirectory of a tree finds the same
project file, so no command ever needs a path to its own configuration. This is
direnv's rule, and it is why `env.bl` belongs to a tree rather than to a
directory.

**Two ways to read it, one truth.** A file that ends in a literal map is read as
DATA, with no evaluation at all — a tool that cannot afford an interpreter (the
doctor, the language server, a text editor) still sees exactly what a run sees.
A file whose value is computed gets a fork and an eval. The cheap path and the
full path return the same project value.

**A wrong key is a value, not a crash.** Every shape problem lands in `:errors`
as data. A broken `env.bl` degrades what the tree can do — its tasks, its ports
— and never stops the command that read it, let alone the daemon hosting it.

```beam-lisp silent
(ns bl.env
  (:require [bl.util :as u]))
```

## Discovery

The walk starts at the command's own directory and climbs until it finds an
`env.bl` or runs out of directories. One project file per tree, found the same
way from anywhere inside it.

```beam-lisp silent
(def file-name "env.bl")

(defn- parent [d] (Path/dirname d))

(defn find
  "The nearest `env.bl` at or above `dir`, or nil when the tree has none. The
   walk is what makes the project file belong to a TREE rather than to one
   directory: a command typed three levels down finds the file a command at the
   root finds."
  [dir]
  (loop [d (Path/expand dir)]
    (let [candidate (str d "/" file-name)]
      (cond
        (File/regular? candidate) candidate
        (= d (parent d))          nil
        :else                     (recur (parent d))))))
```

## The value, two ways

`literal` is the cheap read: parse the file, keep the last top-level form, and
return it when it is already a map. Nothing is evaluated, so it is safe for
tooling that must not run project code.

`evaluate` is the full read: the file runs in its own env fork. The fork is the
point — a project file that defines helpers or requires libraries does it in a
throwaway env, so the image it describes is untouched by the describing.

Both answer with a tagged result, `{:ok v}` or `{:error msg}`, so a caller
never has to guess whether a map it received is the project or a report about
one.

```beam-lisp silent
(defn literal
  "`env.bl` as DATA: its last top-level form, parsed and not evaluated. Returns
   `{:ok map}` when that form is the project map (write the file this way),
   `:dynamic` when the value is computed and only `evaluate` can see it, or
   `{:error msg}` when the file cannot be read."
  [path]
  (try
    (let [forms (BeamLisp.Compiler/read_all_data (File/read! path))]
      (cond
        (empty? forms) {:error "the file has no forms"}
        (map? (last forms)) {:ok (last forms)}
        :else :dynamic))
    (catch e {:error (ex-message e)})))

(defn evaluate
  "Evaluate `path` and return `{:ok value}` — or `{:error msg}` when it raises.
   The evaluation happens in its own env fork, so nothing a project file
   defines leaks into the image it describes."
  [path]
  (try
    (let [dir (Path/dirname path)
          v   (BeamLisp.Env/isolated :global
                (fn []
                  (BeamLisp.Loader/with_load_path dir
                    (fn [] (BeamLisp/eval (File/read! path))))))]
      {:ok v})
    (catch e {:error (ex-message e)})))

(defn- value-of
  "The project value a file holds: read as data when its last form is already a
   map, evaluated in a fork otherwise. One tagged result either way."
  [path]
  (let [lit (literal path)]
    (if (= lit :dynamic) (evaluate path) lit)))
```

## The shape

A project map declares twelve keys. Anything else is reported as an unknown key
rather than ignored, because a typo'd key that silently does nothing is the
worst kind of configuration bug.

- `:name` — the project's name, a string.
- `:instance` — which checkout of this project is running, when more than one
  might be: the qualifier its hosts carry. `:instance` when declared, else the
  tree's git branch when that is not a default branch, else nothing. See
  [names](names.bl.md).
- `:paths` — library roots, relative to the file's directory.
- `:tasks` — name → a file to run, or `{:run FILE :doc STRING :paths […]
  :watch BOOL}`.
- `:ports` — name → a port number, or `{:port N}` (`0` = the OS chooses).
- `:env` — name → value, the environment the tree expects.
- `:app` — `{:name :vsn :applications :mod}`: what this tree IS as an OTP
  application, so a build need not interrogate the running VM about itself.
- `:build` — `{:paths :seed :out :native :jobs :ex}`: which roots hold build
  sources, where the output goes, which crates are native, how wide to compile.
  `:ex :exclude` holds paths RELATIVE TO `:ex :root`, since that is what they are
  matched against.
- `:release` — `{:name :vsn :output :permanent :include :cookie :env}`: what to
  assemble, and what must be permanent in it.
- `:deps` — `[{:name :vsn} …]`: what this tree requires. The digests a
  resolution produced live in `bl.lock`, not here, so the declaration cannot
  disagree with itself.
- `:browser` — `{:provider :api-key-env :base-url :timeout-ms :session}`: how
  this tree reaches a browser provider. `:api-key-env` names the environment
  variable that holds the key — the key itself never appears here — and
  `:session` is handed to the provider verbatim, since only the provider knows
  its own vocabulary.

Every normalizer is total: it returns what it understood plus one error string
per thing it could not. `normalize` collects them, so a file with three
problems reports all three in one pass.

```beam-lisp silent
(def known-keys [:name :instance :paths :tasks :ports :schedules :env :doc
                 :app :build :release :deps :browser])

(defn- unknown-keys
  "The keys of `m` that nothing declares."
  [m known]
  (if (map? m)
    (filter (fn [k] (not (some (fn [x] (= x k)) known))) (keys m))
    []))

(defn- unknown-errs
  "One error string per undeclared key, naming where it was found."
  [m known what]
  (map (fn [k] (str what " has unknown key " k)) (unknown-keys m known)))

(defn- norm-atoms
  "A list of names read as atoms, or [] with an error. nil is absence."
  [v what]
  (cond
    (nil? v) [[] []]
    (and (vector? v) (every? (fn [x] (or (keyword? x) (string? x))) v))
    [(map (fn [x] (if (keyword? x) x (keyword x))) v) []]
    :else [[] [(str what " must be a list of names")]]))

(defn- norm-names
  "A list of strings that are NAMES matched against a path RELATIVE to a root
   (`:build :ex :exclude`), so expanding them would make them match nothing."
  [v what]
  (cond
    (nil? v) [[] []]
    (and (vector? v) (every? (fn [x] (string? x)) v)) [v []]
    :else [[] [(str what " must be a list of strings")]]))

(defn- norm-opt-string
  "A string made absolute against `root`, or nil. Absence is not an error."
  [v what root]
  (cond
    (nil? v) [nil []]
    (string? v) [(Path/expand v root) []]
    :else [nil [(str what " must be a string")]]))

(defn- key-name
  "A declaration's key as the STRING a command is typed with: `bl dev` looks up
   `\"dev\"`, so a project file's `:dev` and its command share one spelling."
  [k]
  (if (keyword? k) (name k) (str k)))

(defn- norm-strings
  "A list of strings, made absolute against `root`, or [] with an error naming
   what was expected. nil is absence, not a problem."
  [v what root]
  (cond
    (nil? v) [[] []]
    (and (vector? v) (every? (fn [x] (string? x)) v))
    [(map (fn [p] (Path/expand p root)) v) []]
    :else [[] [(str what " must be a list of strings")]]))

(defn- norm-task
  "One task entry → {:run FILE :doc STRING :paths [DIR…] :watch BOOL}, plus its
   errors. A bare string is the common case: the file to run."
  [name spec root]
  (let [what (str "task \"" name "\"")]
    (cond
      (string? spec)
      [{:run (Path/expand spec root) :doc nil :paths [] :watch false} []]

      (map? spec)
      (let [run (:run spec)
            [paths perr] (norm-strings (:paths spec) (str what " :paths") root)
            doc (:doc spec)
            derr (if (or (nil? doc) (string? doc)) [] [(str what " :doc must be a string")])]
        (if (string? run)
          [{:run (Path/expand run root) :doc doc :paths paths :watch (or (:watch spec) false)}
           (concat perr derr)]
          [nil (concat [(str what " needs :run, a file to run")] perr derr)]))

      :else
      [nil [(str what " must be a file name or a map")]])))

(defn- norm-tasks [v root]
  (cond
    (nil? v) [{} []]
    (map? v)
    (reduce
      (fn [acc k]
        (let [[spec errs] (norm-task k (get v k) root)]
          (if (nil? spec)
            [(nth acc 0) (concat (nth acc 1) errs)]
            [(assoc (nth acc 0) (key-name k) spec) (concat (nth acc 1) errs)])))
      [{} []]
      (keys v))
    :else [{} [":tasks must be a map of name → task"]]))

(defn- norm-ports [v]
  (cond
    (nil? v) [{} []]
    (map? v)
    (reduce
      (fn [acc k]
        (let [spec (get v k)
              known (cond
                      (erlang/is_integer spec) {:port spec}
                      (map? spec)     {:port (or (:port spec) 0)}
                      :else           nil)]
          (if (nil? known)
            [(nth acc 0) (conj (nth acc 1)
                               (str "port \"" k "\" must be a number or {:port N}"))]
            [(assoc (nth acc 0) (key-name k) known) (nth acc 1)])))
      [{} []]
      (keys v))
    :else [{} [":ports must be a map of name → port"]]))

(defn- norm-when
  "The `:every` / `:daily` / `:at` value of one declaration, checked: `[N UNIT]`,
   `[HH MM]`, or epoch-milliseconds.

   The spellings are the `(sched …)` clause's own (`(every 30 :min :id f)`),
   written where a file can carry them. A file cannot be evaluated, so it cannot
   hold an expression — but it can hold the same WORDS, and the scheduler builds
   both into one rule (proc.sched/rule)."
  [k v what]
  (cond
    (= k :at)
      (if (erlang/is_integer v)
        [v []]
        [nil [(str what " :at must be an epoch in milliseconds")]])

    ;; `[N UNIT]` — the unit is a NAME, and tick/unit-ms owns what it means. A
    ;; list of two integers is a TIME (below), which is why `:every 30 :min`
    ;; and `:daily 4 10` cannot be told apart by shape alone: the key says which
    ;; it is, and checking the wrong one would refuse every correct file.
    (and (= k :every) (vector? v) (= 2 (count v))
         (erlang/is_integer (nth v 0))
         (or (keyword? (nth v 1)) (string? (nth v 1))))
      [v []]

    (and (= k :daily) (vector? v) (= 2 (count v))
         (erlang/is_integer (nth v 0)) (erlang/is_integer (nth v 1)))
      ;; A time a clock can show. `:daily [25 0]` is not a late night — it is a
      ;; schedule that never fires, which is the failure a reader of the file is
      ;; least able to notice, so it is refused where the file is read.
      (if (and (>= (nth v 0) 0) (<= (nth v 0) 23) (>= (nth v 1) 0) (<= (nth v 1) 59))
        [v []]
        [nil [(str what " " (nth v 0) ":" (nth v 1)
                   " is not a time on a clock — :daily is [HH MM]")]])

    (= k :every)
      [nil [(str what " :every is [N UNIT], as in [30 :min]")]]

    :else
      [nil [(str what " :daily is [HH MM], as in [4 10]")]]))

(def SCHEDULE-KEYS
  "What one declaration may carry: when, what to run, how it reads in a listing,
   and the policies a single scheduled entry takes. An unknown key is refused
   rather than ignored — a mistyped `:evry` is a schedule that never runs, which
   is the one failure the reader of a project file cannot see for themselves."
  [:id :every :daily :at :run :doc :catch-up :jitter :on-error])

(defn- norm-schedule
  "One declaration → its normalized map and its errors.

   Shape only. Whether the VERB exists is decided when it fires
   (proc.sched/from-data), because a project that names a verb it has not
   written yet is still a project, and `bl` must keep working in it."
  [i d]
  (let [id (get d :id)
        nm (cond (string? id) id (keyword? id) (name id) :else nil)]
    (if (nil? nm)
      [nil [(str "schedule " i " needs an :id (a string)")]]
      (let [what (str "schedule \"" nm "\"")
            freqs (to-list (filter (fn [k] (contains? d k)) [:every :daily :at]))
            freq (when (= 1 (count freqs)) (first freqs))
            [when errs] (if (nil? freq)
                          [nil [(str what " must say exactly one of :every /"
                                      " :daily / :at")]]
                          (norm-when freq (get d freq) what))
            run (get d :run)
            rerrs (if (and (string? run)
                           (= 2 (count (to-list (erlang/apply :string :split
                                                     (list run "/" :all))))))
                    []
                    [(str what " :run must be a \"namespace/verb\" string, as in"
                          " \"bl.cache/prune\"")])
            uerrs (map (fn [k] (str what " has unknown key " k))
                       (filter (fn [k] (not (some (fn [x] (= x k)) SCHEDULE-KEYS)))
                               (keys d)))
            errs (concat errs rerrs uerrs)]
        [(if (or (nil? freq) (seq errs))
           nil
           (merge (select-keys d SCHEDULE-KEYS) {:id nm}))
         (vec errs)]))))

(defn- norm-schedules
  "A project file's periodic work, in declaration order. Each entry carries the
   three-word spelling the `(sched …)` clause takes — `:every [30 :min]`,
   `:daily [4 10]`, `:at MS` — plus `:run \"namespace/verb\"`. Errors are data,
   like every other shape problem here: a broken declaration costs the tree that
   schedule and never the command that read the file."
  [v]
  (cond
    (nil? v) [[] []]
    (vector? v)
      (let [rs (map (fn [i]
                      (let [d (nth v i)]
                        (if (map? d)
                          (norm-schedule i d)
                          [nil [(str "schedule " i " must be a map")]])))
                    (range (count v)))]
        [(vec (remove nil? (map (fn [r] (first r)) rs)))
         (vec (mapcat (fn [r] (second r)) rs))])
    :else [[] [":schedules must be a list of declarations"]]))

(defn- norm-env
  "A name → string map. The label names the key it came from, so an error says
   WHERE the problem is."
  [v what]
  (cond
    (nil? v) [{} []]
    (and (map? v) (every? (fn [k] (string? (get v k))) (keys v))) [v []]
    :else [{} [(str what " must be a map of name → string")]]))
```

```beam-lisp
(defn- norm-app
  "`:app` — what this tree IS as an OTP application, or nil for a tree that does
   not claim to be one. A missing `:mod` is a library, not an error."
  [v]
  (cond
    (nil? v) [nil []]
    (not (map? v)) [nil [":app must be a map"]]
    :else
      (let [mod (:mod v)
            modv (if (map? mod) {:name (:name mod) :start (:start mod)} nil)
            errs (concat
                   (if (or (nil? (:name v)) (string? (:name v))) []
                       [":app :name must be a string"])
                   (if (or (nil? (:vsn v)) (string? (:vsn v))) []
                       [":app :vsn must be a string"])
                   (if (or (nil? mod) (map? mod)) []
                       [":app :mod must be a map"])
                   (if (or (nil? mod) (not (map? mod)) (string? (:name mod))) []
                       [":app :mod needs :name, a string"])
                   (if (map? mod) (unknown-errs mod [:name :start] ":app :mod") [])
                   (unknown-errs v [:name :vsn :applications :mod] ":app"))]
        [(if (empty? errs)
           {:name (:name v)
            :vsn (:vsn v)
            :applications (first (norm-atoms (:applications v) ":app :applications"))
            :mod modv}
           nil)
         errs])))

(defn- norm-build
  "`:build` — where build sources live and where their output goes. Paths are
   absolute against the project root, like every other path here."
  [v root]
  (cond
    (nil? v) [nil []]
    (not (map? v)) [nil [":build must be a map"]]
    :else
      (let [[paths perr]  (norm-strings (:paths v) ":build :paths" root)
            [native nerr] (norm-strings (:native v) ":build :native" root)
            [seed serr]   (norm-opt-string (:seed v) ":build :seed" root)
            [out oerr]    (norm-opt-string (:out v) ":build :out" root)
            jobs          (:jobs v)
            jerr          (if (or (nil? jobs) (erlang/is_integer jobs)) []
                              [":build :jobs must be a number"])
            ex            (:ex v)
            [exv exerr]
            (cond
              (nil? ex) [nil []]
              (not (map? ex)) [nil [":build :ex must be a map"]]
              :else
                (let [[r rerr] (norm-opt-string (:root ex) ":build :ex :root" root)
                      [x xerr] (norm-names (:exclude ex) ":build :ex :exclude")]
                  [{:root r :exclude x}
                   (concat rerr xerr
                           (unknown-errs ex [:root :exclude] ":build :ex"))]))
            errs (concat perr nerr serr oerr jerr exerr
                         (unknown-errs v [:paths :seed :out :native :jobs :ex] ":build"))]
        [(if (empty? errs)
           {:paths paths
            :seed seed
            :out out
            :native native
            :jobs (or jobs 1)
            :ex exv}
           nil)
         errs])))

(defn- norm-release
  "`:release` — what to assemble: the release's name and version, where it goes,
   what must be permanent in it, and the environment its nodes expect.

   `:cookie :inherit` is the measured default for a self-build: a drop that
   invents a fresh cookie each generation differs from the one before by exactly
   one file, which is enough to break a fixpoint."
  [v root]
  (cond
    (nil? v) [nil []]
    (not (map? v)) [nil [":release must be a map"]]
    :else
      (let [[out oerr]  (norm-opt-string (:output v) ":release :output" root)
            [perm nerr] (norm-atoms (:permanent v) ":release :permanent")
            [inc ierr]  (norm-atoms (:include v) ":release :include")
            [env eerr]  (norm-env (:env v) ":release :env")
            ck          (:cookie v)
            cerr        (cond
                          (nil? ck) []
                          (= ck :inherit) []
                          (string? ck) []
                          :else [":release :cookie must be a string or :inherit"])
            errs (concat
                   (if (or (nil? (:name v)) (string? (:name v))) []
                       [":release :name must be a string"])
                   (if (or (nil? (:vsn v)) (string? (:vsn v))) []
                       [":release :vsn must be a string"])
                   oerr nerr ierr eerr cerr
                   (unknown-errs v [:name :vsn :output :permanent :include :cookie :env]
                                 ":release"))]
        [(if (empty? errs)
           {:name (:name v)
            :vsn (:vsn v)
            :output out
            :permanent perm
            :include inc
            :cookie ck
            :env env}
           nil)
         errs])))

(defn- norm-deps
  "`:deps` — the libraries this tree requires, as a list of `{:name :vsn}`. A
   digest does not belong here: digests are what RESOLUTION produced, and they
   live in `bl.lock`, so the declaration cannot disagree with itself."
  [v]
  (cond
    (nil? v) [[] []]
    (not (vector? v)) [[] [":deps must be a list of {:name :vsn}"]]
    :else
      (reduce
        (fn [acc d]
          (let [errs (if (map? d)
                       (concat
                         (if (string? (:name d)) [] ["a dep needs :name, a string"])
                         (if (string? (:vsn d)) [] ["a dep needs :vsn, a string"])
                         (unknown-errs d [:name :vsn] "a dep"))
                       ["a dep must be a map"])]
            (if (empty? errs)
              [(conj (nth acc 0) {:name (:name d) :vsn (:vsn d)}) (nth acc 1)]
              [(nth acc 0) (concat (nth acc 1) errs)])))
        [[] []]
        v)))

(defn- norm-browser
  "`:browser` — how this tree reaches a browser provider: which provider, the
   NAME of the environment variable that holds its key, the provider's base
   URL, a request timeout, and the provider's own session options.

   The key itself is never here. `:api-key-env` names the variable that holds
   it, so the file stays commit-safe and a rotated key needs no edit; whoever
   calls the provider resolves it (server-side, from that variable) at call
   time. `:session` is PASS-THROUGH — viewport, `timeout_seconds`,
   `network.private_hosts`, `profiles` and whatever else a provider accepts go
   to the client unread, because only the provider knows its own vocabulary.

   Declaring this provisions nothing: no browser, no session is opened until
   something asks for one."
  [v]
  (cond
    (nil? v) [nil []]
    (not (map? v)) [nil [":browser must be a map"]]
    :else
      (let [provider (:provider v)
            perr (cond
                   (nil? provider) []
                   (keyword? provider) []
                   (string? provider) []
                   :else [":browser :provider must be a name"])
            key-env (:api-key-env v)
            kerr (if (or (nil? key-env) (string? key-env)) []
                     [":browser :api-key-env must be a string"])
            base (:base-url v)
            berr (if (or (nil? base) (string? base)) []
                     [":browser :base-url must be a string"])
            timeout (:timeout-ms v)
            terr (if (or (nil? timeout) (and (erlang/is_integer timeout)
                                             (pos? timeout)))
                   []
                   [":browser :timeout-ms must be a positive number"])
            session (:session v)
            serr (if (or (nil? session) (map? session)) []
                     [":browser :session must be a map"])
            errs (concat perr kerr berr terr serr
                         (unknown-errs v [:provider :api-key-env :base-url
                                          :timeout-ms :session] ":browser"))]
        [(when (empty? errs)
           {:provider (if (string? provider) (keyword provider) provider)
            :api-key-env key-env
            :base-url base
            :timeout-ms timeout
            :session session})
         errs])))
```

`normalize` assembles the value the runtime holds. It is total too: `:errors` is
a list, `:paths` is a list, `:tasks` and `:ports` are maps — always the right
shape, whatever the file said.

```beam-lisp silent
(defn normalize
  "The project value as the runtime reads it: `:paths` absolute against `root`,
   tasks and ports keyed by name, `:errors` — every shape problem found, as
   data. Never raises."
  [m root path]
  (let [[paths perr]   (norm-strings (:paths m) ":paths" root)
        nm             (:name m)
        nerr           (if (or (nil? nm) (string? nm)) [] [":name must be a string"])
        inst           (:instance m)
        ierr           (if (or (nil? inst) (string? inst)) [] [":instance must be a string"])
        [tasks terr]   (norm-tasks (:tasks m) root)
        [ports porerr] (norm-ports (:ports m))
        [sched serr]   (norm-schedules (:schedules m))
        [env eerr]     (norm-env (:env m) ":env")
        [app aerr]     (norm-app (:app m))
        [bld berr]     (norm-build (:build m) root)
        [rel rerr]     (norm-release (:release m) root)
        [deps derr]    (norm-deps (:deps m))
        [brw brerr]    (norm-browser (:browser m))]
    {:path path
     :root root
     :name (if (string? nm) nm nil)
     :instance (if (string? inst) inst nil)
     :paths paths
     :tasks tasks
     :ports ports
     :schedules sched
     :env env
     :app app
     :build bld
     :release rel
     :deps deps
     :browser brw
     :errors (concat perr nerr ierr terr porerr serr eerr aerr berr rerr derr
                     brerr
                     (map (fn [k] (str "unknown key " k)) (unknown-keys m known-keys)))}))

(defn empty-project
  "A tree with no env.bl: a project value with nothing declared. Not a special
   case — every accessor reads it the same way it reads a declared one."
  [root]
  {:path nil :root root :name nil :instance nil :paths [] :tasks {} :ports {}
   :schedules []
   :env {} :app nil :build nil :release nil :deps [] :browser nil :errors []})
```

## The project value for a directory

`project` is the one entry point every caller uses — the CLI, the daemon, a
test. It finds the file, reads it, and returns a project value whether or not
the tree has one at all.

```beam-lisp silent
(defn project
  "The project value for the tree containing `cwd`. Always a map: `:path` is the
   env.bl (or nil), `:root` the directory relative paths resolve against, and
   `:errors` any shape problems. Discovery, reading and normalization never
   raise — a caller decides what a degraded project means for it."
  [cwd]
  (let [start (Path/expand cwd)
        path  (find start)]
    (if (nil? path)
      (empty-project start)
      (let [root (Path/dirname path)
            r    (value-of path)
            v    (get r :ok)]
        (cond
          (not (nil? (get r :error)))
          (assoc (empty-project root) :path path
                 :errors [(str "env.bl: " (get r :error))])

          (map? v)
          (normalize v root path)

          :else
          (assoc (empty-project root) :path path
                 :errors [(str "env.bl: the last form must be a map, got " (pr-str v))]))))))
```
