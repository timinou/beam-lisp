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
callee's proven return type.

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

`editors/README.md` has ready configuration for Emacs (eglot, via the bundled
major mode), Neovim (both `nvim-lspconfig` and 0.11's `vim.lsp.config`), VS
Code, and any other generic LSP client — plus a hand-run protocol example. Point
the client at `bl lsp serve`; inside the checkout use `mix bl lsp serve`, or put
`bl` on `PATH`.

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
   "capabilities": {"tools": {}, "resources": {"listChanged": false, "subscribe": false}}}}
```

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
