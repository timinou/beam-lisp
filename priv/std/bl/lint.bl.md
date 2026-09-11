# bl.lint — report the smells in beam-lisp source

`bl lint` answers one question: where does this code spell something the long
way when the language already has a short word for it? It reads the source,
finds every match of the `deodorant` ruleset, and prints one block per match.
It changes nothing — the fix half of the pair is `bl fix`.

A smell is a rule from `priv/std/deodorant.bl`, and every rule belongs to a
tier that says how much trust it needs:

- **safe** — value-identical for every input. `(if (not p) a b)` is
  `(if-not p a b)`. Apply blind.
- **idiomatic** — value-identical under a mild, near-universal assumption.
  `(= n 0)` is `(zero? n)` when `n` is a number, which at a comparison against
  `0` it always is. In the default ruleset with the safe rules.
- **reinvention** — a hand-rolled stdlib function. `(reduce (fn [acc x] (+ acc 1)) 0 xs)`
  is `count`. Exact, but it restructures more of the form, so it is opt-in.

`--tier` picks the set: `safe`, `idiomatic` (the safe+idiomatic default), or
`every` (all three, reinvention included). No `--tier` means the default.

The command exits 0 when the source is clean and 1 when it has at least one
smell, so a gate can branch on it. `--json` prints the same report as one JSON
object for a machine.

```beam-lisp
(ns bl.lint
  (:require [bl.util :as u] [deodorant] [reader-node]))
```

## Tiers name rulesets

`tier-rules` is the one place the `--tier` string meets the `deodorant`
rule queries, so `lint`, `fix` and `check` all read the same mapping. An
unknown string returns `nil`, which the command turns into a usage error
rather than silently linting with some default.

```beam-lisp
(defn tier-rules
  "The deodorant rules for a `--tier` value: nil or \"idiomatic\" is the
   default (safe + idiomatic), \"safe\" is the safe rules alone, \"every\" adds
   the reinvention tier. An unknown string returns nil so the caller can report
   a usage error."
  [tier]
  (cond
    (nil? tier)            (deodorant/all-rules)
    (= tier "idiomatic")   (deodorant/all-rules)
    (= tier "safe")        (deodorant/safe-rules)
    (= tier "every")       (deodorant/every-rule)
    :else                  nil))
```

## Where a smell lives

A match needs a place: a reader wants `file:line`, not a form with no
position. The deodorant rules match data forms, and a data form carries no
position, so the walk reads the source twice over: `reader-node` gives the
tree with a span on every node, and `node->data` converts each node back to
the ordinary form the matcher reads. One tree, two views, aligned node for
node.

`node->data` is the reader's inverse for the shapes a smell can sit inside — a
list, a vector, a symbol, a keyword, a scalar. It also converts map and set
nodes (the reader refuses those, since a map is not a form the matcher can walk
as code), so a smell whose argument is a map literal still reports the exact
before and after text.

`subnodes-with-pos` descends exactly the surface `deodorant/scan` descends —
every list and vector, itself included — and hands each node the nearest
enclosing span, so a bare symbol the reader did not wrap still names the line
of the form it sits in. Because both walks cover the same nodes, the count here
equals `deodorant/report-source` for the same source, which the tests pin.

```beam-lisp
(defn node->data
  "A reader node as the ordinary form the rules match: lists, vectors, sets and
   maps rebuilt from their children, a symbol as itself, a keyword as the
   runtime keyword, a scalar as itself. `reader-node/form` refuses map and set
   nodes; this converts them, so a smell inside a map argument still reports its
   exact before and after."
  [n]
  (let [f (reader-node/node-form n)
        tag (reader-node/node-tag f)]
    (cond
      (= tag :list)    (apply list (map node->data (reader-node/node-items n)))
      (= tag :vector)  (into [] (map node->data (reader-node/node-items n)))
      (= tag :set)     (set (map node->data (reader-node/node-items n)))
      (= tag :map)
      (Map/new
       (u/to-list
        (map (fn [t]
               (erlang/list_to_tuple
                (list (node->data (erlang/element 1 t))
                      (node->data (erlang/element 2 t)))))
             (reader-node/node-items n))))
      (= tag :symbol)  f
      (= tag :keyword) (keyword (reader-node/node-name f))
      :else            f)))

(defn- subnodes-with-pos
  "Every node of `n` paired with the source position it starts at, itself
   included, depth-first. Descends list and vector nodes — the same surface
   `deodorant/scan` walks — and gives a child without its own span the nearest
   enclosing one, so a smell always reports the line of the form it sits in."
  [n pos]
  (let [tag (reader-node/node-tag (reader-node/node-form n))
        here (or (reader-node/node-pos n) pos)]
    (cons [n here]
          (if (contains? #{:list :vector} tag)
            (mapcat (fn [c] (subnodes-with-pos c here)) (reader-node/node-items n))
            []))))

(defn- line-of
  "The 1-based line of a position map, or 0 when the node carries no span."
  [pos]
  (if (and (map? pos) (int? (:line pos))) (:line pos) 0))

```

## One source, every smell

`lint-source` folds the walk into one `{:path :smells [...]}` entry. Each smell
names the rule it matched, its tier, the line the matched form starts on, and
the before/after text — `deodorize-with` applied to that one rule, so the
`after` is the fix that rule alone would make, not the sum of all rules.

A node whose conversion or match raises is skipped rather than aborting the
sweep; a linter reports what it can read and keeps going.

```beam-lisp
(defn- smell
  "One reported smell: the rule, its tier, the starting line of the matched
   form, and the before/after text of that rule alone."
  [rule form pos]
  {:name (name (:name rule))  ; a string, so `--json` can encode it
   :tier (:tier rule)
   :line (line-of pos)
   :before (pr-str form)
   :after (pr-str (deodorant/deodorize-with (list rule) form))})

(defn lint-source
  "Every smell in one source text under `rules`: `{:path :smells [...]}`. Walks
   each node of every top-level form and reports each rule that matches there,
   the same surface and count as `deodorant/report-source`."
  [rules path src]
  (let [forms (BeamLisp.Reader/read_string src)
        smells-at
        (fn [node]
          (let [pos (second node)]
            (try
              (let [form (node->data (first node))]
                (map (fn [rule] (smell rule form pos))
                     (deodorant/matches rules form)))
              (catch _ []))))]
    {:path path
     :smells (into [] (mapcat smells-at (mapcat (fn [n] (subnodes-with-pos n nil)) forms)))}))

(defn smell-count
  "How many smells `src` holds under `rules` — the count without the positions,
   for a caller that only needs the number."
  [rules src]
  (reduce + 0 (vals (deodorant/report-source rules src))))

(defn lint-paths
  "Lint every source in `paths`, in order: `{:files [...] :total n}`, where
   `total` is the smell count across all files."
  [rules paths]
  (let [files (into [] (map (fn [p] (lint-source rules (u/rel-path p) (BeamLisp.Loader/read_source p))) paths))]
    {:files files
     :total (reduce + 0 (map (fn [f] (count (:smells f))) files))}))
```

## The report

`render` prints each smell as its location, its rule and tier, and the two
lines that show the change. The last line is the tally a gate reads.

```beam-lisp
(defn render
  "The human report: one block per smell — `path:line  name [tier]`, the before
   line, the after line — then `N smells in M files`."
  [report]
  (let [blocks
        (mapcat
         (fn [f]
           (map (fn [s]
                  (str (:path f) ":" (:line s) "  " (:name s) " [" (name (:tier s)) "]\n"
                       "    " (:before s) "\n"
                       "  → " (:after s)))
                (:smells f)))
         (:files report))]
    (join "\n"
          (concat blocks
                  [(str (u/plural (:total report) "smell") " in "
                        (u/plural (count (:files report)) "file"))]))))
```

## The command

`run` resolves the targets, lints them, prints the report the requested way,
and returns the exit code. With no PATH it lints `src/` when that directory
exists — the shape of a small project — and otherwise reports how to call it.

```beam-lisp
(defn run
  "`bl lint [PATH…] [--tier safe|idiomatic|every] [--json]`. Exit 0 when the
   sources are clean, 1 when any smell is reported, 2 on a usage error."
  [args st]
  (u/register-paths st)
  (let [rules (tier-rules (:tier st))]
    (if (nil? rules)
      (u/usage-error (str "bl lint: unknown tier \"" (:tier st) "\" (safe | idiomatic | every)"))
      (let [targets (if (empty? args)
                      (when (File/dir? (u/resolve "src")) ["src"])
                      args)]
        (if (nil? targets)
          (u/usage-error "bl lint: no PATH given and no src/ directory here")
          (let [paths (vec (mapcat u/expand-targets (map u/resolve targets)))]
            (if (empty? paths)
              (u/usage-error "bl lint: no source files found")
              (let [report (lint-paths rules paths)]
                (u/emit st report render)
                (if (zero? (:total report)) 0 1)))))))))
