# Editors and agents

beam-lisp meets a tool on three surfaces. Two speak a standard protocol, so any
client that speaks it reaches the language; the third is `--json`, which every
command that produces a report offers.

| surface | command | protocol |
|---|---|---|
| intelligence | `bl lsp serve` | Language Server Protocol over stdin/stdout |
| facts | `bl mcp` | Model Context Protocol, one JSON object per line |
| reports | `bl … --json` | one JSON object per command run |

`bl doctor --json` reports what the machine can do, for an agent deciding what
to try.

## The language server

`bl lsp serve` is an LSP server on stdin/stdout. It frames each message with a
`Content-Length` header, exactly as the protocol requires.

### What it advertises

On `initialize` it answers with the capability set it can actually honour —

```json
{"capabilities":
  {"textDocumentSync": {"openClose": true, "change": 1, "save": true},
   "hoverProvider": true,
   "definitionProvider": true,
   "referencesProvider": true,
   "documentHighlightProvider": true,
   "documentSymbolProvider": true,
   "completionProvider": {"triggerCharacters": ["(", " "]},
   "signatureHelpProvider": {"triggerCharacters": ["(", " "]},
   "inlayHintProvider": true,
   "codeActionProvider": {"codeActionKinds": ["quickfix", "refactor"]}},
 "serverInfo": {"name": "beam-lisp", "version": "0.1.0"}}
```

— and then:

- **lifecycle** — `initialize`, `initialized`, `shutdown`, `exit`;
- **documents** — `textDocument/didOpen`, `didChange`, `didSave`, `didClose`,
  with `publishDiagnostics` on open and change;
- **features** — `hover` (carrying the compiler's proof card), `definition`,
  `references`, `documentHighlight`, `documentSymbol`, `completion`,
  `signatureHelp`, `inlayHint`, `codeAction`.

Diagnostics, definitions and references come from the compiler's analysis, not
from re-parsing: a reference is a real call-graph edge, and a hover reports the
callee's proven return type. The analysis is not confined to function bodies:
the forms a script runs at top level are compiled into a synthetic `<top>`
function — the same name the codebase db and `bl ask` print — so hover,
definition, references, highlights and signature help answer there too, a
script's use of a fn keeps it out of `deadCode`, and a type error in a
top-level form squiggles like any other. Pointing at a definition's own head
answers that fn's proof card. Mid-edit text that does not parse yet answers
every feature with its empty result — the parse-error diagnostic already says
why.

### Requests the protocol has no words for

The proof-backed queries are reachable as `$/beamlisp/` methods. Each takes
`uri` and `fn` (plus `roots` for `deadCode`) and answers with the compiler's
data:

| method | params | result |
|---|---|---|
| `$/beamlisp/proof` | `uri`, `fn` | the proof summary: `pure`, `terminates`, `returns`, `footprint`, `calls` |
| `$/beamlisp/nativeEligible` | `uri`, `fn` | `{eligible, note}` — whether the fn can offload to native code |
| `$/beamlisp/impact` | `uri`, `fn` | every fn that transitively calls `fn` |
| `$/beamlisp/deadCode` | `uri`, `roots` | fns unreachable from `roots` |

```json
{"id": 3, "result": {"calls": ["dist2"], "fn": "step", "footprint": {},
                     "pure": true, "returns": ["float", "int"], "terminates": true}}
```

### Wiring an editor

`bl install` does the wiring (see
[00-the-cli.md](00-the-cli.md#install)): `bl install doom` installs the Doom
Emacs module — the major mode, the tree-sitter grammar, LSP registration, a
warm REPL, and first-party literate `.bl.md` / `.bl.org` support — and
`bl install mcp` writes the agent instructions and client registration for
MCP clients. The sections below remain the hand-run reference for clients
the installer does not know yet (Neovim, VS Code) and for understanding what
the installer writes.

`bl lsp check FILE` is the same analysis without an editor — see
[00-the-cli.md](00-the-cli.md#bl-lsp-check-file---json).

## The codebase, as facts

`bl mcp` is a Model Context Protocol server on stdin/stdout. It exchanges one
JSON-RPC object per line, and only **answers** cross the wire — never whole
files. The protocol version is `2026-07-28`.

A client starts with `server/discover`:

```json
{"jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": {}}
```

```json
{"id": 1, "result": {
   "protocolVersion": "2026-07-28",
   "serverInfo": {"name": "beam-lisp-mcp-server", "version": "0.1.0"},
   "capabilities": {"tools": {}, "prompts": {"listChanged": false},
                    "resources": {"listChanged": false, "subscribe": false}},
   "instructions": "# beam-lisp MCP — onboarding\n\n## What you are holding\n\n…"}}
```

### Instructions are facts; a prompt is a query result

The server's instructions are not a file — they are datoms in the same
database that holds the code facts, mounted beside them at startup. Each
fragment is an entity with `:instr/id` (a unique identity — re-asserting
amends), `:instr/for` (the surface: `"mcp"`), `:instr/kind`
(`:onboarding` | `:usage` | `:protocol`), `:instr/order`, `:instr/title`,
`:instr/text`. Two authoring styles, one fact space:

- **the corpus document** — `priv/lib/mcp/instructions.bl.md` holds the
  fragments about the surface as a whole;
- **colocated annotations** — `^{:instr {…}}` on an `(ns …)` or `defn` NAME
  puts an instruction in the namespace it describes, and the indexer
  (`codebase.bl`) emits it as the same kind of fact.

The prompt surface is three queries over those facts:

| prompt | kind | when a client reads it |
|---|---|---|
| `beam-lisp/onboarding` | `:onboarding` | first contact, once (also on `server/discover` as `instructions`) |
| `beam-lisp/usage` | `:usage` | on task start; closes with the live registry — tools, questions and counts as they are right now |
| `beam-lisp/protocol` | `:protocol` | before extending or amending the instructions |

`prompts/list` advertises them; `prompts/get` assembles one. Because the
facts sit in the served database, `code/query` can read the instructions
too — an agent can check where its instructions come from. `bl install mcp`
projects the same corpus into markdown files; the files and the prompts
cannot drift, because both are projections of one corpus.

`tools/list` returns the tool surface:

| tool | answers |
|---|---|
| `code/list` | the mounted codebases and their manifests (namespaces, fn/call counts) |
| `code/query` | datalog over the fn/call facts; rules are available for reachability |
| `code/ask` | a named question — `impact`, `callers`, `reachable`, `returns-type`, `arity-mismatches`, `unknown-callees` |
| `code/verify` | prove a `defserver`'s `^{:invariant}` with z3; synthesize a repair when it fails |
| `code/subscribe` | watch the fact space: fire when a fn gains or loses a caller |
| `code/poll` | drain the events a subscription has accumulated |

`code/ask` is the ergonomic layer — the same named questions `bl ask` answers,
with one implementation behind both doors. A question that needs a target and
gets none returns `input_required` (MRTR) so the client can elicit it, rather
than guessing:

```json
{"resultType": "input_required",
 "inputRequests": [{"method": "elicitation/create", "params": {…}}]}
```

Answers are rows:

```json
{"result": {"question": "reachable", "target": "sum-squares",
            "rows": [["map"], ["reduce"]], "resultType": "complete"}}
```

The mounted codebase is beam-lisp indexing itself — the code-as-facts engine
(`codebase.bl` + `typed.bl`) served back as facts. Those two sources are
resolved through the load path, not the working directory, so a client that
starts `bl mcp` anywhere gets the same facts; the mount is paid once at startup
and reused by every request.

Two resources accompany the tools:

| resource | answers |
|---|---|
| `code://beam-lisp/schema` | the fact schema: the `fn` and `call` attributes |
| `code://beam-lisp/namespaces` | the namespaces currently mounted |

## `--json`, the third surface

Every command that produces a report offers `--json`, and it prints exactly
**one JSON object per run** — the same value the human report renders, so the
two can never disagree.

| command | object keys |
|---|---|
| `bl test` | `tests`, `pass`, `fail`, `error`, `files` |
| `bl examples` | `files` (`path`, `status`), `passed`, `skipped`, `failed`, `ok` |
| `bl lint` | `files` (per file: `path`, `smells` — `name`, `tier`, `line`, `before`, `after`), `total` |
| `bl fix` | `files` (`path`, `changed`, `applied`), `changed`, `skipped`, `failed` |
| `bl check` | `files`, `metrics`, `ok`, `regressions` (+ `note`, `updated`) |
| `bl ask` | `question`, `target`, `rows`, `count` |
| `bl doctor` | `ok`, `probes` (`name`, `ok`, `detail`, `required`) |
| `bl lsp check` | `diagnostics`, `symbols` (`name`, `returns`, `pure`, `terminates`, `calls`) |

A pipeline can gate on the exit code and read the object when it needs the
detail:

```sh
$ bl check --json | jq .regressions
```

## `bl doctor --json`

`bl doctor --json` is the environment report as one object: `ok`, and `probes`,
each with `name`, `ok`, `detail`, and `required`. An agent reads it before
choosing a strategy — a missing optional native is a `false` probe, not a
failure.

```json
{"ok": true,
 "probes": [
   {"name": "language",   "ok": true,  "detail": "(+ 1 2) → 3", "required": true},
   {"name": "lazy_memo",  "ok": true,  "detail": "65536 bytes fast lane", "required": true},
   {"name": "z3",         "ok": true,  "detail": "sat", "required": false},
   {"name": "daemon",     "ok": false, "detail": "not running (:no_socket)", "required": false}]}
```

The two required probes are the language evaluating and the LazyMemo fast lane
answering; a build without them is not a working beam-lisp. Everything else is a
capability this host may or may not carry.
