# The project file: env.bl

A beam-lisp project is a directory with a file in it. That file is `env.bl`, and
it says what the project IS: where its namespaces live, what its tasks are
called, which ports it serves on. Everything else — `bl run`, `bl test`,
`bl dev`, the session's dashboard — reads it and relies on it.

```beam-lisp id=require
(ns dev.env-doc
  (:require [bl.env :as env] [bl.util :as u]))
```

```beam-lisp silent
(defn scratch
  "A temporary project directory that is removed when `f` returns."
  [f]
  (let [d (str (System/tmp_dir!) "/bl-dev-doc-" (erlang/unique_integer (list :positive)))]
    (File/mkdir_p! d)
    (try (f d) (finally (File/rm_rf! d)))))
```


```bl-result require
:dev.env-doc
```

## What it looks like

This repository's own file, at the root:

```clojure
{:name  "beam-lisp"
 :paths ["examples" "priv/lib"]
 :tasks {:demo   {:run "examples/live/11-pulse-app.bl"
                  :doc "the Pulse walkthrough: one app, backend and frontend"}
         :runner {:run "examples/reload/10-ward-warm-runner.bl"
                  :doc "the isolated test runner, running four adversarial files"}}}
```

Six keys, and no others:

- `:name` — what the project is called.
- `:instance` — which checkout of this project is running, when more than one
  might be. It qualifies the names the project's ports answer to; declared, or
  the git branch when that is not a default branch. See [names](names.bl.md).
- `:paths` — the roots the loader searches for namespaces. This is what `-p`
  does on the command line, written down once instead of typed every time.
- `:tasks` — the verbs a developer types: `bl demo`, `bl runner`. A task is a
  file to run, or a map with `:run`, `:doc`, `:watch` and `:paths`.
- `:ports` — the ports the project serves on, by NAME: `{:web 4000}`, or
  `{:web {:port 0}}` to let the OS choose. A name is what the port answers to —
  `http://web.<project>.test` — so nobody has to read the number.
- `:env` — environment variables the project expects.

Anything else is reported as an unknown key. A typo that silently does nothing
is the worst kind of configuration bug, so it is not allowed to be silent:

```beam-lisp id=unknown-key
(scratch
  (fn [d]
    (File/write! (str d "/env.bl") "{:name \"typo\" :wat 2}")
    (:errors (env/project d))))
```

```bl-result unknown-key
("unknown key wat")
```

## Reading it: two ways, one answer

The value is a MAP, and a file whose last form is a map is read as DATA — no
evaluation, nothing runs:

```beam-lisp id=literal
(scratch
  (fn [d]
    (File/write! (str d "/env.bl") "{:name \"tiny\" :paths [\"src\"]}")
    (env/literal (str d "/env.bl"))))
```

```bl-result literal
{:ok {:name "tiny", :paths ["src"]}}
```

A file whose value is COMPUTED — a project that builds its task list, say — is
evaluated in its own fork instead. Both roads end at the same project value:

```beam-lisp id=computed
(scratch
  (fn [d]
    (File/write! (str d "/env.bl") "(assoc {:name \"built\"} :paths [\"src\"])")
    (env/literal (str d "/env.bl"))))
```

```bl-result computed
:dynamic
```

## Where it is found

Discovery walks UP from the command's directory. `bl` typed in any subdirectory
of a tree finds the same file, so no command ever needs a path to its own
configuration:

```beam-lisp id=walk-up
(scratch
  (fn [d]
    (File/mkdir_p! (str d "/deep/deeper"))
    (File/write! (str d "/env.bl") "{:name \"nested\"}")
    (= (str d "/env.bl") (env/find (str d "/deep/deeper")))))
```

```bl-result walk-up
true
```

## A broken file degrades, it never stops you

Every shape problem is collected as data. A project with six mistakes reports
six and still runs with the parts it understood — its remaining paths, its
surviving tasks:

```beam-lisp id=errors-are-data
(scratch
  (fn [d]
    (File/write! (str d "/env.bl") "{:name 42 :paths \"src\" :wat 2}")
    (list (:name (env/project d)) (:paths (env/project d)) (:errors (env/project d)))))
```

```bl-result errors-are-data
(nil [] (":paths must be a list of strings" ":name must be a string" "unknown key wat"))
```


That is the whole idea: a project file you can read in one screen, in two ways
that cannot disagree, that a typo cannot silently corrupt, and that never stops
the command you were actually trying to run.
