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

The keys a project may declare:

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
- `:app` — what the tree IS as an OTP application (`:name :vsn :applications
  :mod`), so a build need not interrogate the running VM about itself.
- `:build` — which roots hold build sources, where the output goes, which
  crates are native, how wide to compile.
- `:release` — what to assemble, and what must be permanent in it.
- `:deps` — the libraries the tree requires. The digests a resolution produced
  live in `bl.lock`, not here, so the declaration cannot disagree with itself.
- `:browser` — how the tree reaches a browser provider. See
  [Talking to a browser](#talking-to-a-browser).

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


## Talking to a browser

Some trees drive a real browser: a provider hosts one on the far side of an
HTTP API, and the project says which provider and how to reach it. That is
`:browser`, and reading it is reading any other key:

```beam-lisp id=browser
(scratch
  (fn [d]
    (File/write! (str d "/env.bl")
                 (str "{:name \"browsing\""
                      " :browser {:provider :kernel"
                      "           :api-key-env \"KERNEL_API_KEY\""
                      "           :base-url \"https://api.onkernel.com\""
                      "           :timeout-ms 30000"
                      "           :session {:viewport {:width 1280 :height 800}"
                      "                     :network {:private_hosts true}}}}"))
    (:browser (env/project d))))
```

```bl-result browser
{:session {:viewport {:width 1280, :height 800}, :network {:private_hosts true}}, :provider :kernel, :api-key-env "KERNEL_API_KEY", :base-url "https://api.onkernel.com", :timeout-ms 30000}
```

Five keys, and what each one is for:

- `:provider` — which provider, a name: `:kernel`. It is what turns the rest of
  the map into requests.
- `:api-key-env` — the NAME of the environment variable that holds the key.
  **The key itself never appears in the file.** It is resolved where the call is
  made — the server reads `KERNEL_API_KEY` from its own environment — so the
  file stays commit-safe, and rotating the key needs no edit here.
- `:base-url` — where that provider's API lives.
- `:timeout-ms` — how long a call may take, a positive number of milliseconds.
- `:session` — the provider's OWN options, passed through untouched:
  `viewport`, `timeout_seconds`, `network.private_hosts`, `profiles`, and
  whatever else it accepts. Nothing in this map is interpreted here; only the
  provider knows its own vocabulary.

Two things `:browser` deliberately does not do.

**It never holds the key.** There is no `:api-key`. A key typed into the file is
an unknown key — an error, not a stored secret:

```beam-lisp id=browser-secret
(scratch
  (fn [d]
    (File/write! (str d "/env.bl") "{:browser {:api-key \"sk-live-oops\"}}")
    (:errors (env/project d))))
```

```bl-result browser-secret
(":browser has unknown key api-key")
```

**It provisions nothing.** Declaring `:browser` opens no browser and reserves no
session: it says how to reach a provider, and a session is created by a call
that asks for one. Reading the project stays free of side effects, like every
other key. A tree that declares no `:browser` reads `nil` — not an empty map, and
not a special case.

That is the whole idea: a project file you can read in one screen, in two ways
that cannot disagree, that a typo cannot silently corrupt, and that never stops
the command you were actually trying to run.
