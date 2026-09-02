# MCP over the codebase — a thoughtfully small surface

Status: PROTOTYPE — 2026-08-30
Lives in: `tooling/mcp/` (six modules) + `tooling/run-mcp-demo.bl` (entry)
Run: `mix beam_lisp.run --path tooling tooling/run-mcp-demo.bl`

> One claim, tested: the three-tool MCP shape proven against a *law* library in
> `spell/apps/mcp` is not domain-specific. Repointed at beam-lisp's own
> code-as-facts engine (`priv/std/codebase.bl`), the *same* protocol core, the
> *same* MRTR elicitation, and the *same* registry answer coding questions —
> only the fact space changed. Then two tools no external indexer can offer —
> `code/verify` (the z3 prover) and `code/subscribe` (datom L3 watch) — are
> added, because on beam-lisp they are already-shipped subsystems awaiting a
> wire.

---

## 0. Where this came from

The six protocol modules were built in `spell/apps/mcp/src/mcp` pointed at a
Moroccan-law fixture. They were copied here and split into two halves:

| module | origin | change |
|---|---|---|
| `jsonrpc.bl` | spell | **verbatim** — pure JSON-RPC 2.0 + version envelopes |
| `transport-stdio.bl` | spell | **verbatim** — newline framing, all diagnostics to stderr |
| `stdio_main.bl` | spell | **verbatim** — the spawned-process entry |
| `server.bl` | spell | **repointed** — `code://` resources; dispatch unchanged |
| `tools.bl` | spell | **rewritten** — six tools over `codebase.bl` |
| `demo.bl` | spell | **rewritten** — eleven exchanges over real source |

That the transport-neutral half copies verbatim is the first evidence for the
thesis: **the MCP core never calls out** (protocol is pure data in, data out),
so it does not know or care whether the fact space behind it is law or code.

---

## 1. The design principle (why the surface is *small*)

Three independent lines of work in the field converged on one conclusion:

- **Anthropic, *Code Execution with MCP*** — loading many tool definitions and
  passing raw results through the model wastes context; filter in the execution
  environment and let only answers cross the wire.
- **CodeRLM (RLM pattern)** — index a repo with tree-sitter and let the agent
  *query the index* (callers, bodies, tests) instead of glob → grep → read.
- **LogicLoc (arXiv 2604.16021)** — extract program *facts*, run *Datalog* over
  them on a deterministic engine; more accurate localization at lower token cost,
  because structural traversal is offloaded off the model.

beam-lisp already *is* the substrate all three reach for: `priv/std/codebase.bl`
turns source into facts —

```
[?d :fn/name "t-meet"] [?d :fn/arity 2] [?d :fn/line 214]
[?c :call/caller "walk-if"] [?c :call/callee "t-meet"] [?c :call/line 402]
```

— and the questions ("who calls X", "what breaks if X changes", "which fns
return string") are *already queries* over datom. So the MCP surface does not
need many tools. It needs to **expose the query engine**. Power lives in datalog
and datom, not in a wide tool menu.

---

## 2. The surface — the three-tool core, plus two beam-lisp-only tools

| legal prototype | codebase MCP | role | wire cost |
|---|---|---|---|
| `library/list` | `code/list` | discover mounted codebases + manifests | tiny (counts) |
| `library/query` | `code/query` | raw datalog over fn/call facts (escape hatch) | only rows |
| `proc/run` (MRTR) | `code/ask` (MRTR) | named questions; elicits the target fn if missing | only rows |
| — (new) | `code/verify` | **prove** a defserver's `^{:invariant}` (z3); synthesize a repair if it fails | verdict + guard |
| — (new) | `code/subscribe` / `code/poll` | **watch** the fact space (datom L3): fire when a fn gains/loses a caller | events only |

The first three are the domain-neutral shape inherited from the legal
prototype. The last two are the payoff of building on beam-lisp specifically:
both are already-shipped subsystems (`system.core` prover, `datom/watch` L3)
that no external indexer can offer, wired to MCP.

Two layers, on purpose:

- **`code/query` is the floor of maximum power.** The argument *is* a datalog
  query; the handler reads the `:in` clause and binds `$` → the db, `%` → the
  `REACH` reachability rules, and each remaining `?var` from `bindings` in
  order. Anything the engine can express, the agent can ask — and only the
  result rows return, never a file.

- **`code/ask` is the ergonomic layer.** A coding agent does not think in
  datalog; it asks `impact` / `callers` / `reachable` / `returns-type` /
  `arity-mismatches` / `unknown-callees`. Each maps to one canned,
  **target-bound** query. This is where the agent lives day to day; `code/query`
  is the hatch it drops to when a question is not yet named.

### MRTR is the same machinery, repointed

The 2026-07-28 spec's `input_required` flow (a result that asks the client for
more input, which retries with `inputResponses`) drove *legal document
parameters* in the original. Here it drives **"which function?"**: `code/ask`
with a target-needing question and no `target` returns `input_required` with an
elicitation schema; the client retries with `{"target": "t-meet"}` and gets the
answer. Identical protocol path, different question. (`demo.bl` exchanges 5→6.)

---

## 3. What the prototype proves (verified, not asserted)

`demo.bl` runs **eleven** exchanges against beam-lisp indexing **itself**
(`priv/std/codebase.bl` + `priv/std/typed.bl` → 80 fns, 745 call facts, one basis):

1. `server/discover` → `2026-07-28` handshake ✓
2. `tools/list` → exactly **six** tools, `ttlMs`/`cacheScope` present ✓
3. `code/list` → both namespaces, live fn/call counts ✓
4. `code/query` (datalog: fns that may return `"string"`) → rows ✓
5. `code/ask impact` **no target** → `input_required` elicitation ✓
6. `code/ask impact` retry `target=t-meet` → the 9 fns that break if the
   lattice heart changes ✓
7. `code/verify` (correct account) → `verdict: holds` — □(balance ≥ 0) proven ✓
8. `code/verify` + `repair` (broken account) → `verdict: violated` +
   synthesized guard `(<= amt balance)` on `withdraw` ✓
9. `code/subscribe` callers of `t-meet` → subscription handle ✓
10. a new caller is committed; `code/poll` → event
    `{caller: freshly-added-fn, callee: t-meet, added: true}` ✓
11. bad version → `-32022` ✓

### The two beam-lisp-only tools, in detail

**`code/verify` — the prover as a tool.** The client sends the source of a
`defserver` carrying `^{:invariant …}`. `system.core/verify-process` proves the
invariant holds for *every* state and input via z3 (not tested — proven); with
`repair: true`, a failing invariant returns the *weakest* guard that repairs it
(`repair-process`, the checker run backwards). The z3 port is opened lazily and
memoized — a real OS process paid for only on first use. This is the single most
differentiated coding-agent tool in the surface: no external indexer can return
a machine-checked safety verdict, let alone an auto-repair.

**`code/subscribe` + `code/poll` — live fact changes.** MCP 2026-07-28 has
`subscriptions/listen` for live resources; datom's L3 `datom/watch` *is* that
mechanism one layer down. `code/subscribe {callee}` registers a T1 pattern watch
`[?c :call/callee <fn>]` — it fires only when a commit asserts/retracts a call
to that fn. The canonical use: *"tell me if the function I'm editing gains or
loses a caller."* The prototype exposes it as a **poll pair** (subscribe →
handle; poll → drain) because the in-process demo has no long-lived stream; a
real transport wires the watch callback straight to `subscriptions/listen`
frames. NB the matched datom's `:v` is the *callee*; the event resolves the
caller from the sibling `:call/caller` datom on the same entity `:e` — a bug the
first run surfaced and the demo now proves fixed.

### A correctness fix worth naming

`codebase.bl` ships `impact`/`reachable` whose rule call leaves the target var
**unbound** — `(reaches ?who ?name)` with `?name` free means "?who reaches
*some* callee", i.e. every caller in the graph. Measured on `typed.bl`:

```
SHIPPED impact t-meet → 37 fns   (everything that reaches anything)
BOUND   impact t-meet →  9 fns   (genuine transitive callers of t-meet)
DIRECT callers of t-meet → guard-narrow, walk-call, walk-if  (all 9 contain these 3)
```

This is now **fixed upstream** in `priv/std/codebase.bl`: `impact` and `reachable`
bind the target via `:in` (the FEAT-025-safe discipline: filter at the call
site, not in the rule body). `code/ask` delegates straight to the fixed
helpers — the correctness lives in **one** place, not copied into the MCP layer.
The existing `examples/typing/02_codebase_demo.bl` still PASSes with the fix.

---

## 4. Surface-design decisions, and the tradeoffs

- **Three tools, not one per question.** Named questions could each be a tool,
  but that reinflates the definition list the field is trying to shrink. One
  `code/ask` with a `question` enum keeps the tool count flat; new questions are
  additive data, not new wire surface.
- **`code/query` kept as an escape hatch.** Some questions are not worth naming.
  Exposing raw datalog means the agent is never blocked waiting for a new tool —
  it drops to the floor and expresses the query itself. (Risk: an agent can
  write an expensive query; a real deployment gates this with a query
  cost/allow-policy — out of scope for the prototype.)
- **Resources are read-only `code://` URIs** (`schema`, `namespaces`). The
  design doc's larger vision maps `subscriptions/listen` onto datom's L3
  `datom/watch` so the agent is *told* when a fn it edited changes; the
  prototype stops at static resources.
- **Multi-file mount needs id-offsetting.** `codebase.bl` uses fixed `:db/id`
  bases per `index-source`, so two files into one conn collide. `mount!` offsets
  ids per file (entities join by name string, never by id — so shifting is
  free). This is a mounting concern, kept out of `codebase.bl`.

---

## 5. Open edges (honest)

1. ~~`impact`/`reachable` over-broad~~ — **fixed upstream** (§3).
2. **FEAT-025** (rule bodies can't filter on head args) is why reachability is
   target-bound at the call site rather than inside the rule. The #1 engine ask
   for the full "semantic datalog" promise.
3. **stdio discipline** holds (`transport-stdio.bl` routes every diagnostic to
   stderr; `println` would corrupt framing) — respect it in any extension.
4. **`code/subscribe` is a poll pair, not a live stream.** The in-process demo
   drains via `code/poll`; a real HTTP/stdio transport wires the watch callback
   straight to `subscriptions/listen` frames (the L3 process already exists —
   only the transport binding is missing). The watch is also per-`callee`
   pattern (T1); a full-query T2a watch (diff of a datalog answer) is a
   one-line change to the interest shape.
5. **z3 port lifecycle.** `code/verify` opens one z3 port lazily and memoizes
   it; a long-lived server should supervise/restart it (let-it-crash) rather
   than leak on failure — out of scope for the prototype.
6. **One basis, no time axis yet.** datom gives `as-of`/`since` for free; a
   `code/ask … as-of <tx>` ("who called X three commits ago") is a small
   follow-up, not a new mechanism.

---

## 6. Files

```
tooling/mcp/jsonrpc.bl          protocol core (verbatim from spell)
tooling/mcp/transport-stdio.bl  stdio framing  (verbatim)
tooling/mcp/stdio_main.bl       spawned entry  (verbatim)
tooling/mcp/server.bl           dispatch + code:// resources (repointed)
tooling/mcp/tools.bl            code/list · code/query · code/ask · code/verify ·
                                code/subscribe · code/poll (rewritten)
tooling/mcp/demo.bl             eleven exchanges over the real self-index
priv/std/codebase.bl                impact/reachable target-binding fix (upstream)
tooling/run-mcp-demo.bl         runnable entrypoint
```
