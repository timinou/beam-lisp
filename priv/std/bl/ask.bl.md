# bl.ask — questions about a body of code

`bl ask` answers a named question about source instead of making you write a
query. You hand it a question name, sometimes a target, and the files to look
at; you get back rows. The point is that the questions are *named*: an agent or
a person says "what breaks if I change this function" without knowing datalog,
a schema, or which helper to call.

Two kinds of question live here.

- **Database questions** read a *fact database* built from the sources: every
  definition and every call is a fact, and a question is a query over those
  facts. `impact`, `callers`, `reachable`, `returns-type`, `arity-mismatches`
  and `unknown-callees` are these. They answer about a whole *set* of files at
  once, because facts from every file land in one database.
- **File questions** read one file's inter-procedural analysis — the call graph
  with its proofs. `dead-code` and `symbols` are these. They answer about each
  file on its own, because a summary belongs to the program it summarizes.

Both kinds share one table of question descriptors, so the CLI and the MCP
server describe and validate the same surface from the same place. That is the
whole reason this namespace exists separately from either front door: a question
has ONE definition, and every interface projects it.

```beam-lisp
(ns bl.ask
  (:require [bl.util :as u]
            [codebase]
            [code.index]
            [typed]
            [datom]
            [datom.conn]
            [datom.store-fjall]
            [lsp]))
```

## The question table

A question is a small record: its name, whether it needs a target, which kind of
reading it performs, and one line saying what it answers. The table is the
surface; everything else here is plumbing that serves it.

`needs-target?` is what an interface reads to decide whether to ask for the
missing piece. `scope` is what this namespace reads to decide whether to open a
database or read a file. The MCP server only speaks the database questions, so
it validates with `db-question?` and keeps its own MRTR envelope around them.

```beam-lisp
(def ^:private table
  [{:name "impact"
    :needs-target? true
    :scope :db
    :doc "every fn that transitively calls TARGET — what breaks if it changes"}
   {:name "callers"
    :needs-target? true
    :scope :db
    :doc "direct callers of TARGET, each with its call site"}
   {:name "reachable"
    :needs-target? true
    :scope :db
    :doc "every fn TARGET transitively calls"}
   {:name "returns-type"
    :needs-target? true
    :scope :db
    :doc "fns whose return may include the type tag TARGET (e.g. string)"}
   {:name "arity-mismatches"
    :needs-target? false
    :scope :db
    :doc "calls whose callee is defined but never at the called arity"}
   {:name "unknown-callees"
    :needs-target? false
    :scope :db
    :doc "calls to names never defined, not core, not interop"}
   {:name "dead-code"
    :needs-target? false
    :scope :source
    :doc "fns unreachable from a file's own top-level entry points"}
   {:name "symbols"
    :needs-target? false
    :scope :source
    :doc "every definition with its proven summary: returns, purity, termination, growth"}])

(defn questions
  "Every question this namespace answers, as descriptors."
  []
  table)

(defn question-def
  "The descriptor for `name`, or nil when there is no such question."
  [name]
  (first (filter (fn [q] (= name (:name q))) table)))

(defn db-question?
  "Whether `name` is one of the questions a fact database answers."
  [name]
  (let [q (question-def name)]
    (and (some? q) (= :db (:scope q)))))

(defn needs-target?
  "Whether `name` is a question about one function. A name with no descriptor
   needs nothing — it is not a question at all."
  [name]
  (let [q (question-def name)]
    (if (nil? q) false (:needs-target? q))))

(defn db-questions
  "The names of the questions a fact database answers, in table order."
  []
  (map (fn [q] (:name q)) (filter (fn [q] (= :db (:scope q))) table)))
```

## Indexing: sources become facts

The database questions need facts. `index!` reads each source, asks the reader
for its forms, and asks `codebase/index-source` for the definitions and calls in
them. A file's namespace is `bl.util/ns-of` — its first `(ns NAME …)` form — so the
facts carry the namespace the author wrote; a file with no such form is
`"user"`.

Every file's facts land in ONE connection, so a question reaches across all of
them. `codebase/index-source` numbers entities from fixed bases, so two files
would otherwise overwrite each other's rows; `index!` shifts each file's ids by
a per-file delta. Entities join by name (`:fn/name`, `:call/caller`), never by
id, so shifting ids changes nothing a query can see.

Two things keep indexing cheap enough to run on every question. The facts of
every file are gathered first and written in a few large transactions rather
than one per file: a transaction has a fixed cost on top of its facts, so
batches of `tx-batch` facts halve the write time of a per-file loop while
staying well inside the connection's write deadline. And the facts of a file are a
pure function of its text, so they are cached by content hash under the
analysis store directory (`codebase/blanalysis-dir`): a file that has not
changed since the last question is read back as data instead of re-walked.
The cache is never load-bearing — a missing or unreadable entry is a fresh
index, and a changed byte changes the hash, so a stale entry is unreachable.

```beam-lisp
(defn- offset-facts
  "Shift every fact's :db/id by `delta` so files never share an id."
  [facts delta]
  (u/to-list (map (fn [f] (assoc f :db/id (+ (get f :db/id) delta))) facts)))

(defn- cache-path
  "Where one cached ANALYSIS of a source with content hash `sha` lives. `kind`
   says what was computed: `facts` is the indexer's facts (what a datalog
   question is answered from), `symbols` the analyser's document symbols (what a
   source question is answered from).

   Under the project of the SOURCES being asked about, not the shell's: an
   artifact derived from a tree belongs to that tree."
  [kind sha root]
  (str (codebase/blanalysis-dir root) "/" kind "." sha ".term"))

(defn- cached-analysis
  "The `kind` analysis remembered for `sha`, or nil."
  [kind sha root]
  (let [p (cache-path kind sha root)]
    (when (File/exists? p)
      (try (erlang/binary_to_term (File/read! p)) (catch _ nil)))))

(defn- remember-analysis!
  "Store `value` as the `kind` analysis of `sha`; a failure to write is silently
   a cache miss next time."
  [kind sha value root]
  (try
    (File/mkdir_p (codebase/blanalysis-dir root))
    (File/write! (cache-path kind sha root) (erlang/term_to_binary value))
    (catch _ nil)))

(defn source-facts
  "`{:ns :fn :calls}` for one source text: the file's namespace and its
   definition and call facts, from the cache when this exact text has been
   indexed before."
  [sigs src root]
  (let [sha (sha256-hex src)]
    (or (cached-analysis "facts" sha root)
        (let [ns-str (u/ns-of src)
              facts (codebase/index-source sigs ns-str src)
              entry {:ns ns-str :fn (u/to-list (:fn facts)) :calls (u/to-list (:calls facts))}]
          (remember-analysis! "facts" sha entry root)
          entry))))

(def tx-batch
  "Facts per transaction. Large enough to amortise the per-transaction cost,
   small enough that one write finishes long before the writer's deadline."
  2000)

(defn index!
  "Index every source in `paths` into `conn` under `sigs` (the type seeds the
   indexer reads return annotations against). Facts from all paths share the
   one connection, written `tx-batch` at a time; each file's ids are offset so
   files never collide. Returns the namespaces indexed, in path order."
  ([conn sigs paths] (index! conn sigs paths (first (u/to-list paths))))
  ([conn sigs paths root]
  (let [entries (loop [ps (u/to-list paths) i 0 nss [] facts []]
                  (if (empty? ps)
                    {:nss nss :facts facts}
                    (let [e (source-facts sigs (File/read! (first ps)) root)
                          delta (* i 1000000)]
                      (recur (rest ps) (+ i 1) (conj nss (:ns e))
                             (into facts (concat (offset-facts (:fn e) delta)
                                                 (offset-facts (:calls e) delta)))))))]
    (u/each (fn [batch] (datom/transact! conn (u/to-list batch)))
            (Enum/chunk_every (u/to-list (:facts entries)) tx-batch))
    (:nss entries))))
```

Writing facts into a store is the slow half of a question — tens of seconds
for a few hundred files — and the facts of a given SET of sources are a pure
function of their texts. So a whole indexed set is kept as one persistent datom
store, named by the hash of every file's content hash in order. Asking again
about unchanged sources reopens that store in milliseconds; changing any file
changes the set's hash and indexes afresh. Without the persistent backend the
set lives in memory for this run only — the same answers, just not remembered.

```beam-lisp
(defn- set-hash
  "One content hash for an ordered set of sources."
  [paths]
  (sha256-hex
    (join "\n" (map (fn [p] (sha256-hex (File/read! p))) (u/to-list paths)))))

(defn- set-store-path [hash root]
  (str (codebase/blanalysis-dir root) "/askset." hash ".fjall"))

(defn connect-set!
  "A connection holding the facts of every source in `paths`: reopened from the
   persistent set store when this exact set has been indexed before, otherwise
   indexed and stored. Returns `{:conn :nss}`.

   The tree's own sources FIRST, through `code.index`: when the question is
   about the tree the caller stands in — no `-p`, which is most of them — the
   daemon has already indexed exactly these sources, and reusing its conn costs
   a hash of each file (tens of ms) instead of reopening a store or re-indexing
   anything. The askset below is the fallback for a question about a DIFFERENT
   set of sources (an explicit `-p`, a single file), where the set really is a
   different corpus."
  [sigs paths]
  (let [paths (u/to-list paths)
        root (first paths)
        nss-of (fn [] (u/to-list (map (fn [p] (u/ns-of (BeamLisp.Loader/read_source p))) paths)))
        shared (try (code.index/reuse-for-paths (BeamLisp/cwd) paths) (catch e nil))]
    (if (some? shared)
      {:conn (:conn shared) :nss (nss-of)}
      (do
        ; The store's host module exists only once the namespace declaring it has
        ; been initialized, and nothing on this path loads it: without this the ask
        ; set is rebuilt every run. Inline for the same reason `bl.search` is (see
        ; the note there — a helper in `codebase` or `bl.cache` cycles the AOT build).
        (try (BeamLisp.AOT/ensure_loaded "datom.store-fjall") (catch e nil))
        (if (not (datom.store-fjall/available?))
          (let [conn (codebase/connect-codebase)]
            {:conn conn :nss (index! conn sigs paths)})
          (let [path (set-store-path (set-hash paths) root)]
            (if (File/exists? path)
              {:conn (datom.conn/connect-with (datom.store-fjall/open path))
               :nss (nss-of)}
              (do
                (File/mkdir_p (codebase/blanalysis-dir root))
                (let [store (datom.store-fjall/open path)
                      conn (datom.conn/connect-with store codebase/SCHEMA)
                      nss (index! conn sigs paths)]
                  (datom.store-fjall/sync! store)
                  {:conn conn :nss nss})))))))))
```

## Answering a database question

`answer` is the one place a database question becomes rows. `core-names` is the
"always defined" set — every public name of core plus of each indexed namespace
— so the `unknown-callees` question reports a call as unknown only when nothing
could define it.

Rows come back as plain lists so a JSON printer and a text printer read the same
value. `:unknown-question` is the honest answer when the name is not a database
question; an interface validates first, so it never reaches here.

```beam-lisp
(defn- rows-of [rows]
  (u/to-list (map u/to-list rows)))

(defn- code-rows
  "Rows naming a function in the codebase. Interop/host ops (a name with a
   slash) are calls the codebase records but not functions it defines, so a
   question about the call graph answers with the functions."
  [rows]
  (rows-of (filter (fn [r] (not (codebase/interop-name? (first r)))) rows)))

(defn answer
  "Answer the database `question` about `target` (target is ignored by the
   questions that take none). `core-names` is the always-defined set for
   unknown-callees. Rows are plain lists; `:unknown-question` when `question`
   is not a database question."
  [db question target core-names]
  (cond
    (= question "impact")
      (rows-of (codebase/impact db target))

    (= question "reachable")
      (code-rows (codebase/reachable db target))

    (= question "arity-mismatches")
      (rows-of (codebase/arity-mismatches db))

    (= question "unknown-callees")
      (rows-of (codebase/unknown-callees db core-names))

    (= question "callers")
      (rows-of (datom/q '[:find ?caller ?line
                          :in $ ?t
                          :where [?c :call/callee ?t]
                                 [?c :call/caller ?caller]
                                 [?c :call/line ?line]]
                        db target))

    (= question "returns-type")
      (rows-of (datom/q '[:find ?name ?src
                          :in $ ?wanted
                          :where [?d :fn/name ?name]
                                 [?d :fn/ret-tag ?wanted]
                                 [?d :fn/ret-source ?src]]
                        db target))

    :else :unknown-question))
```

## Answering a file question

A file question reads one source's inter-procedural summary. `dead-code` needs
the roots to measure liveness from: the functions the file's *own top-level code*
refers to — the script's entry points. A definition nothing at top level
mentions is a candidate for dead, and liveness flows through the call graph
(including higher-order calls), so a function used only as a callback stays
live. A file with no top-level reference at all is a library with no declared
entry point, so every definition counts as a root and nothing is reported dead —
a false negative is the honest side to err on for a claim of "dead".

`symbols` reads `lsp/document-symbols`: every definition with the summary the
analyzer proved about it. Each row is `file name returns purity termination
growth`: the first five cells are the proven summary, and `growth` is the
recursion's growth label (`O(n)` / `>= O(n^2)` / `O(2^n)`), empty when the
definition is not self-recursive.

```beam-lisp
(defn- node-refs
  "Every symbol name appearing anywhere under reader node `n`."
  [n]
  (let [n (typed/node-form n)
        tag (typed/node-tag n)]
    (cond
      (= tag :symbol) [(typed/node-name n)]
      (contains? #{:list :vector :set} tag) (mapcat node-refs (typed/node-items n))
      (= tag :map)
        (mapcat (fn [pair]
                  (let [[k v] (erlang/tuple_to_list pair)]
                    (concat (node-refs k) (node-refs v))))
                (typed/node-items n))
      :else [])))

(defn- defn-form?
  "Whether a top-level form is a (defn …) or (defn- …) definition."
  [form]
  (let [f (typed/node-form form)]
    (if (not= :list (typed/node-tag f))
      false
      (let [head (first (typed/node-items f))]
        (and (some? head)
             (= :symbol (typed/node-tag (typed/node-form head)))
             (contains? #{"defn" "defn-"} (typed/node-name (typed/node-form head))))))))

(defn symbols-of
  "The document symbols of `src` — what a source question is answered from. The
   analysis costs seconds a file, so a question asked twice over the same text
   pays for it once: content-addressed, so an edit is a new entry and an
   unchanged file is a hit. Every source question shares it, which is why
   `dead-code` — two analyses' worth — costs one."
  [src root]
  (let [sha (sha256-hex src)]
    (or (cached-analysis "symbols" sha root)
        (let [syms (u/to-list (lsp/document-symbols src))]
          (remember-analysis! "symbols" sha syms root)
          syms))))

(defn roots
  "The definitions a source's own top-level code refers to — its entry points.
   A source with none is a library, so every definition is a root. The symbols
   are passed in when the caller already has them: analyzing one file twice to
   answer one question is the cost this file exists to avoid."
  ([src] (roots src (u/to-list (lsp/document-symbols src))))
  ([src syms]
  (let [names (set (map (fn [s] (:name s)) (u/to-list syms)))
        forms (BeamLisp.Reader/read_string src)
        refs (mapcat (fn [f] (if (defn-form? f) [] (node-refs f))) forms)
        rs (distinct (filter (fn [r] (contains? names r)) refs))]
    (if (empty? rs) (into [] names) rs))))

(defn- tag-str [t]
  (if (keyword? t) (name t) (pr-str t)))

(defn- returns-str [s]
  (let [rs (u/to-list (:returns s))]
    (if (empty? rs) "?" (join "|" (map tag-str rs)))))

(defn source-rows
  "Answer the file `question` for one source: rows are plain lists whose first
   cell names the file. `:unknown-question` when `question` is not a file
   question. `root` is the corpus the answer is remembered under."
  [question path src root]
  (let [path (u/rel-path path)]
    (cond
      (= question "dead-code")
        (let [syms (symbols-of src root)]
          (u/to-list (map (fn [n] (u/to-list [path n]))
                          (u/to-list (lsp/dead-code src (roots src syms))))))

      (= question "symbols")
        (u/to-list (map (fn [s] (u/to-list [path (:name s) (returns-str s)
                                            (:pure s) (:terminates s)
                                            (:growth-label s)]))
                        (symbols-of src root)))

      :else :unknown-question)))
```

## Rendering

Both kinds of answer come back as rows, so one renderer serves both. It prints a
header naming the question (and target, when there is one), then one row per
line with cells separated by tabs — the shape a person reads and a shell can
cut. An empty answer says `no results` rather than printing a bare header.

```beam-lisp
(defn- cell [x]
  (cond
    (nil? x) ""
    (keyword? x) (name x)
    (= x true) "yes"
    (= x false) "no"
    :else (str x)))

(defn render
  "The text form of an answer: a header line, then one tab-separated row per
   line. `no results` when there are no rows."
  [data]
  (let [rows (u/to-list (:rows data))
        head (if (nil? (:target data))
               (:question data)
               (str (:question data) " " (:target data)))]
    (join "\n"
          (concat [head]
                  (if (empty? rows)
                    ["no results"]
                    (map (fn [r] (join "\t" (map cell (u/to-list r)))) rows))))))
```

## The verb

`run` is the glue between the table and the two answer paths. It decides whether
a target is needed, expands the path arguments into sources, opens a database or
reads files, and prints the answer through `u/emit` — text by default, one JSON
object under `--json`.

Paths default to `src/` when that directory exists. A question that is valid
exits 0 even when it finds no rows; a bad invocation exits 2.

```beam-lisp
(defn- question-usage []
  (println "bl ask — ask a named question of a body of code")
  (println "")
  (println "usage: bl ask QUESTION [TARGET] [PATH...] [--json]")
  (println "")
  (println "questions:")
  (u/each (fn [q]
            (println (str "  " (:name q)
                          (if (:needs-target? q) " TARGET" "       ")
                          "  " (:doc q))))
          (questions))
  (println "")
  (println "TARGET is the function name (returns-type: the type tag) the question is about.")
  (println "PATH defaults to src/ when that directory exists."))

(defn- default-paths []
  (if (File/exists? (u/resolve "src")) ["src"] []))

(defn- run-db [qname target sources st]
  (let [sigs (merge typed/core-sigs typed/core-seeds-v2 typed/host-seeds)
        set (connect-set! sigs sources)
        conn (:conn set)
        nss (:nss set)
        core-names (reduce (fn [s n] (into s (codebase/core-callee-names n))) #{} nss)
        rows (answer (datom/db conn) qname target core-names)
        data {:question qname :target target :rows rows :count (count rows)}]
    (u/emit st data render)
    0))

(defn- run-source [qname sources st]
  (let [; The SOURCES decide where the analysis is remembered, as they do for the
        ; store: a question about a checkout elsewhere caches there.
        root (first sources)
        rows (u/to-list
               (mapcat (fn [p] (source-rows qname p (File/read! p) root)) sources))
        data {:question qname :target nil :rows rows :count (count rows)}]
    (u/emit st data render)
    0))

(defn run
  "`bl ask QUESTION [TARGET] [PATH…] [--json]`. A target question takes the
   function name next; the rest take a path there. Returns 0 for any valid
   question (even one with no rows), 2 for a bad invocation."
  [args st]
  (u/register-paths st)
  (let [qname (first args)
        qd (question-def qname)
        given (if (:needs-target? qd) (u/to-list (rest (rest args)))
                                   (u/to-list (rest args)))
        paths (if (empty? given) (default-paths) given)]
    (cond
      (nil? qname)
      (do (question-usage) 2)

      (nil? qd)
      (do (u/io-err (str "bl ask: unknown question \"" qname "\""))
          (question-usage)
          2)

      (and (:needs-target? qd) (nil? (second args)))
      (u/usage-error (str "bl ask " qname ": needs a TARGET — " (:doc qd)))

      (empty? paths)
      (do (u/io-err "bl ask: no PATH given and no src/ directory here")
          (question-usage)
          2)

      :else
      (let [sources (u/to-list (mapcat u/expand-targets (map u/resolve paths)))]
        (if (empty? sources)
          (do (u/io-err (str "bl ask " qname ": no sources under " (join ", " paths)))
              (question-usage)
              2)
          (if (= :db (:scope qd))
            (run-db qname (if (:needs-target? qd) (second args) nil) sources st)
            (run-source qname sources st)))))))
```
