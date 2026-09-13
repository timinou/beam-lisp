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

```beam-lisp
(ns bl.env
  (:require [bl.util :as u]))
```

## Discovery

The walk starts at the command's own directory and climbs until it finds an
`env.bl` or runs out of directories. One project file per tree, found the same
way from anywhere inside it.

```beam-lisp
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

```beam-lisp
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

A project map declares six keys. Anything else is reported as an unknown key
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

Every normalizer is total: it returns what it understood plus one error string
per thing it could not. `normalize` collects them, so a file with three
problems reports all three in one pass.

```beam-lisp
(def known-keys [:name :instance :paths :tasks :ports :env :doc])

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

(defn- norm-env [v]
  (cond
    (nil? v) [{} []]
    (and (map? v) (every? (fn [k] (string? (get v k))) (keys v))) [v []]
    :else [{} [":env must be a map of name → string"]]))
```

`normalize` assembles the value the runtime holds. It is total too: `:errors` is
a list, `:paths` is a list, `:tasks` and `:ports` are maps — always the right
shape, whatever the file said.

```beam-lisp
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
        [env eerr]     (norm-env (:env m))
        unknown        (filter
                         (fn [k] (not (some (fn [known] (= known k)) known-keys)))
                         (keys m))]
    {:path path
     :root root
     :name (if (string? nm) nm nil)
     :instance (if (string? inst) inst nil)
     :paths paths
     :tasks tasks
     :ports ports
     :env env
     :errors (concat perr nerr ierr terr porerr eerr
                     (map (fn [k] (str "unknown key " k)) unknown))}))

(defn empty-project
  "A tree with no env.bl: a project value with nothing declared. Not a special
   case — every accessor reads it the same way it reads a declared one."
  [root]
  {:path nil :root root :name nil :instance nil :paths [] :tasks {} :ports {}
   :env {} :errors []})
```

## The project value for a directory

`project` is the one entry point every caller uses — the CLI, the daemon, a
test. It finds the file, reads it, and returns a project value whether or not
the tree has one at all.

```beam-lisp
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
