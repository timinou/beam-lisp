# bl.fix — rewrite the smells away, keeping the file's shape

`bl fix` is `bl lint`'s other half: it finds the same deodorant smells and
rewrites them in place. The rewrite is **trivia-preserving** — only the tokens
the rule itself spells change; every comment, every blank line, and the layout
of every untouched form survive byte-for-byte. That is what makes a sweep
across a whole codebase reviewable: the diff shows the shortcuts, nothing else.

The rules come from the same tiers `bl lint` describes. No `--tier` is the
default safe+idiomatic set; `--tier safe` applies only the value-identical
rules; `--tier every` adds the reinvention tier that restructures a hand-rolled
`reduce` into `count` or `sum`, and the MIGRATION tier that turns one form into
a successor form. `--tier every` is explicit — naming it is the opt-in.

A migration may bring a SECOND EDIT: a rule whose output names a namespace can
declare `:ensure-require [proc.server :as srv]`, and the fixer appends that
require to the file's `(ns …)` line — append only, never reorder. When the
header has no `:require` clause to append to, or already requires the namespace
under a different alias, the fixer REFUSES and writes NOTHING, naming the line
to edit: a fix whose output must be hand-repaired is worse than no fix.

Only plain `.bl` sources are rewritten. A literate document (`.bl.md`,
`.bl.org`) holds prose around its cells, and the fixer works on whole file
text, so those are reported as skipped rather than mangled. Standard input is
refused: a fix has to write somewhere.

```beam-lisp
(ns bl.fix
  (:require [bl.util :as u] [bl.lint :as lint] [deodorant]))
```

## Which files can be fixed in place

A fixable file is a plain `.bl` source. The check is about the file the fixer
reads and writes, not about the code inside it — a literate document's cells
are lintable but not writable back as one text.

```beam-lisp
(defn fixable-file?
  "A file the in-place fixer rewrites: a plain `.bl` source. A literate
   document (`.bl.md` / `.bl.org`) interleaves prose with its cells, and the
   fixer works on the whole text, so the command leaves those alone."
  [p]
  (ends-with? p ".bl"))
```

## One file at a time, a failure does not stop the sweep

`fix-one` runs the trivia-preserving rewriter over one file and returns what
changed. The result is re-parsed inside the rewriter before it is written, so a
file that could not be read raises here and is recorded as failed rather than
leaving the sweep half done. The path in the result is the display path — the
one relative to the command's cwd — so the report reads the way the user typed
it.

```beam-lisp
(defn- fix-one
  "Fix one plain source in place. `{:path :changed :applied}`, or
   `{:path :error}` when the fixer could not read the file OR a migration's
   second edit was REFUSED (the header could not be amended safely) — in which
   case nothing was written, so the file is reported, not silently half-fixed."
  [rules p]
  (try
    (let [r (deodorant/fix-file-preserving! rules p)]
      (if (:refused r)
        {:path (u/rel-path p) :error (:refused r)}
        {:path (u/rel-path p) :changed (> (:changed r) 0) :applied (:changed r)}))
    (catch e {:path (u/rel-path p) :error (ex-message e)})))
```

`fix-paths` walks the expanded paths, fixes the plain sources, and collects
three lists: the files it acted on, the literate documents it skipped, and the
files it could not read. `:changed` counts the files whose text actually moved;
a file with no smells is reported with `:applied 0`, not hidden.

```beam-lisp
(defn fix-paths
  "Fix every path in place under `rules`. Returns `{:files [...] :changed n
   :skipped [...] :failed [...]}`: `files` carries `{:path :changed :applied}`
   per acted-on source, `skipped` names the literate documents, and `failed`
   names a file the fixer could not read."
  [rules paths]
  (let [results (into [] (map (fn [p]
                                (if (fixable-file? p)
                                  (fix-one rules p)
                                  {:path (u/rel-path p) :skipped true}))
                              paths))
        sources (filter (fn [r] (not (:skipped r))) results)
        ok (into [] (filter (fn [r] (not (:error r))) sources))]
    {:files (into [] (map (fn [r] (dissoc r :error)) ok))
     :failed (into [] (filter (fn [r] (:error r)) sources))
     :skipped (into [] (map (fn [r] (:path r)) (filter (fn [r] (:skipped r)) results)))
     :changed (count (filter (fn [f] (:changed f)) ok))}))
```

## The report

The human report lists each file whose text changed and its rewrite count, then
the tally.

```beam-lisp
(defn render
  "The human report: a `fixed path (n)` line per changed file, then the tally."
  [report]
  (let [lines (map (fn [f] (str "fixed " (:path f) " (" (:applied f) ")"))
                   (filter (fn [f] (:changed f)) (:files report)))]
    (join "\n"
          (concat (if (empty? lines)
                    [(if (empty? (:failed report)) "no smells to fix"
                         "nothing written — see the errors below")]
                    lines)
                  [(str (u/plural (:changed report) "file") " changed, "
                        (u/plural (count (:skipped report)) "literate file") " skipped")]))))
```

## The command

`run` resolves the targets the way `bl lint` does — `src/` when no PATH is
given and that directory exists — refuses `-`, fixes the sources, and reports.
A clean sweep returns 0; a file the fixer could not read returns 1 with the
reason; a usage problem returns 2.

```beam-lisp
(defn run
  "`bl fix [PATH…] [--tier safe|idiomatic|every] [--json]`. Exit 0 when the
   sweep completes, 1 when a file could not be read, 2 on a usage error."
  [args st]
  (u/register-paths st)
  (let [rules (lint/tier-rules (:tier st))]
    (cond
      (nil? rules)
      (u/usage-error (str "bl fix: unknown tier \"" (:tier st) "\" (safe | idiomatic | every)"))

      (some (fn [a] (= a "-")) args)
      (u/usage-error "bl fix: cannot fix standard input — name a file or directory")

      :else
      (let [targets (if (empty? args)
                      (when (File/dir? (u/resolve "src")) ["src"])
                      args)]
        (if (nil? targets)
          (u/usage-error "bl fix: no PATH given and no src/ directory here")
          (let [paths (vec (mapcat u/expand-targets (map u/resolve targets)))]
            (if (empty? paths)
              (u/usage-error "bl fix: no source files found")
              (let [report (fix-paths rules paths)]
                (u/emit st report render)
                (u/each (fn [f] (u/io-err (str "bl fix: " (:path f) ": " (:error f))))
                        (:failed report))
                (if (empty? (:failed report)) 0 1)))))))))
