# mcp.instructions — instructions are facts; a prompt is a query result

Every agent surface in beam-lisp needs instructions: what this thing is, how
not to misuse it, how to do the day's work. The usual answer is a markdown
file that drifts from the tool it describes. The maximalist answer: the
instructions are **datoms in the same database that holds the code facts**,
and a prompt — MCP `prompts/get`, the files `bl install mcp` writes, the
`instructions` key on `server/discover` — is one datalog query over them.

One corpus, every projection. The files and the prompts cannot drift, because
both are the same facts rendered.

## The schema

Six attributes describe an instruction fragment — they live in
codebase/SCHEMA, because the indexer itself emits them: any namespace can
carry an instruction COLOCATED with the code it describes,

```beam-lisp
(ns ^{:instr {:for "mcp" :kind :usage :order 25
              :title "Reachability: bind the target"
              :text "…"}}
  my.ns)
```

and the same `^{:instr …}` works on a defn name. This file is the other
authoring style: a separate corpus document, for instructions that describe a
whole surface rather than one namespace. One fact space, both styles.

`:instr/id` is a unique identity — re-asserting the same id rewrites the
fragment, which is how an existing instruction is amended. `:instr/for` names
the surface the fragment addresses (`"mcp"` here; an editor extension would
take `"doom"`), so one database can hold every surface's instructions side by
side. `:instr/kind` separates what an agent reads once from what it re-reads
daily:

- `onboarding` — first contact. What this is, the wire, the model, the rules
  of engagement. Fetched once, before the first tool call.
- `usage` — the day-to-day grammar. Tools, named questions, recipes, cost
  discipline. Re-fetched on task start.
- `protocol` — how the instruction layer itself works (this schema, the
  kinds, how to compose new fragments). Fetched when extending.

The id space starts far above the code-fact ids (codebase.bl uses fixed
bases, offset per mounted file; the test seam asserts near 9000000), so
instruction entities never collide with fn/call entities in the same conn.

```beam-lisp
(ns mcp.instructions
  (:require [datom]))

(def ID-BASE 900000000)
```

## The corpus: onboarding

What an agent must know before its first tool call. Each fragment is one
idea, in the order it should be read; orders step by 10 so a later fragment
slots between two existing ones without renumbering.

```beam-lisp
(def onboarding
  [{:instr/id "mcp/onboarding/what"
    :instr/for "mcp" :instr/kind :onboarding :instr/order 10
    :instr/title "What you are holding"
    :instr/text
    "beam-lisp is a Clojure-reader dialect on the BEAM whose source is indexed as a fact database. This MCP server IS that database, live: beam-lisp has mounted its own engine into datom — an immutable, queryable store of fn and call facts. You never read files through this server. You ask questions, and only answers (rows) cross the wire."}

   {:instr/id "mcp/onboarding/wire"
    :instr/for "mcp" :instr/kind :onboarding :instr/order 20
    :instr/title "The wire"
    :instr/text
    "One JSON-RPC 2.0 object per line on stdio. TWO lifecycles are served, and the one you open with decides the shape of every answer after it. Modern (2026-07-28): the version travels in _meta[\"io.modelcontextprotocol/protocolVersion\"], the first move is server/discover → capabilities, serverInfo and these instructions, and a tool answers with bare rows. Classic (2025-06-18 and older): open with initialize, carrying the version in params; a revision we do not know is negotiated down rather than refused, and tool results come back in the content[] envelope that revision requires, with the rows repeated in structuredContent. A notification (no id) is NEVER answered — not with a result, not with an error. An unknown method answers -32601; a stated version the server does not speak answers -32022."}

   {:instr/id "mcp/onboarding/model"
    :instr/for "mcp" :instr/kind :onboarding :instr/order 30
    :instr/title "The model: source is facts, questions are queries"
    :instr/text
    "Every definition is an entity: :fn/name, :fn/ns, :fn/arity, :fn/line, :fn/ret-tag (a PROVEN return type — annotated from ^{:ret …} or inferred). Every call is an entity: :call/caller, :call/callee, :call/arity, :call/line. Two ways to ask: code/ask for named questions (impact, callers, reachable, returns-type, arity-mismatches, unknown-callees), code/query for raw datalog when the question has no name yet. In code/query, $ is the database and % is the reachability rules ((reaches ?a ?b)). ALWAYS bind your target via an :in scalar — a free variable inside a rule means \"reaches anything\", not \"reaches X\". JSON has no keywords and no symbols, so write a query as the strings you would read aloud: [\":find\" \"?caller\" \":where\" [\"?c\" \":call/callee\" \"walk-calls\"] [\"?c\" \":call/caller\" \"?caller\"]]. A leading : is a keyword, a leading ? is a variable, $ % and _ are themselves, and every other string stays the data value it is — which is how the callee name above matches."}

   {:instr/id "mcp/onboarding/mrtr"
    :instr/for "mcp" :instr/kind :onboarding :instr/order 40
    :instr/title "Elicitation (MRTR)"
    :instr/text
    "A question that needs a target and got none does not fail — it answers resultType: input_required with an elicitation schema. Retry the same tools/call with inputResponses: {\"target\": \"<fn>\"} as a SIBLING of name and arguments inside params — not inside arguments, where it is ignored and the server simply elicits again. Never guess a target; let the server ask."}

   {:instr/id "mcp/onboarding/verify"
    :instr/for "mcp" :instr/kind :onboarding :instr/order 50
    :instr/title "Two tools no indexer has"
    :instr/text
    "code/verify takes the source of a defserver carrying ^{:invariant …} and PROVES the invariant with z3 — verdict: holds is a machine-checked fact, and with repair: true a violation returns the weakest guard. Read the COVERAGE beside the verdict: :complete false means some transition's next-state could not be modelled and was therefore NOT checked, and :unmodelled names them — a partial proof, never a total one. code/subscribe + code/poll watch the fact space itself: subscribe to a callee, then poll to drain \"fn X gained or lost a caller\" events."}

   {:instr/id "mcp/onboarding/rules"
    :instr/for "mcp" :instr/kind :onboarding :instr/order 60
    :instr/title "Rules of engagement"
    :instr/text
    "1. Ask named questions first (code/ask); drop to code/query only when the question has no name. 2. Project to rows — filter inside the query, never in your context. 3. Fetch the beam-lisp/usage prompt (prompts/get) before your first real task. 4. Trust verdicts, not vibes — but read a verdict WITH its coverage: `holds` is proved for every transition the checker could model, and `:complete false` (with `:unmodelled`) is a partial proof, so `holds` beside it is not a promise about every state and input. 5. Fetch beam-lisp/protocol before you extend or amend these instructions."}])
```

## The corpus: usage

The day-to-day grammar. The tool table itself is NOT here — it is live data,
assembled from the server's registry at read time (see `prompt` below), so a
new tool appears in the usage prompt the moment it is registered.

```beam-lisp
(def usage
  [{:instr/id "mcp/usage/answers"
    :instr/for "mcp" :instr/kind :usage :instr/order 10
    :instr/title "Answers cross the wire, never files"
    :instr/text
    "Every tool answers with rows. tools/list carries ttlMs: 60000 — repeat reads inside a minute are cacheable. The live registry (tools, mounted namespaces, fact counts) follows at the end of this prompt, read from the server the moment you asked."}

   {:instr/id "mcp/usage/recipes"
    :instr/for "mcp" :instr/kind :usage :instr/order 20
    :instr/title "Recipes"
    :instr/text
    "What breaks if I change X? → code/ask {question: \"impact\", target: \"X\"} (transitive callers). Who calls X right now, and at which line? → code/ask {question: \"callers\", target: \"X\"}. What does X need? → \"reachable\". Which fns produce a string? → \"returns-type\" with target \"string\". Is this state machine safe? → code/verify {source, repair: true}. Did anything start calling my fn? → code/subscribe {callee} then code/poll {subscription}. Anything odd in this tree? → \"arity-mismatches\", \"unknown-callees\", \"dead-code\" (no target needed). A question with no name → code/query with your own datalog."}

   {:instr/id "mcp/usage/resources"
    :instr/for "mcp" :instr/kind :usage :instr/order 30
    :instr/title "Resources"
    :instr/text
    "code://beam-lisp/schema is the full fact vocabulary (read it before writing datalog). code://beam-lisp/namespaces says what is mounted right now. Both are read-only."}

   {:instr/id "mcp/usage/cost"
    :instr/for "mcp" :instr/kind :usage :instr/order 40
    :instr/title "Cost discipline"
    :instr/text
    "Name the question instead of reading the file. Keep :find to the columns you need — every extra column is tokens. Prefer a subscribe/poll pair over re-asking the same question in a loop. If a datalog answer looks too big, the bug is usually an unbound target — bind it via :in and ask again."}])
```

## The corpus: protocol

The meta layer: how instructions work in beam-lisp, told to the agent that
is about to extend them. This is the piece a static file can never be — the
instructions describing themselves, queryably.

```beam-lisp
(def protocol
  [{:instr/id "mcp/protocol/facts"
    :instr/for "mcp" :instr/kind :protocol :instr/order 10
    :instr/title "Instructions are facts"
    :instr/text
    "These words are not a file. They are datoms — entities with :instr/id, :instr/for, :instr/kind, :instr/order, :instr/title, :instr/text — transacted into the same database that holds the code facts, at mount time. Query them yourself: code/query [:find ?order ?title ?text :where [?i :instr/for \"mcp\"] [?i :instr/kind :usage] [?i :instr/order ?order] [?i :instr/title ?title] [?i :instr/text ?text]]. A prompt is a query result: kind filter, order sort, join. Nothing else."}

   {:instr/id "mcp/protocol/kinds"
    :instr/for "mcp" :instr/kind :protocol :instr/order 20
    :instr/title "Onboarding is not usage"
    :instr/text
    ":instr/kind separates what you read once (onboarding: what this is, how not to misuse it) from what you re-read daily (usage: the grammar of doing) from the meta layer (protocol: this text). Fetch onboarding at first contact, usage on task start, protocol when extending. Never merge them into one blob — the kinds exist so each reading habit gets exactly its own text."}

   {:instr/id "mcp/protocol/compose"
    :instr/for "mcp" :instr/kind :protocol :instr/order 30
    :instr/title "Composing new instructions"
    :instr/text
    "Any surface adds instructions by transacting more facts: pick an :instr/for (\"mcp\", \"doom\", \"cli\" — one per surface), take an :instr/order in the gaps (10, 20, 30 …), give the fragment a stable :instr/id. The id is a unique identity, so re-asserting the same id AMENDS the fragment in place. Two authoring styles, one fact space: a separate corpus document (like this one) for instructions about a whole surface, or ^{:instr …} on the ns/defn NAME for an instruction colocated with the code it describes — the indexer (codebase.bl) emits those as the same facts. bl install mcp projects this corpus into markdown files — the files and the prompts cannot drift, because both are projections of one corpus."}

   {:instr/id "mcp/protocol/covenant"
    :instr/for "mcp" :instr/kind :protocol :instr/order 40
    :instr/title "The covenant"
    :instr/text
    "One corpus, every surface. If an instruction is worth saying to an agent over MCP, it is worth saying identically in the bl install mcp files and in any editor onboarding. Add it as a fact once; every projection picks it up. An instruction that lives in only one projection is a bug."}])

```

## The corpus: skill

The same facts, addressed to a reader who has no database yet. `:instr/for
"skill"` is the surface an agent meets **before** its first tool call: what
beam-lisp is, which modules are worth knowing first, and where the rest of the
documentation lives.

On this surface a `:instr/kind` names the **file** the fragments land in, which
is how one corpus becomes a skill directory:

| kind | file | who reads it |
|---|---|---|
| `:onboarding` | `SKILL.md` | the agent, on first contact |
| `:modules` | `modules.bl.md` | whoever wants the calls, running |
| `:usage` | `usage.bl.md` | the agent, on task start |
| `:protocol` | `protocol.bl.md` | whoever extends the skill |

A fragment may carry `:instr/code` beside `:instr/text`: a form the module
index shows *and a test can run*, so an idiom that stops being true fails the
suite instead of misleading a reader. `mcp.skill` renders both; the
`beam-lisp/skill` MCP prompt renders the same facts without the fences.

```beam-lisp
(def skill-orientation
  [{:instr/id "skill/onboarding/what"
    :instr/for "skill" :instr/kind :onboarding :instr/order 10
    :instr/title "What beam-lisp is"
    :instr/text
    "beam-lisp is a Clojure-reader dialect on the BEAM: Clojure's syntax and data model (lists, vectors, maps, sets, keywords, symbols, lazy seqs, destructuring, protocols, multimethods) running on Erlang's runtime (cheap processes, message passing, supervisors, per-process heaps), with total type inference and logic solvers on top. Two habits carry you through the first day. Values are IMMUTABLE — you build a new one rather than changing the one you have — and a namespace is named by its `(ns …)` head, its functions called as `(ns/fn …)` and pulled in with `:require [ns :as alias]`. It is a dialect, not Clojure: where the two might disagree, ask `bl eval` rather than assume."}

   {:instr/id "skill/modules/map"
    :instr/for "skill" :instr/kind :modules :instr/order 10
    :instr/title "Modules worth knowing first"
    :instr/text
    "Seven names answer most questions, each with the handful of calls that carry it.\n\n- **datom** — the database: facts in, datalog out, time for free. `(datom/connect SCHEMA)` · `(datom/transact! conn facts)` · `(datom/q '[:find ?e :where …] (datom/db conn))` · `(datom/pull db '[*] eid)` · `(datom/as-of db t)` / `(datom/history db)`.\n- **codebase** — the source index: every definition and call as a fact. `^{:ret \"string\"}` / `^{:instr {…}}` annotations on a name · `(codebase/index-source sigs ns src)` · `(codebase/transact-source! conn sigs ns src)` · `(codebase/connect-codebase extra)`.\n- **web** — the HTTP edge, on Bandit. `(web/serve {:port 4000 :plug router})` · `(web/text conn \"ok\")` · `(web/json conn data)` · `(web/html conn s)` · `(web/read-body conn)` / `(web/form-params conn)` — a plug is one function, conn in, conn out.\n- **auth** — capability tokens, offline. `(auth/keypair)` · `(auth/issue root facts)` · `(auth/attenuate token spec)` · `(auth/authorize root-pub token ctx)` · `(auth/guard query filters)` — the last is row-level security: one query, filtered per principal.\n- **live** — live queries that are allowed to be live. `(live/check-query q)` says whether a query is monotone · `(live/register-live! conn query inputs ns cb-name)` gates on that before watching · `(live/violations …)` names every reason a query cannot be watched.\n- **deodorant** — the linter and the fixer. `(deodorant/rules-of-tier :safe)` · `(deodorant/scan rules form)` (pure, changes nothing) · `(deodorant/report rules form)` (a count per smell) · `(deodorant/fix-file! path)` — the same rule set behind `bl lint` and `bl fix`.\n- **veritas** — properties, checked rather than hoped. `(veritas/int-of lo hi)` / `(veritas/string-of prefix min max)` generators · `(veritas/for-all port var gen pred)` · `(veritas/exists port var gen pred)` · `(veritas/covers port fn-src gen)` — verdicts are modal: `:proven`, `:refuted` (with a witness), `:witnessed` (sampled, not proved)."}

   {:instr/id "skill/modules/datom"
    :instr/for "skill" :instr/kind :modules :instr/order 20
    :instr/title "datom, executed"
    :instr/code
    "(let [conn (datom/connect [{:db/ident :note/body :db/valueType :db.type/string}])]\n  (datom/transact! conn [{:db/id -1 :note/body \"hello\"}])\n  (first (first (datom/q '[:find ?b :where [?n :note/body ?b]] (datom/db conn)))))"}

   {:instr/id "skill/modules/codebase"
    :instr/for "skill" :instr/kind :modules :instr/order 30
    :instr/title "codebase, executed"
    :instr/code
    "(count (get (codebase/index-source [] \"demo\" \"(ns demo)\\n(defn add [a b] (+ a b))\") :fn))"}

   {:instr/id "skill/modules/web"
    :instr/for "skill" :instr/kind :modules :instr/order 40
    :instr/title "web, executed"
    :instr/text
    "The one shape, because it is the whole idea: a plug is a one-argument function, conn in, conn out, and `web/serve` is what wraps it in Bandit. Of all the modules here this is the one whose calls only mean something with a live request in hand, so the example shows the shape rather than a round trip."
    :instr/code
    "(fn? (fn [conn] (web/text conn \"ok\")))"}

   {:instr/id "skill/modules/auth"
    :instr/for "skill" :instr/kind :modules :instr/order 50
    :instr/title "auth, executed"
    :instr/code
    "(let [kp (auth/keypair)\n      token (auth/issue kp [[\"right\" \"doc-42\" \"read\"]])\n      public (auth/public kp)]\n  (auth/verify public token))"}

   {:instr/id "skill/modules/live"
    :instr/for "skill" :instr/kind :modules :instr/order 60
    :instr/title "live, executed"
    :instr/code
    "(get (live/check-query '[:find ?e :where [?e :note/body _]]) :monotone)"}

   {:instr/id "skill/modules/deodorant"
    :instr/for "skill" :instr/kind :modules :instr/order 70
    :instr/title "deodorant, executed"
    :instr/code
    "(deodorant/report (deodorant/every-rule) '(if (not (nil? x)) 1 2))"}

   {:instr/id "skill/modules/veritas"
    :instr/for "skill" :instr/kind :modules :instr/order 80
    :instr/title "veritas, executed"
    :instr/code
    "(veritas/holds? \"v\" '(> v 0) 3)"}

   {:instr/id "skill/onboarding/docs"
    :instr/for "skill" :instr/kind :onboarding :instr/order 30
    :instr/title "Getting the full documentation"
    :instr/text
    "This skill is the doorway, not the room. Register the server — `claude mcp add beam-lisp -- bl mcp`, or `mcp { server \"beam-lisp\" { command \"bl\"; args \"mcp\" } }` in a spell.kdl — and the whole surface is a prompt away: prompts/get `beam-lisp/onboarding` (the wire, the fact model, the rules of engagement), `beam-lisp/usage` (the day-to-day grammar, closing with the LIVE tool registry), `beam-lisp/protocol` (how the instruction layer itself works), and `beam-lisp/skill` (this text, fetched rather than read from disk). Two resources carry the vocabulary: `code://beam-lisp/schema` (every attribute and what it means) and `code://beam-lisp/namespaces` (what is mounted right now). Without an MCP client: `bl ask \"question\"` answers about this tree, `bl search \"what it means\"` finds functions by intent, and `docs/bl/*.md` is the prose corpus, indexed by `docs/bl/00-the-cli.md`.\n\nOnly answers cross the MCP wire, never whole files: name the question, keep `:find` to the columns you need, and bind every target via `:in` — a free variable inside a rule means \"reaches anything\", not \"reaches X\"."}])

```

## The corpus: skill — usage

The `:usage` half is what an agent re-reads on task start: the verbs, the
literate file format, and the habit of asking before reading.

```beam-lisp
(def skill-usage
  [{:instr/id "skill/usage/verbs"
    :instr/for "skill" :instr/kind :usage :instr/order 10
    :instr/title "The CLI is the harness"
    :instr/text
    "`bl run FILE` executes a program (the last value prints) · `bl eval EXPR` evaluates one expression · `bl repl` is a live session you keep adding code to · `bl test [PATH…]` runs `.bl` tests with each file in its own isolated ward · `bl check --changed` compiles and analyses what moved · `bl lint` reports smells and `bl fix` applies the safe tier · `bl doc run FILE` executes a literate document and checks its cells. Every report command also answers `--json`, which is the same report for a program to read."}

   {:instr/id "skill/usage/literate"
    :instr/for "skill" :instr/kind :usage :instr/order 20
    :instr/title "Literate source: .bl.md and .bl.org"
    :instr/text
    "A `.bl.md` is prose with fenced beam-lisp cells: the prose is the narrative, the cells are the program, and the cells are concatenated in document order and compiled as one unit. The same file is therefore source, documentation and test corpus at once — `bl run docs/x.bl.md` executes it. Write new explanations this way and put the supporting files beside the skill as `.bl.md`: the doc cannot drift from the code because it IS the code."}

   {:instr/id "skill/usage/explore"
    :instr/for "skill" :instr/kind :usage :instr/order 30
    :instr/title "Ask before you read"
    :instr/text
    "`bl ask \"who calls X?\"` and `bl search \"what it means\"` answer from the source-index facts, not from a grep over text — the answer is the call graph, with lines. `bl lint --tier safe` and `bl check --changed` are the two cheap gates to run before calling a change done."}

   {:instr/id "skill/usage/idioms"
    :instr/for "skill" :instr/kind :usage :instr/order 40
    :instr/title "Three lines of the dialect"
    :instr/text
    "Threading, anonymous functions, lazy sequences, and core predicates compose the way they do in Clojure — that is the point of a reader-compatible dialect. A pipeline reads top to bottom, and nothing runs until something demands the value."
    :instr/code
    "(->> (range 1 6)\n     (map (fn [n] (* n n)))\n     (filter even?)\n     (reduce +))"}])

```

## The corpus: skill — protocol

The meta layer, for whoever extends the skill: it is a projection, and it says
which release it was projected from.

```beam-lisp
(def skill-protocol
  [{:instr/id "skill/protocol/facts"
    :instr/for "skill" :instr/kind :protocol :instr/order 10
    :instr/title "This skill is a projection"
    :instr/text
    "Nothing in this skill is hand-kept. Each heading is an `:instr/*` fact — `:instr/id`, `:instr/for \"skill\"`, `:instr/kind`, `:instr/order`, `:instr/title`, `:instr/text` (and the optional `:instr/code`, a form the renderer shows as a cell a test can RUN) — in the same fact space that holds the code facts. The directory on disk is those facts assembled by `mcp.skill`; the `beam-lisp/skill` prompt is the same query through `mcp.instructions/prompt`. Amend a fragment by re-asserting its `:instr/id`. The covenant holds here too: an instruction that lives in only one projection is a bug."}

   {:instr/id "skill/protocol/tag"
    :instr/for "skill" :instr/kind :protocol :instr/order 20
    :instr/title "The release tag"
    :instr/text
    "The skill carries the release number of the `bl` that wrote it (`version:` in the frontmatter, from `bl.util/version` — the CalVer tag in a built drop, `0.1.0` in a checkout). `bl install mcp --check` compares that tag against the running `bl` and reports a skill written by an older release rather than quietly leaving it in place. A skill that cannot say which release it describes cannot be trusted to describe the one you are running."}])

(def CORPUS (concat onboarding usage protocol skill-orientation skill-usage skill-protocol))
```

## Mounting and assembly

`mount!` installs the schema and asserts the corpus into an existing codebase
conn — the instruction facts land beside the fn/call facts, so `code/query`
reaches them with the same datalog. `assemble` is the whole trick in one
query: the fragments of one kind, in order, joined as markdown.

```beam-lisp
(defn facts
  "The corpus as transaction data, one entity per fragment, ids above every
   code-fact base."
  []
  (second
   (reduce (fn [[i acc] frag]
             [(+ i 1) (conj acc (assoc frag :db/id (+ ID-BASE i)))])
           [0 []] CORPUS)))

(defn mount!
  "Assert the corpus into `conn`. The conn must carry the instruction attrs —
   codebase/connect-codebase's SCHEMA includes them, because the indexer
   itself emits :instr/* facts from ^{:instr …} annotations (the colocated
   authoring style; this corpus is the separate-document style — one fact
   space, both styles). :instr/id is a unique identity, so re-mounting
   AMENDS fragments in place."
  [conn]
  (datom/transact! conn (to-list (facts)))
  conn)

(defn fragments
  "The `kind` fragments of surface `for`, ordered: [{:order :title :text
   :code} …]. A fragment may carry prose, a form, or both; `:code` is absent
   when it carries no runnable form.

   `get-else` is what keeps the optional attributes optional. Both are read
   with it, because the alternative — a required join — makes a fragment
   without prose or without code vanish from the answer entirely, which reads
   as \"this instruction does not exist\" when the truth is \"this
   instruction is a form\"."
  [db for kind]
  (sort-by (fn [frag] (:order frag))
           (map (fn [row]
                  (let [text (nth row 2)
                        code (nth row 3)
                        frag {:order (first row) :title (second row) :text text}]
                    (if (nil? code) frag (assoc frag :code code))))
                (datom/q '[:find ?order ?title ?text ?code
                           :in $ ?for ?kind
                           :where
                           [?i :instr/for ?for]
                           [?i :instr/kind ?kind]
                           [?i :instr/order ?order]
                           [?i :instr/title ?title]
                           [(get-else $ ?i :instr/text "") ?text]
                           [(get-else $ ?i :instr/code nil) ?code]]
                         db for kind))))

(defn- fragment-md
  "One fragment as markdown: the heading, the prose, and — when the fragment
   carries one — the form as a beam-lisp cell. A literate document is exactly
   this, so a fragment with :instr/code is a literate document with a cell."
  [frag]
  (str "## " (:title frag) "\n\n"
       (let [text (:text frag)]
         (if (or (nil? text) (= "" text)) "" (str text "\n\n")))
       (if (some? (:code frag))
         (str "```beam-lisp\n" (:code frag) "\n```\n")
         "")))

(defn assemble-for
  "One surface's `kind` as markdown: a heading per fragment, in :instr/order.
   The whole instruction layer is this function — a prompt is a query result,
   and so is a skill file."
  [db for kind]
  (join "\n" (map fragment-md (fragments db for kind))))

(defn assemble
  "`assemble-for` for the MCP surface — the surface every older caller means."
  [db kind]
  (assemble-for db "mcp" kind))
```

## Prompts

The MCP `prompts/*` surface. Three named prompts, one per kind; `usage`
appends a LIVE section (built by the caller from the server's tool registry
and the database's manifest), because the freshest fact about the tools is
the registry itself.

```beam-lisp
(def prompt-descriptors
  [{"name" "beam-lisp/onboarding"
    "description" "First contact: what this server is, the wire, the fact model, the rules of engagement. Read once, before the first tool call."}
   {"name" "beam-lisp/usage"
    "description" "The day-to-day grammar: recipes per question, resources, cost discipline — closing with the live tool registry. Re-fetch on task start."}
   {"name" "beam-lisp/protocol"
    "description" "How the instruction layer works: the :instr/* fact schema, the kinds, how to compose or amend fragments. Read before extending these instructions."}
   {"name" "beam-lisp/skill"
    "description" "The skill: what beam-lisp is, the modules worth knowing first, where the full documentation lives. The same corpus bl install mcp writes into an agent's skills directory."}])

(defn manifest-line
  "One sentence of live counts — the database introduces itself."
  [db]
  (let [nss (sort (into [] (datom/q '[:find ?ns :where [?d :fn/ns ?ns]] db)))
        fns (or (first (first (into [] (datom/q '[:find (count ?d) :where [?d :fn/name _]] db)))) 0)
        calls (or (first (first (into [] (datom/q '[:find (count ?c) :where [?c :call/caller _]] db)))) 0)]
    (str "*Right now the database holds " fns " fn facts and " calls
         " call facts across: " (join ", " (map first nss)) ".*")))

(defn prompt
  "Assemble prompt `name` over `db`. `live` is the caller-built live registry
   section, appended to usage. Returns {:description … :text …}, or nil for a
   name this server does not carry."
  [name db live]
  (cond
    (= name "beam-lisp/onboarding")
    {:description "First contact with the beam-lisp codebase server."
     :text (str "# beam-lisp MCP — onboarding\n\n"
                (assemble db :onboarding)
                "\n\n" (manifest-line db))}

    (= name "beam-lisp/usage")
    {:description "The day-to-day grammar of the beam-lisp codebase server."
     :text (str "# beam-lisp MCP — usage\n\n"
                (assemble db :usage)
                (if (and (some? live) (not= live "")) (str "\n\n" live) ""))}

    (= name "beam-lisp/protocol")
    {:description "The instruction layer, described by itself."
     :text (str "# beam-lisp MCP — the instruction protocol\n\n"
                (assemble db :protocol))}

    ;; The skill is the SAME corpus, addressed to a reader with no database
    ;; yet: the mcp prompts teach questions, the skill teaches the language.
    ;; One query, two readers — and `mcp.skill` renders it a third time, to
    ;; files. Three projections, one corpus, no drift.
    (= name "beam-lisp/skill")
    {:description "beam-lisp itself: what it is, which modules to know, how to reach the rest."
     :text (str "# beam-lisp — the skill\n\n"
                (assemble-for db "skill" :onboarding)
                "\n\n" (assemble-for db "skill" :modules)
                "\n\n" (assemble-for db "skill" :usage))}

    :else nil))
```
