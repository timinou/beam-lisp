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
    "Every definition is an entity: :fn/name, :fn/ns, :fn/arity, :fn/line, :fn/ret-tag (a PROVEN return type — annotated from ^{:ret …} or inferred). Every call is an entity: :call/caller, :call/callee, :call/arity, :call/line. Two ways to ask: code/ask for named questions (impact, callers, reachable, returns-type, arity-mismatches, unknown-callees), code/query for raw datalog when the question has no name yet. In code/query, $ is the database and % is the reachability rules ((reaches ?a ?b)). ALWAYS bind your target via an :in scalar — a free variable inside a rule means \"reaches anything\", not \"reaches X\"."}

   {:instr/id "mcp/onboarding/mrtr"
    :instr/for "mcp" :instr/kind :onboarding :instr/order 40
    :instr/title "Elicitation (MRTR)"
    :instr/text
    "A question that needs a target and got none does not fail — it answers resultType: input_required with an elicitation schema. Retry the same tools/call with inputResponses: {\"target\": \"<fn>\"} as a SIBLING of name and arguments inside params — not inside arguments, where it is ignored and the server simply elicits again. Never guess a target; let the server ask."}

   {:instr/id "mcp/onboarding/verify"
    :instr/for "mcp" :instr/kind :onboarding :instr/order 50
    :instr/title "Two tools no indexer has"
    :instr/text
    "code/verify takes the source of a defserver carrying ^{:invariant …} and PROVES the invariant with z3 — verdict: holds is a machine-checked fact, and with repair: true a violation returns the weakest guard that fixes it. code/subscribe + code/poll watch the fact space itself: subscribe to a callee, then poll to drain \"fn X gained or lost a caller\" events."}

   {:instr/id "mcp/onboarding/rules"
    :instr/for "mcp" :instr/kind :onboarding :instr/order 60
    :instr/title "Rules of engagement"
    :instr/text
    "1. Ask named questions first (code/ask); drop to code/query only when the question has no name. 2. Project to rows — filter inside the query, never in your context. 3. Fetch the beam-lisp/usage prompt (prompts/get) before your first real task. 4. Trust verdicts, not vibes: if code/verify says holds, it holds for every state and input. 5. Fetch beam-lisp/protocol before you extend or amend these instructions."}])
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

(def CORPUS (concat onboarding usage protocol))
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
  "The `kind` fragments of surface `for`, ordered — [[order title text] …]."
  [db for kind]
  (sort-by (fn [row] (first row))
           (into []
                 (datom/q '[:find ?order ?title ?text
                            :in $ ?for ?kind
                            :where
                            [?i :instr/for ?for]
                            [?i :instr/kind ?kind]
                            [?i :instr/order ?order]
                            [?i :instr/title ?title]
                            [?i :instr/text ?text]]
                          db for kind))))

(defn assemble
  "One kind's prompt as markdown: a heading per fragment, in :instr/order.
   The whole instruction layer is this function — a prompt is a query result."
  [db kind]
  (join "\n\n"
        (map (fn [row]
               (let [title (second row)
                     text (nth row 2)]
                 (str "## " title "\n\n" text)))
             (fragments db "mcp" kind))))
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
    "description" "How the instruction layer works: the :instr/* fact schema, the kinds, how to compose or amend fragments. Read before extending these instructions."}])

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

    :else nil))
```
