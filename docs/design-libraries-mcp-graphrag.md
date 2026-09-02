# Design: MCP · Libraries · GraphRAG ingest · Facts & Procedures

Status: DRAFT for discussion — 2026-08-27
Scope: beam-lisp ecosystem (`priv/datom`, `examples/semantic`, `examples/datom/live`) + spell harness.

> North star: **a library is a datom space. Facts and procedures are both datoms.
> MCP is the wire. Live queries are the nerve.** Nothing in this design invents a
> second storage, query, or sync mechanism — every layer reuses datom's indexes,
> datalog, vector lane, time travel, and L2/L3 broadcast.

---

## 0. Ground truth (verified this session)

| piece | state |
|---|---|
| `priv/lib/datom/*.bl` | Immutable temporal EAV db. Facade: `connect/connect-with/transact!/with/q/pull/entity/as-of/since/history/install-schema!/register-tx-fn!`. Store protocol over redb (durable, CAS, atomic commit), ETS (dev), map (reference), overlay (speculative reads). Query engine: hash-joins, `:and/:or/:not/:or-join`, **rules w/ native fixpoint** (`datom_datalog` NIF, bl semi-naive fallback), aggregates, pull w/ recursion, migrations w/ tx-fns. |
| `priv/lib/datom/vector.bl` | DVec normalized packed f32; `similar-to` as a **datalog clause**; k-means, PCA, knn-all, HNSW NIFs declared (flat search shipped; persistent HNSW lifecycle NOT wired). |
| `priv/lib/datom/broadcast.bl` + `live/` | L2: commit reports `[:datom/tx basis tx-datoms]` / `[:datom/changed basis attrs]`, attr-filtered, Phoenix.PubSub optional. L3: `datom/watch` T1 pattern watches, T2a guarded (auth/rls) + semantic watches. T2b incremental maintenance is follow-up. |
| `examples/semantic/` | Thesis: *embeddings are ordinary datoms*. 11–15 = working GraphRAG prototype: corpus split → Gemini `gemini-embedding-001` (768d, disk-cached) → entity/relationship extraction (schema-constrained JSON) → unique entity datoms + ref edges → label-propagation communities → summaries as facts → local (vector entry + graph expansion) / global (community summaries) search. |
| `spell/apps/spell/lib/spell/mcp.ex` | MCP **server** Plug, POST-only `/spell/mcp`, hardcoded `2025-03-26`, 3 tools (`run/state/transcript`). No resources, prompts, notifications, SSE, auth. Origin-validated, loopback-assumed. |
| spell session memory | Split: `Spell.Persist` (journal.bl + transcript.json) vs `spell.transcript`/`spell.timeline` (datom-backed, seeded fixture only — **new turns don't reach datom yet**). |
| beam-lisp IO surface | Remote interop compiles to `apply/3`: httpc, Jason, File, crypto, Base, :gen_tcp all reachable. defserver/Supervisor real OTP. `println` → stdout (unsafe for stdio MCP). No tested URI parse, regex, or `send_after` wrappers. |
| PLAN-034 | datom is being split into its own EPL-2.0 package — new packages must be shaped for that split. |

Known datom gaps that matter below: FEAT-008 (50k-char value encode ≈ 8s — document text!), FEAT-010 (no historical schema at basis), FEAT-015 (no lookup refs in tx entity position), magic sets exist but not wired, HNSW not lifecycle-managed.

---

## 1. Package `mcp` — Model Context Protocol, 2026-07-28

### 1.1 Version policy

Latest released spec = **2026-07-28** (stateless core). It is a *breaking* revision,
not a superset:

- `initialize`/`initialized` handshake **removed** → every request carries
  `protocolVersion` + `clientCapabilities` in `_meta`; mandatory `server/discover` RPC.
- `Mcp-Session-Id` **removed** → cross-call state via server-minted handles as
  ordinary tool args. (For us: `library` + `basis-t` handles — datom basis is
  *literally* the session handle the spec now wants.)
- `ping`, `logging/setLevel`, roots/sampling/logging **deprecated/removed**.
- HTTP GET + `resources/subscribe` → **`subscriptions/listen`**: one long-lived POST
  stream, client opts into `toolsListChanged / promptsListChanged / resourcesListChanged /
  resourceSubscriptions`.
- **MRTR**: server returns `InputRequiredResult` (`resultType: "input_required"` +
  `inputRequests`), client retries original request with `inputResponses`. Replaces
  server-initiated `elicitation/create`.
- Every result has `resultType`; list/read results need `ttlMs` + `cacheScope`
  (CacheableResult); JSON Schema 2020-12 fully allowed for tool schemas.
- `tasks` moved to extension `io.modelcontextprotocol/tasks` (poll via `tasks/get`,
  client input via `tasks/update`).

Design decision: implement **2026-07-28 as primary**, keep a `server/discover`-based
compat shim answering legacy `initialize` with `UnsupportedProtocolVersionError` +
advertised versions. Spell.Mcp's 2025-03-26 face stays up while the new package
rises; cutover, not parallel growth.

### 1.2 Shape

```
priv/mcp/
  jsonrpc.bl        ; transport-neutral: message validate → dispatch → result/error
  version.bl        ; protocol negotiation, _meta envelopes, resultType, CacheableResult
  server.bl         ; defserver: tool/prompt/resource registries, MRTR state, tasks
  discover.bl       ; server/discover + capability advertisement
  subscriptions.bl  ; subscriptions/listen state machine
  transport/stdio.bl    ; newline framing; ALL diagnostics to stderr (println is stdout!)
  transport/http.bl     ; Bandit plug: POST endpoint + listen stream, Origin validation,
                        ; Mcp-Method/Mcp-Name headers, stateless (no session header)
```

Everything protocol-level is pure data (maps in, maps out); effects (query, transact,
LLM calls) live behind registered performers — same trust discipline as
`interface/server.bl`'s closed walker: **the protocol core never calls out**.

### 1.3 The mapping that makes this design cohere

| MCP 2026-07-28 | datom-native realization |
|---|---|
| `tools/list` + `ttlMs` | tool registry as datoms; `ttlMs` from `:tool/churn` policy |
| `resources/list` / `resources/read` | libraries ARE resources: `library://<name>/schema`, `library://<name>/entity/<id>`, `library://facts/<space>/since/<t>` |
| `subscriptions/listen` + `resourceSubscriptions` | **L3 `datom/watch`**: resource URI → datalog pattern interest → notification per commit. L2 attr filters = the prefilter. Nothing new to build. |
| `Mcp-Session-Id` replacement handles | `(library, basis-t)` pairs — immutable db values as explicit state tokens |
| MRTR `input_required` | procedure execution with missing params (§4.4) — legal-doc generation is the canonical case |
| `tasks` extension | long ingests (§3): `tasks/get` polls ingest job entity; job state is datoms |
| notifications `toolsListChanged` | L2 broadcast on the registry space's `:tool/*` attrs |

The claim to test in the PoC: **datom's L2/L3 is a strict superset of
`subscriptions/listen`** — including per-principal filtering (T2a guarded feeds →
per-client subscription scoping) that MCP itself doesn't specify.

---

## 2. Package `librarium` — libraries as datom spaces

### 2.1 Model

A **library** = one datom connection (redb-backed) + a manifest entity + one or more
installed **schema packs**:

```
{:library/name :moroccan-law
 :library/kind #{:facts :procedures}     ; most libraries are mixed
 :library/store {:redb "/path/law.redb"}
 :library/schema-packs [:legal/core :legal/doc :proc/core]
 :library/embedding {:attr :chunk/embedding :dims 768 :index :hnsw}
 :library/version 3}
```

- **Schema pack** = versioned, named set of `install-schema!` defs + migrations.
  Shipping a vocabulary = shipping a pack; upgrading = `datom.migrate/plan+apply`.
- **Space isolation**: one redb file per library (single-writer discipline already
  holds per conn). No cross-library FKs; references are by name strings resolved at
  query time (`:ref` stays intra-space — matches Datomic).
- **Session mounting**: a session mounts libraries read-only + gets a **scratch
  space layered via `store-overlay`** — speculative writes over the mounted basis.
  Scratch is where the agent asserts working hypotheses; promotion to the real
  library is an explicit `transact!` (reviewable diff = overlay's op log).
  This is the "agent thinks in pencil, publishes in ink" pattern, and overlay
  already exists.

### 2.2 Universal vocabulary (every library)

```
:lib/doc        ; source document (uri, hash, title, fetched-at)
:lib/chunk      ; text span: doc ref, char range, order, text, embedding
:lib/entity     ; canonical entity: unique name, type, aliases[]
:lib/rel        ; edge: subject ref, predicate, object ref, doc provenance
:prov/*         ; every derived datom carries :prov/doc, :prov/span, :prov/tx,
                ; :prov/agent (which session/model produced it), :prov/confidence
```

Provenance is not optional decoration — it's what makes `datom/history` +
`datom/tx-of` answer "who asserted this and from what source" for free.

### 2.3 Embedding discipline

One embedding attr per chunk entity (thesis already proven in `examples/semantic`).
Gap to close: **index lifecycle** — an L3 watch on `:chunk/embedding` maintains the
HNSW NIF resource, so `similar-to` stays O(log n) at library scale instead of flat
scans. This is the single most important perf piece for real corpora.

---

## 3. Package `xberg` — ingest documents → GraphRAG in datom

**Open question (need your input): what is xberg?** Nothing named xberg/iceberg
exists in either repo. I've designed the seam assuming xberg = your document
reader/normalizer (parse → clean text + structure). If it's something else, only
stage 0 changes.

### 3.1 Pipeline (all beam-lisp; stages are pure fn values, composed)

```
0 read      xberg/bl: bytes → {:blocks [...] :meta {...}}        (pluggable)
1 chunk     structure-aware split (headings/articles > paragraphs > windows)
            — for law: NEVER split an article; chunk = article/alinéa
2 transact  chunks + doc entity + provenance, one tx per doc (atomic)
3 embed     batched; :chunk/embedding datoms in same space
4 extract   LLM structured extraction (gemini.bl pattern, schema-constrained):
            entities + relations → :lib/entity (unique name upsert) + :lib/rel refs
5 graph     adjacency materialized; label-propagation communities (14-communities.bl)
6 summarize community summaries + library-level digest → derived facts
7 report    ingest job entity updated per stage; MCP tasks/get polls it
```

Stages 4–6 are exactly `examples/semantic/13→14→15` lifted from scripts into a
package with: resumability (each stage queries "what's missing" instead of
remembering), idempotent upserts (unique identity on entity names + doc hashes),
and stage-level caching (content-hash keyed, like gemini.bl's disk cache but as
datoms).

### 3.2 Why this is *better* than MS-GraphRAG/LightRAG as shipped

- MS-GraphRAG: parquet files + LLM community reports; retrieval disjoint from storage.
- LightRAG: KV + vector + graph in three separate stores.
- **Ours: one store.** Chunk text, embeddings, entity graph, communities, summaries
  are all datoms in one basis → one `q` can mix vector kNN + graph walk + time +
  provenance in a single snapshot. Example (legal): "articles similar to this clause,
  in force as-of 2023, cited by decrees" = one query, `similar-to` ∧ `:as-of` ∧
  VAET walk. Neither GraphRAG nor LightRAG can express that without glue code.

### 3.3 The Memp-shaped feedback loop

`examples/semantic/12-naive-rag.bl` demonstrates naive RAG *failing* on global
questions — keep that as the regression test: ingest must make global questions
answerable via stage 6 summaries, else the pipeline is decorative.

---

## 4. Facts and Procedures — the semantics

Cognitive architecture alignment, made concrete:

| human memory | our realization | where it lives |
|---|---|---|
| episodic | session transcripts | spell.transcript datoms (once loop→datom cutover lands) |
| semantic | **facts** | fact libraries |
| procedural | **procedures** | procedure libraries |
| working | mounted bases + overlay scratch | per-session |

### 4.1 Facts

A fact = datoms with provenance, plus **valid time** layered on tx time:

```
{:fact/statement "Le délai de préavis est de ..."   ; or as structured triples
 :fact/valid-from 2004-06-06   :fact/valid-to nil    ; bitemporal: law needs this
 :prov/doc <dahir-ref>  :prov/confidence 1.0}
```

Datom gives tx-time (`as-of`, `since`); valid-time is two indexed attrs +
a datalog rule `(in-force ?art ?date)`. Legal domain *requires* this: dahirs
abrogate articles; "what did art. 1240 say when the contract was signed" is
`as-of` over tx-time ∧ valid-window overlap.

Fact kinds worth standardizing in `schema pack :facts/core`:
- `:fact/triple` — extracted entity relations (stage 4)
- `:fact/assertion` — human/agent-authored claims w/ confidence + source
- `:fact/decision` — the coding-harness case: architecture decisions w/ rationale
  + status (`:proposed/:accepted/:superseded` + `:fact/superseded-by` ref —
  which is exactly SUPERSEDES in the memory graph)

### 4.2 Procedures

A procedure = a **stored, versioned, semantically retrievable program**:

```
{:proc/name :legal/mise-en-demeure
 :proc/doc "Génère une mise en demeure (art. 268 DOC) ..."
 :proc/params {:debiteur :string :creance :money :delai-jours :int}   ; shape spec
 :proc/precondition '[:find ?art :where [?art :art/num 268] ...]      ; datalog, as data
 :proc/body [:template "templates/mise-en-demeure.blmd"               ; or .bl steps
             [:assert :doc/debiter :$debiteur] ...]
 :proc/output :doc/pdf
 :proc/embedding <768d>           ; over name+doc+params → similar-to retrieval
 :proc/stats {:runs 41 :success 0.93 :last-used tx}
 :proc/successor nil  :proc/status :active}
```

Execution modes, in increasing authority:
1. **pure** — body is datalog rules/pull → run inside query engine, zero effects.
   (Datalog rules *are* procedures for deriving facts; tx-fns *are* procedures for
   deriving transactions. The library doesn't invent these — it **names, versions,
   and indexes** them.)
2. **template** — body fills a `.blmd` template from params + precondition query
   results → document. The legal-helper workhorse.
3. **script** — body is `.bl` source (stored as a string datom, loaded via the
   AOT/loader path) with registered performers; runs under the trust-boundary rules.
4. **agentic** — body is a plan for the LLM loop (steps + tool allowlist); the
   session executes it, stats update after.

MRTR tie-in: `proc/run` with missing/invalid params → `InputRequiredResult` whose
`inputRequests` are generated *from `:proc/params`*; client retries with
`inputResponses`; precondition query gates execution. The 2026-07-28 spec seems
almost designed for this.

### 4.3 The lifecycle (Memp: build / retrieve / update)

- **Build**: session end → distillation pass reads the session's transcript datoms
  (`spell.transcript`) → proposes new facts/procedures into scratch → human or
  policy promotes. Success trajectories distill to procedures; stable knowledge to
  facts. (Memp's empirical finding: procedural memory transfers — even to weaker
  models. So the legal partner's procedures compound in value.)
- **Retrieve**: hybrid = `similar-to` over `:proc/embedding`/`:chunk/embedding`
  ∧ datalog constraints (kind, status :active, domain, precondition satisfiability
  against *mounted facts* — retrieval that knows what the procedure needs).
- **Update**: correction = retraction + successor link (history preserved);
  stats decay; deprecation when superseded. All datalog-queryable:
  "procedures with success < 0.5 unused 90 days" is one query.

### 4.4 Use-case walkthroughs

**Moroccan legal helper**
- Fact library `moroccan-law`: DOC/code-de-commerce as `:lib/doc` → articles as
  chunks (never split) with `valid-from/to`, entity graph (dahir → loi → décret →
  article, `cites`/`abroge` edges), embeddings per article.
- Procedure library `cabinet-procs`: partners author `:legal/*` procedures —
  params (parties, montants, délais), precondition queries (vérifier prescription,
  art. en vigueur), templates in `.blmd`, output PDF/DOCX.
- Session: partner mounts both + scratch. Query: "délai de préavis licenciement
  2022" → `similar-to` ∧ `(in-force ?art 2022)` → cited answer w/ provenance.
  Generation: `proc/run :legal/mise-en-demeure` → MRTR elicits missing params →
  precondition checks art. 268 valid today → template fills → doc. Draft clauses go
  to scratch; partner approves → promoted with `:prov/agent`.

**Coding harness (spell itself)**
- One library `dev-wisdom`: facts = architecture decisions, conventions, host
  facts (the emulator/KVM findings in AGENTS.md are *literally* fact-library
  entries with provenance); procedures = "how to add an MCP tool", "benchmarking
  protocol", "how to ship a datom migration".
- Session bootstrap: mount `dev-wisdom`, inject top-k relevant procs by task
  embedding. Session end: distill. The harness's memory becomes one datom space
  you can `q`, `as-of`, diff, and replicate — replacing scattered markdown notes.

---

## 5. What beam-lisp needs (ask list, ranked)

1. **stdout discipline for stdio MCP**: `println` goes to stdout → corrupts framing.
   Need `eprintln`/stderr redirect, or a stdio mode that reroutes.
2. **FEAT-008** value-codec O(n) escaping (~8s @ 50k chars): blocks storing document
   text as datom values. Either fix codec or chunk-external blob store keyed by hash.
3. **HNSW lifecycle**: NIFs declared, no persistent index management. Libraries need
   watch-maintained indexes (§2.3).
4. **URI parsing + regex** as tested wrappers (MCP resource templates, `library://`
   URIs). Reachable via interop today; make them blessed + tested.
5. **`send_after`/timer wrapper** (subscription heartbeats, task polling deadlines).
6. **SSE streaming helper** (lazy Stream guidance exists; need a plug-shaped one for
   `subscriptions/listen`).
7. **FEAT-015** lookup refs in tx entity position (ingest upserts need it).
8. **JSON Schema 2020-12 validation** in bl (tool schemas, `:proc/params` checking,
   MRTR inputRequests) — promote `semantic.shape` from example to package.
9. Nice-to-have: magic sets wired into planner (recursive `cites`/`abroge` walks);
   FEAT-010 historical schema (strict as-of correctness).

---

## 6. Build order (proposal)

1. `mcp` protocol core + stdio transport (version negotiation, tools, discover) — PoC target.
2. `librarium` minimal: manifest + schema packs + mount/overlay + `library://` resources.
3. `xberg` stages 0–3 (read→chunk→transact→embed) on the legal corpus; naive RAG answer.
4. Stages 4–6 (graph+communities) — port 13–15 examples; global-question regression test.
5. Procedures: `:proc/core` pack + template mode + MRTR; legal doc generation end-to-end.
6. `subscriptions/listen` ← datom/watch bridge; tasks extension for ingest jobs.
7. Session integration in spell: mount on init, context injection, end-of-session distill.

PoC for this week: (2)+(3) thin slice — one schema pack, one dahir ingested, one
`similar-to ∧ in-force` query, one procedure run via MRTR-shaped tool call.

---

## 7. Addendum 2026-08-27 — packs shipped as prototype (spell/apps/librarium)

Packs now exist as runnable beam-lisp: `facts-core` (src/chunk/entity/**edge**/prov
— the edge+provenance vocabulary moved here, ALL domain packs share it),
`proc-core` (procedures as data: params/precondition as `:db.type/term`, kinds
:pure/:template/:script/:agentic, stats, successor chains), and seven domain
packs: legal, dev, research, kb, crm, support, ops. `librarium/harness.bl`
runs all seven against the real engine (fake embedder offline;
`LIBRARIUM_EMBED=gemini` switches to disk-cached gemini-embedding-2).

Conventions proven by the harness:
- dates as YYYYMMDD longs; `valid-to` sentinel 99999999 ⇒ temporal filters
  stay negation-free
- tx-time ≠ valid-time demonstrated live: `as-of` before the amendment tx
  shows 3 versions, current basis 4, and the 2010 valid-time query returns
  the PRE-amendment text
- ticket/incident → `:resolved-by` → procedure works: episodic feeds
  procedural, retrieved by meaning in one query

**FEAT-025 filed** (beam-lisp): rule bodies can't filter on head args —
bottom-up materialisation has no call-site bindings; magic.bl exists but is
unwired. Until fixed, packs ship pattern-only rules (`window`, `open-deal`,
`cites*`…) and date/cutoff predicates live at call sites. This is the #1
engine ask for the "semantic datalog" promise.

