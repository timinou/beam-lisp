# mcp.skill — the instruction corpus, rendered as a skill directory

An agent's tool reads a *skill* the same way a person reads a README you put on
their desk: one file it opens first, a few beside it for when the first file is
not enough. The content of those files is not written here. It is the
`:instr/for "skill"` corpus (`mcp.instructions`) — the same facts that answer
`prompts/get beam-lisp/skill` — and this namespace is the renderer: fragments
sorted by `:instr/order`, a heading per fragment, and a beam-lisp cell wherever
a fragment carries `:instr/code`.

Two consequences, both of them the point:

- **No second source.** Amend an instruction by re-asserting its `:instr/id`;
  the file, the prompt and the next `bl install mcp` all follow. A skill that
  needs editing in two places is already wrong.
- **The examples run.** `:instr/code` is a form, not a quotation of one, so
  `modules.bl.md` is a program: `bl run` it and the idioms in the map either
  work or name themselves as stale.

```beam-lisp
(ns mcp.skill
  (:require [datom] [bl.util :as u] [codebase :as cb]
            [mcp.instructions :as instr]))
```

## The skill's shape

Four files, one per `:instr/kind`. The kind names the file because on this
surface the file IS the division — an agent reads `SKILL.md` once, and comes
back to the others by name.

A `.bl.md` needs one thing a fragment cannot supply: the `(ns …)` its cells
resolve against. That is a property of the FILE — the set of modules its
examples happen to use — so it is declared here, beside the file, and emitted
only when the part actually carries code (a header over no cells is dead text).

```beam-lisp
(def skill-name
  "The directory name under an agent's skills root. One name across agents:
   the corpus is about beam-lisp, not about the client reading it."
  "beam-lisp")

(def description
  "The one line a client shows beside the skill's name — what a reader picks
   the skill BY, so it says what the reader gets, not what the corpus is."
  "beam-lisp: a Clojure-reader dialect on the BEAM — what it is, the modules worth knowing first, and how to reach the full documentation over MCP. Read before writing or reviewing beam-lisp source.")

(def parts
  "The files, in reading order. `kind` picks the fragments; `header` is the ns
   a literate part's cells resolve against; `about` is the one line SKILL.md
   uses to point at it."
  [{:path "SKILL.md"      :kind :onboarding :header nil
    :about "you are reading it"}
   {:path "modules.bl.md" :kind :modules
    :about "the module index, with every example executable"
    :header (str "(ns beam-lisp.skill.modules\n"
                 "  (:require [datom] [codebase] [web] [auth] [live]"
                 " [deodorant] [veritas]))")}
   {:path "usage.bl.md"   :kind :usage    :header nil
    :about "the day's verbs, and the habits that save a round trip"}
   {:path "protocol.bl.md" :kind :protocol :header nil
    :about "how this skill is generated — for whoever extends it"}])
```

## The corpus, mounted alone

The skill describes the LANGUAGE, so it is assembled from a connection that
carries nothing but the instruction corpus: no source is indexed, no tree is
scanned, and the answer does not depend on which project asked. Mounting is
idempotent (`:instr/id` is an identity), and the connection is in memory —
this is a renderer for a document, not a runtime for a database.

```beam-lisp
(defn db
  "A datom db value holding the instruction corpus and nothing else."
  []
  (let [conn (cb/connect-codebase)]
    (instr/mount! conn)
    (datom/db conn)))
```

## Rendering

The front-matter is the skill's identity card: `name` and `description` are how
a client decides whether to show it at all (the native loader requires the
description), and `version` is the release that wrote it — the one field that
makes a stale skill detectable instead of merely wrong.

```beam-lisp
(defn version
  "The release number this skill is written for: the CalVer tag in a built
   drop, `0.1.0` in a checkout."
  []
  (u/version))

(defn frontmatter
  []
  (join "\n"
        ["---"
         (str "name: " skill-name)
         (str "description: " (pr-str description))
         (str "version: " (version))
         "---"]))

(defn- has-code?
  "Whether any of `part`'s fragments carries a form — the question the header
   is gated on."
  [d part]
  (some (fn [frag] (some? (:code frag))) (instr/fragments d "skill" (:kind part))))

(defn- pointer
  "One line of SKILL.md's map of the other files."
  [part]
  (str "- `" (:path part) "` — " (:about part)))
```

`files` is the whole renderer. SKILL.md is the front matter, the onboarding
fragments, and the map of what sits beside it — derived from `parts`, so a
fifth file is one table row and no prose to remember. Every other part is its
kind, with the ns header in front of the cells when there are cells.

```beam-lisp
(defn files
  "The skill as [{:path :text} …], in reading order, ready to write."
  [d]
  (into []
        (map (fn [part]
               (let [body (instr/assemble-for d "skill" (:kind part))]
                 (if (= "SKILL.md" (:path part))
                   {:path (:path part)
                    :text (str (frontmatter) "\n\n# beam-lisp\n\n" body "\n\n"
                               "## The files beside this one\n\n"
                               (join "\n" (map pointer (drop 1 parts))) "\n")}
                   {:path (:path part)
                    :text (str (if (and (some? (:header part)) (has-code? d part))
                                 (str (:header part) "\n\n")
                                 "")
                               body "\n")})))
        parts)))

(defn write!
  "Write the skill into `dir` (the skill's OWN directory; this does not create
   a parent). Returns the paths written, in reading order — the report line a
   caller prints is the list it got back, not a second guess at it."
  [dir d]
  (File/mkdir_p dir)
  (mapv (fn [f]
          (let [path (str dir "/" (:path f))]
            (File/write! path (:text f))
            path))
        (files d)))
```

## Reading back

`--check` needs one question answered: is the skill on disk the one this `bl`
would write? The version line answers it, and answering it from the file the
skill *starts* with (rather than from a marker file of our own) means a skill
somebody edited by hand still reports what it says about itself.

```beam-lisp
(defn installed
  "What the skill at `dir` says about itself: {:version :path} where version is
   the `version:` line of its SKILL.md, or nil when there is no skill there."
  [dir]
  (let [path (str dir "/SKILL.md")]
    (if (not (File/regular? path))
      nil
      (let [line (some (fn [l]
                         (if (starts-with? l "version: ")
                           (String/trim (subs l (count "version: ")))
                           nil))
                       (String/split (File/read! path) "\n"))]
        {:version line :path path}))))

(defn stale?
  "Whether the installed skill was written by a different release than this
   one. A skill with no version line is stale on purpose: it cannot say what
   it describes, so it is not trusted to describe this."
  [dir]
  (let [i (installed dir)]
    (if (nil? i)
      :absent
      (if (= (:version i) (version)) :current :stale))))
```
