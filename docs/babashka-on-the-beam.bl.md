# Babashka on the BEAM — a runnable guidebook

> This is a **literate program**. Every `beam-lisp` code block below runs.
> Load it like any script: `mix beam_lisp.run docs/babashka-on-the-beam.bl.md`.
> The prose is the narrative; the code is the proof.

Babashka made Clojure a joy for scripting: `slurp` a file, crunch it with
`clojure.string` and the threading macros, `spit` the result, read
`*command-line-args*`. beam-lisp brings that same vocabulary to the BEAM — the
same `clojure.*` namespaces, the same contracts — so the muscle memory
transfers. This guidebook walks the surface, and runs while it does.

## One namespace form, every batteries library

A script opens exactly as it would under Babashka: a plain `ns` with `:require`.
These are the real `clojure.*` and `babashka.*` names, resolved from the compat
tier.

```beam-lisp
(ns guide.babashka
  (:require [clojure.string :as str]
            [clojure.set :as set]
            [clojure.edn :as edn]
            [clojure.walk :as walk]
            [babashka.fs :as fs]
            [clojure.io]))
```

## `clojure.string` — the daily driver

Every contract is Clojure's: `split` returns a vector and drops trailing
empties, `join` puts the separator between elements, `replace` handles literal
strings, chars, and regex patterns (with `$1` group references).

```beam-lisp
(println "split:    " (str/split "a,b,,c," (re-pattern ",")))
(println "join:     " (str/join " | " ["one" "two" "three"]))
(println "replace:  " (str/replace "hello world" (re-pattern "o") "0"))
(println "groups:   " (str/replace "2026-08-31" (re-pattern "(\\d+)-(\\d+)-(\\d+)") "$3/$2/$1"))
(println "capitalize:" (str/capitalize "bABASHKA"))
(println "blank?:   " (str/blank? "   ") (str/blank? " x "))
```

## Regex is `clojure.core`, no require

`re-find`, `re-matches`, `re-seq` resolve unqualified — they are interned into
core on load, exactly as they are `clojure.core` on the JVM. The whole-vs-vector
return contract holds: no capture groups yields the matched string, groups yield
`[whole g1 …]`.

```beam-lisp
(println "re-find (no groups):" (re-find (re-pattern "\\d+") "abc123def"))
(println "re-find (groups):   " (re-find (re-pattern "(\\w)(\\w)") "hi there"))
(println "re-matches (anchored):" (re-matches (re-pattern "\\d+") "42") (re-matches (re-pattern "\\d+") "4x2"))
(println "re-seq (all):       " (vec (re-seq (re-pattern "\\w+") "the quick brown fox")))
```

## `clojure.edn` — read data, safely

`edn/read-string` parses Clojure data notation and **never evaluates** it. A
list is data, not a call — so reading untrusted input is safe.

```beam-lisp
(def config (edn/read-string "{:port 8080 :hosts [\"a\" \"b\"] :flags #{:tls :http2}}"))
(println "parsed:   " config)
(println "a keyword lookup:" (:port config))
(println "safety — (inc 1) stays DATA:" (edn/read-string "(inc 1)"))
```

## `clojure.set` — relational algebra

Vendored byte-for-byte from Clojure. Union, intersection, difference, and the
rel operators (`project`, `join`, `index`) all work on beam-lisp's native sets
and maps.

```beam-lisp
(println "union:       " (set/union #{1 2} #{2 3} #{3 4}))
(println "intersection:" (set/intersection #{1 2 3} #{2 3 4}))
(println "difference:  " (set/difference #{1 2 3} #{2}))
(def people #{{:name "Ada" :role "dev"} {:name "Bob" :role "ops"}})
(println "project:     " (set/project people [:role]))
```

## `clojure.walk` — transform whole trees

`postwalk`/`prewalk` rewrite arbitrary nested data. `keywordize-keys` is the
classic: turn a JSON-shaped string-keyed map into a keyword-keyed one, all the
way down.

```beam-lisp
(def raw {"user" {"name" "Ada" "roles" ["admin" "dev"]}})
(println "keywordized:" (walk/keywordize-keys raw))
(println "doubled:    " (walk/postwalk (fn [x] (if (number? x) (* 2 x) x)) [1 [2 3] {:a 4}]))
```

## `babashka.fs` + `slurp`/`spit` — touch the filesystem

The script half of Babashka: create directories, write and read files, glob a
tree. `slurp` and `spit` are `clojure.core`, unqualified.

```beam-lisp
(def dir "/tmp/bl-guidebook")
(fs/create-dirs dir)
(spit (fs/path dir "greeting.txt") "hello from the BEAM")
(println "slurped:  " (slurp (fs/path dir "greeting.txt")))
(spit (fs/path dir "log.txt") "line1\n")
(spit (fs/path dir "log.txt") "line2\n" :append true)
(println "appended: " (clojure.io/read-lines (fs/path dir "log.txt")))
(println "exists?:  " (fs/exists? (fs/path dir "greeting.txt")))
(println "extension:" (fs/extension "report.edn"))
(fs/delete-tree dir)
(println "cleaned up:" (not (fs/exists? dir)))
```

## Putting it together — a tiny pipeline

The Babashka reflex: read some data, transform it with the threading macros and
the seq library, print a summary. This is the whole point — unmodified Clojure
idiom, computing the right answer, on OTP.

```beam-lisp
(def sales-edn
  "[{:region :north :amount 100} {:region :south :amount 250}
    {:region :north :amount 150} {:region :south :amount 300}]")

(let [sales (edn/read-string sales-edn)
      by-region (->> sales
                     (group-by :region)
                     (map (fn [pair]
                            [(key pair) (reduce + (map :amount (val pair)))]))
                     (sort-by second >))]
  (println "\nSales by region (high to low):")
  (doseq [row by-region]
    (println (str "  " (name (first row)) ": " (second row)))))
```

## Where this stops

This runs a *useful subset* of Babashka — `clojure.core` plus string/set/edn/
walk/io/fs and the script platform. It is not "any bb app": a script that reaches
into `java.*`, a Maven dependency, or a pod cannot run unmodified, because there
is no JVM under the BEAM. That boundary is a category difference, not a missing
feature — and everything on this page is real, tested (`docs/babashka-compat.md`
has the scorecard: 81 tests, 339 assertions, zero failures), and running as you
read it.

```beam-lisp
(println "\n— end of guidebook; everything above executed —")
```
