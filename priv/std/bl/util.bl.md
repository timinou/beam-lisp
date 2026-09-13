# bl.util — the small bridges every `bl` verb shares

`bl` commands live in their own namespaces (`bl.check`, `bl.lint`, `bl.repl`,
…) and do the same few chores at their edges: print a line to stderr, turn a
file or directory argument into the sources to act on, save a file through the
cwd the caller is standing in, and hand a value to Jason. Those chores live
here once so every verb speaks the same dialect.

Three shape-mismatches explain almost everything in this namespace.

- **Elixir option APIs read keyword lists.** `Keyword.get/3`, any `Enum`
  function taking `opts`, and the loader's ward entry points pattern-match
  cons-cell `{key, value}` tuples. A beam-lisp map is a different shape, and a
  beam-lisp literal cannot spell the tuple, so `kw-pair` and `kw` build the
  tuple list the Elixir side expects.

- **beam-lisp collections are their own types.** A `[…]` literal is a
  `BeamLisp.Vector` struct and a `#{…}` is a `BeamLisp.Set`; Jason encodes
  neither. `plain` recursively lowers a value to the lists, maps and strings
  Jason accepts, so one `emit` can serve both the human reader and the `--json`
  reader of the same data.

- **A command resolves file arguments against the client's cwd.** A standalone
  `bl` runs in the caller's shell, where the OS cwd is already right. The
  daemon serves many clients from one VM, so `resolve` reads the cwd the
  request bound rather than the daemon's own checkout.

The functions here return, they never halt. A command namespace hands its
`run` an integer exit code; `bl.cli/main` is the only place a process leaves.

```beam-lisp
(ns bl.util)
```

## Sequences: eager iteration, plain lists, keyword lists

`each` exists because `map` is lazy. A side effect sitting in an unrealized
lazy seq simply never runs, and a command is mostly side effects, so the
honest loop is an eager fold.

`to-list` and `kw` cross the boundary in the other direction. `to-list` gives
an Elixir API the cons-cell list it pattern-matches; a beam-lisp vector is a
different type even when it prints the same. `kw-pair` builds the `{key,
value}` tuple beam-lisp cannot write as a literal, and `kw` collects pairs into
a keyword list, realized eagerly because `Keyword.get` matches cons cells.

```beam-lisp
(defn each
  "Eager for-each. `map` is lazy — a side effect sitting in an unrealized lazy
   seq never runs. `reduce` is an eager fold, so this is the honest loop.
   Returns nil."
  [f coll]
  (reduce (fn [_ x] (f x) nil) nil coll))

(defn to-list
  "A plain cons-cell list from any seq. The Elixir APIs reached at the command
   boundary (Keyword.fetch!, the loader's source lists) want the list an Elixir
   caller passes, and a beam-lisp vector is a different type."
  [coll]
  (reverse (reduce (fn [acc x] (cons x acc)) nil coll)))

(defn kw-pair
  "One `{k, v}` Elixir keyword pair. beam-lisp has no tuple literal, so the
   tuple is built the way the prelude builds its tagged tuples."
  [k v]
  (erlang/list_to_tuple (list k v)))

(defn kw
  "An Elixir keyword list from beam-lisp pairs: `(kw [:a 1] [:b 2])`. ONE
   PAIR PER VECTOR — Elixir option APIs read opts with Keyword.get/3, which a
   beam-lisp map does not satisfy. Realized eagerly: Keyword.get
   pattern-matches cons cells.

   A single vector of four elements is the same options written flat, and
   `(kw [:a 1 :b 2])` would silently keep only `:a` — exactly the kind of
   option that goes missing without a symptom until the feature that needed it
   quietly does not work. So it is refused, by name."
  [& pairs]
  (when (and (erlang/=:= (erlang/length pairs) 1)
             (not (erlang/=:= 2 (count (first pairs)))))
    (throw (ex-info (str "util/kw: one pair per vector — (kw [:a 1] [:b 2]), not "
                         (pr-str (first pairs)))
                    {:pairs (first pairs)})))
  (to-list (map (fn [p] (kw-pair (first p) (second p))) pairs)))
```

## Paths: where a command's files are

`resolve` expands a file argument against the command's cwd. Standalone that is
the OS cwd, which makes an absolute path an identity. Under the daemon it is
the client's cwd, so `bl run foo.bl` typed in any terminal finds the file in
that terminal's tree, not one under the daemon's checkout.

`expand-targets` turns the user's PATH arguments into the actual sources: a
file stays a file when the loader would load it, a directory becomes every
source beneath it in sorted order. A command maps it over mixed arguments and
acts on exactly the sources, nothing else.

`join-args` exists because a shell splits an expression. `bl eval '(+ 1' '2)'`
arrives as three positionals; joining them with spaces restores the one form
the user meant.

```beam-lisp
(defn io-err [s] (IO/puts :stderr s))

(defn resolve
  "Expand a file argument against the command's cwd. Standalone this is the OS
   cwd (identity for an absolute path); under the daemon it is the CLIENT's cwd,
   so `bl run foo.bl` finds the client's file, not one under the daemon's
   checkout. `BeamLisp/cwd` carries the binding."
  [p]
  (Path/expand p (BeamLisp/cwd)))

(defn dirname [p] (Path/dirname p))

(defn rel-path
  "A path relative to the command's cwd — the form every report prints and every
   committed baseline keys by, so a file reads as the user typed it and a
   baseline survives a move to another checkout."
  [p]
  (Path/relative_to p (BeamLisp/cwd)))

(defn source-file?
  "A file the loader loads: `.bl`, or a literate `.bl.md` / `.bl.org`."
  [p]
  (some (fn [ext] (ends-with? p ext)) (BeamLisp.Loader/doc_extensions)))

(defn expand-targets
  "FILE → [FILE]; DIR → every loader source under it, sorted, hidden entries
   skipped. A file that is not a loader source expands to nothing, so a command
   maps this over mixed arguments and acts on exactly the sources."
  [p]
  (cond
    (File/regular? p) (if (source-file? p) [p] [])
    (File/dir? p)
    (->> (File/ls! p)
         (filter (fn [n] (not (starts-with? n "."))))
         (sort-by identity)
         (map (fn [n] (str p "/" n)))
         (mapcat expand-targets))
    :else []))

(defn join-args
  "bl eval '(+ 1' '2)' — join leftover positionals into one expression."
  [args]
  (reduce (fn [acc s] (if acc (str acc " " s) s)) nil args))
```

## Output: text or JSON from the same value

A command produces a value and prints it two ways. The human way is a render
function the command supplies. The machine way is JSON, and it is the same
value either way — `--json` changes the printer, not the data.

`plain` is the one lowering step JSON needs. It converts a keyword to its name,
a vector, list, set or lazy seq to an Erlang list, a map to a string-keyed map,
and does so recursively. A `BeamLisp.Vector` reaches Jason as a struct it
cannot encode, so the conversion happens here once rather than at every call
site. A foreign struct with its own `Jason.Encoder` is left intact so a library
value encodes the way its owner intends.

`emit` picks the printer. `render` may be nil for a command whose JSON is the
only content. `usage-error` reports a bad invocation and returns the CLI's
usage exit code.

```beam-lisp
(defn- plain-key [k]
  (cond (keyword? k) (name k)
        (string? k) k
        :else (str k)))

(defn plain
  "A beam-lisp value → the plain BEAM shapes Jason encodes. Keywords become
   their name (a JSON string); vectors, lists, sets and lazy seqs become Erlang
   lists; map keys become strings; the conversion is recursive. Jason rejects a
   BeamLisp.Vector or BeamLisp.Set deep in its encoder, so every `--json` output
   crosses here once."
  [x]
  (cond
    (keyword? x) (name x)
    (vector? x) (Enum/to_list (Enum/map (Enum/to_list x) (fn [e] (plain e))))
    (set? x)    (Enum/to_list (Enum/map (Enum/to_list x) (fn [e] (plain e))))
    (list? x)   (Enum/to_list (Enum/map (Enum/to_list x) (fn [e] (plain e))))
    (BeamLisp.LazySeq/lazy? x) (Enum/to_list (Enum/map (doall x) (fn [e] (plain e))))
    (struct? x) x
    (map? x)    (Map/new (Enum/to_list
                           (Enum/map (Enum/to_list x)
                             (fn [t] (kw-pair (plain-key (erlang/element 1 t))
                                              (plain (erlang/element 2 t)))))))
    :else x))

(defn emit
  "Print `data` through the command's output mode. With `:json` in the parsed
   argv, prints `(Jason/encode! (plain data))`; otherwise prints `(render data)`
   when that returns a string. `render` may be nil when the JSON is the only
   content. Returns nil."
  [st data render]
  (if (:json st)
    (println (Jason/encode! (plain data)))
    (when render
      (let [s (render data)]
        (when s (println s)))))
  nil)

(defn usage-error
  "Report a usage problem and return the CLI's usage exit code (2)."
  [msg]
  (io-err msg)
  2)

(defn plural
  "`n` with its noun: \"1 smell\", \"3 smells\". Every count a verb prints
   reads through here, so no report says \"1 files\"."
  [n noun]
  (str n " " noun (if (= n 1) "" "s")))

(defn silent
  "Run `f` with this process's group leader swapped for a throwaway StringIO,
   so whatever it (or the processes it spawns) prints never reaches stdout. A
   `--json` command wraps the work that produces its data in this: a runner
   that prints its own report, or a program under test that prints, would
   otherwise mix prose into the one JSON object. The leader is restored in a
   `finally`, so a raise still restores it."
  [f]
  (let [prev (Process/group_leader)
        dev (erlang/element 2 (StringIO/open ""))]
    (Process/group_leader (erlang/self) dev)
    (try (f) (finally (Process/group_leader (erlang/self) prev)))))
```

## Input: a file or standard input

`-` is the stdin convention every Unix tool shares. `read-source` gives a
command one call for "the source the user named", whether that is a file on
disk or the bytes on standard input. `read-stdin` reads to end of input and
answers the empty string when there is none, so a command never has to
distinguish "no input" from "empty input".

```beam-lisp
(defn read-stdin
  "All of standard input as one string; empty input reads as \"\"."
  []
  (let [s (IO/read :stdio :eof)]
    (if (= :eof s) "" s)))

(defn read-source
  "The source text for a FILE argument: `-` means standard input."
  [p]
  (if (= p "-") (read-stdin) (File/read! (resolve p))))
```

## The namespace a source declares

Many verbs need to know which namespace a file is: the analyzer keys facts by
it, a diagnostic names it, a baseline records it. It is the NAME of the leading
`(ns NAME …)` form, or `"user"` when a file declares none — the same default
the loader applies. Reading one form is cheap and needs no loader.

```beam-lisp
(defn ns-of
  "The namespace `src` declares in its first `(ns NAME …)` form, else \"user\"."
  [src]
  (try
    (let [f0 (first (BeamLisp.Compiler/read_all_data src))]
      (if (and (list? f0) (= 'ns (first f0)) (symbol? (second f0)))
        (name (second f0))
        "user"))
    (catch _ "user")))
```

## The version

The one place the release version is read: the `:beam_lisp` application's
`vsn`, which `mix.exs` stamps (CI stamps it from the tag). `bl version` and
`bl doctor` both print it from here. The erlang `application` module is used
rather than the Elixir delegate because it is what a trimmed release always
carries.

```beam-lisp
(defn version
  "The beam-lisp version string, or \"0.0.0-dev\" outside a started application."
  []
  (let [r (application/get_key :beam_lisp :vsn)]
    (if (= :undefined r)
      "0.0.0-dev"
      (let [[tag vsn] r]
        (if (= :ok tag)
          (if (string? vsn) vsn (erlang/list_to_binary vsn))
          "0.0.0-dev")))))
```

## Library roots and code paths

`--path` adds a directory the loader searches for namespaces. `--code-path`
adds a directory of AOT beams to the running VM's code path, and
`BEAM_LISP_CODE_PATH` does the same from the environment. Library roots keep
the loader from compiling a namespace it could not find; code paths let a
namespace load as a prebuilt beam instead of compiling from source.

A code-path directory matters because Mix prunes the VM code path down to the
project's dependencies once the project loads, so a `-pa` handed to the VM is
gone by the time a program runs. Adding the directory here, after the prune,
is what makes it stick.

```beam-lisp
(defn code-paths
  "The AOT beam directories to put on the VM code path: every `--code-path`
   value, then the colon-separated `BEAM_LISP_CODE_PATH`."
  [st]
  (let [env (System/get_env "BEAM_LISP_CODE_PATH")
        from-env (if (or (nil? env) (= env ""))
                   []
                   (filter (fn [d] (not= d "")) (String/split env ":")))]
    (concat (:code-paths st) from-env)))

(defn register-paths
  "Apply the parsed command's library roots and code paths. Library roots go to
   the loader's search path; code paths go on the VM's code path, expanded
   against the command's cwd."
  [st]
  (each (fn [d] (BeamLisp.Env/add_search_path d)) (:paths st))
  (each (fn [d] (Code/prepend_path (resolve d))) (code-paths st)))
```
