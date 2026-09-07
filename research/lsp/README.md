# A language server that is not a server

First-party language intelligence for beam-lisp, built as pure functions over
the analyzed program — no protocol, no external process, no re-parse. Every
answer is a projection of `:ann` (position + proofs + types) and
`system.analyze` (whole-program summaries).

## Why beam-lisp collapses the LSP split

A conventional LSP has two halves that do not trust each other: a language
server that re-parses text to answer positional questions, and a host editor
that owns the truth. beam-lisp has no such split — **the compiler is the
analyzer**. Position, inferred types, effect footprints, termination proofs, and
the call graph all already live on the IR. A "language server" is then a thin
index-by-position over that, and every request is a few lines.

## Measured: every request, working (research/lsp/lsp.bl)

Input:
```clojure
(defn mk [] :kw)
(defn double [x] (erlang/* x 2))
(defn use-it [n] (erlang/+ 1 (mk)))
(defn caller [n] (double (use-it n)))
(defn dead [] 42)
```

### Core LSP requests

| request | result |
|---|---|
| `hover 2:18` | `call erlang/* : (:float :int)` — inter-procedural type |
| `definition 4:18` | `{:resolves-to "double" :kind :user-fn}` |
| `references "double"` | `("caller")` — graph-based, not grep |
| `document-symbols` | each fn + `{returns terminates pure calls}` |
| `diagnostics` | `3:30 type error: + expects [:float :int], got [:kw]` |

The diagnostic is the inter-procedural bug — `mk` returns `:kw`, flowed into
`+` across the call — caught at the exact argument position. A single-function
checker cannot see it.

### Beyond LSP — requests the protocol has no words for

LSP is a fixed request menu designed around a syntax-only server. These need
*proofs the compiler computed*, so no LSP can express them:

| request | result | why LSP can't |
|---|---|---|
| `proof-hover "double"` | `{pure true, terminates true, footprint {}, returns (:float :int)}` | no proof channel |
| `native-eligible "double"` | `{:eligible true, "pure ∧ terminating"}` | no notion of compile-to-native |
| `impact "use-it"` | `["mk" "use-it"]` — transitive blast radius | references go one hop |
| `dead-code ["caller"]` | `("dead")` — sound, keeps callbacks live | no whole-program reachability |

## The full first-party LSP surface (what maps cleanly)

Everything below is answerable from `:ann` + summaries today or with a small
extension. Grouped by what already exists in the engines:

**Ready now (prototype implements):** hover, publishDiagnostics,
documentSymbol, definition, references, (signatureHelp from `:args`/`:ret`
meta).

**Small extension:** completion (symbols in scope from the env + summary
return types for ranking), rename (the structural node-walk from the subst-sym
cutover, applied file-wide via the call graph), codeAction (every deodorant
smell is a quick-fix; the span-preserving rewrite makes the edit trivia-safe),
inlayHint (inferred return tags + effect markers), documentHighlight (all
references to the symbol under the cursor), foldingRange (from node spans),
selectionRange (parent spans up the ANF), semanticTokens (op kind per node).

**Uniquely beam-lisp (no LSP analog):** proof-hover, native-eligibility gutter,
effect-footprint lens, "prove this invariant" code action (drive
`system.core/verify-process` from the editor), termination lens, impact
analysis, "why is this `any`?" (trace the return-tag inference), and
live-reload-aware diagnostics (the reload engine already knows what a change
breaks).

## Known gap (honest)

`native-eligible` currently checks pure ∧ terminates only. The doc-05 gate also
requires `types ⊆ NIF-safe sorts` and a work bound. `use-it` shows the gap: it
is pure+terminating but has a type error, so it should be refused on the sort
theorem. Wiring `typed`/`smt` sort-check into eligibility is the next step (see
`research/native-eligible/`).

## Productionization

Two forms, same core:
1. **In-executable command** — `bl lsp hover FILE:L:C`, `bl lsp diagnostics FILE`
   — the intelligence with a CLI skin.
2. **stdio JSON-RPC shim** — a ~100-line transport mapping LSP methods to these
   functions, so any LSP editor (VS Code, Neovim, Emacs) talks to the beam-lisp
   compiler directly. The shim is dumb; the compiler is smart.
