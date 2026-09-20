# API playground implementation contract

Read BOTH architecture documents completely before work:
- `!tasks/artifacts/PLAN-136-proc-workspace-architecture.md`
- `!tasks/artifacts/PLAN-136-change-sets-and-repl-parity.md`

User requests an API-FIRST runnable prototype, friendly tutorials, and actual visual browser validation. All new production/domain/UI composition code is BL. Existing OTP, filesystem, reader/compiler, CodeMirror/browser transport substrate may be reused. Do not build a second production editor. Prototype code lives under `research/workspace-spike/`; add that directory as a search root to load `dev.workspace`, `play.change`, `play.gen`, `play.ui`. Existing dev.change must remain intact; the prototype's play.change is explicitly a candidate API, NOT another production executor. The final cutover location is dev.change. Document that naming distinction. No full production claims about crash-atomic multi-file save, sandboxing, automatic refactor or durable tokens.

## Full envisioned API

Project and file inventory, namespaces/definitions/references; new/open/close/save/save-as buffers; create/copy/move/trash/restore files/directories; structural replace/add/require/create-namespace/move-namespace/rename-def proposals; preview/verify/try/save/make-live/status/undo; gen/ns/refine/cancel/turns/versions; contextual REPL for all UI elements; view/theme/focus/pin/collapse. Proposed source and cross-namespace changes form one dependency-closed proposal. Made, Saved, Live are independent revision pointers. `.file.cache.bl` is the one source-owned gen ledger; unrelated touched files do not grow generation caches. Shared logical handles, not stale PIDs; daemon owns state; snapshot reads must not block on LLM calls. Paid calls are never automatically requeued. No provider request on hover/load/reconnect. Candidate compilation is not a sandbox.

## Prototype slice — implemented, not promises

A disposable `examples` fixture is copied by the launcher into a chosen workspace under `/tmp` by default. Do not edit user's real project automatically. The spike supports one workspace actor per root, real source/buffer/proposal state, guarded file persistence, namespace evaluation in isolated session env, and explicit live publication. Restart reloads persisted proposal/cache state; restored Saved is known, Live must NOT be fabricated after restart.

The prototype implements the APIs listed in the next sections. Larger inventory features (cross-file rename, full undo history, durable coordinator crash recovery, token-level streaming) may be explicit unsupported commands with honest UI/docs, not fake successes. Keep tests for the supported slice. Model generation is opt-in; fake provider is default.

## Namespace/file ownership

- `research/workspace-spike/play/change.bl`: pure constructors + restricted model-response decoder + structural materializer. Owner: change worker.
- `research/workspace-spike/dev/workspace.bl`: stateful public API using proc, snapshots, file/proposal/save/live lifecycle. Owner: workspace worker (can be same as change worker).
- `research/workspace-spike/play/gen.bl`: async generation + fake/DeepSeek seam, versions/turns, cache persistence. Orchestrator owns.
- `research/workspace-spike/play/ui.bl`, `ui-client.js`, `ui.css`: BL-rendered Carbon/Snow playground over EXACT APIs. UI worker owns.
- `research/workspace-spike/serve.bl`, `api_walkthrough.bl`, `README.md`, tests and fixture files: orchestrator owns unless delegated later.

## Concrete data contract

Handles are ordinary maps with `:kind` (`:workspace`, `:buffer`, `:proposal`, `:experience`), `:root` canonical absolute workspace root, `:id` stable string. Public reads return ordinary values. Domain errors throw ex-info with message and useful data; no raw provider auth/secret response dumps.

Workspace snapshot: `{:kind :workspace :root :files [relative .bl paths] :buffers [buffer snapshots] :proposals [proposal snapshots] :experiences [experience snapshots]}`.
Buffer snapshot: `{:kind :buffer :root :id :path relative :source string :basis string-or-nil :dirty? bool :ns string-or-nil}`.
Proposal snapshot: `{:kind :proposal :root :id :title :revision string :status :made|:verified|:conflict|:failed :changes [{:path relative :before string-or-nil :after string-or-nil :basis string-or-nil :reason string}] :made revision :saved revision-or-nil :live revision-or-nil :verification map-or-nil :error string-or-nil}`. Empty file string differs from nonexistent nil. Save must verify all bases BEFORE writing; stale basis throws and writes nothing. Mark live only after successful evaluated/committed candidate; failed eval must not advance Live. Live scope is prototype workspace runtime env, NOT arbitrary existing application process migration.
Experience snapshot: `{:kind :experience :root :id :source-path relative :prompt string :status :queued|:running|:ready|:failed|:cancelled :turns [{:role string :text string}] :versions [proposal handles] :proposal latest-handle-or-nil :error string-or-nil}`.

## play.change constructors (worker implements)

`(bundle title & ops)` -> `{:title title :operations vector}`.
`(create-namespace ns-symbol & quoted-definitions)` -> operation creating namespace source under `src/<ns path>.bl`, refusing existing file.
`(in-namespace ns-symbol & ops)` -> scoped operation group.
`(require quoted-require-vector)` -> add/merge require in ns declaration using reader structure.
`(replace-definition name-symbol quoted-defn)` -> replace exact existing top-level definition, refuse missing/ambiguous/name mismatch.
`(add-definition quoted-defn)` -> append named definition, refuse duplicates.
`(create-file relative source)` / `(move-file from to)` / `(delete-file relative)` -> file operations, path guards at materialize stage.
`(materialize root bundle)` -> change vector with before/after/basis/reason. Resolve against original source, group edits per file. Reuse reader spans + span-rewrite; preserve untouched comments. No arbitrary model text evaluation.
`(decode text)` -> bundle, accepting only `(change/bundle ...)` plus the constructor names above with literal strings/quoted symbols/quoted vectors/quoted forms. Reject unknown constructors/expressions. Allow ```clojure fenced output. Parse using existing reader; do NOT eval model response. Reject paths outside root, absolute paths, symlink escape, .env/dotfile access, and shipped namespaces from this prototype.
`(digest source)` -> SHA256 hex string; nil stays nil, used by workspace tests/basis checks.

## dev.workspace public slice (worker implements)

`attach! root` -> stable workspace handle; reuse existing owner. `shutdown! w` -> stop owned prototype runtime (for restart test).
`files w` -> sorted relative .bl source paths (exclude caches/internal/dotfiles).
`open! w relative` -> buffer handle; `new-file! w relative source` -> dirty draft buffer; refuse overwrite.
`snapshot handle` -> workspace/buffer/proposal/experience snapshot.
`edit! buffer source` -> updated buffer handle; `close! buffer` refuses dirty data loss.
`definitions w ns-symbol` -> definition records `{:name :ns :kind}` using source reader; no regex parser.
`propose! w bundle` -> proposal handle; materialize through play.change.
`preview p` -> proposal snapshot incl before/after.
`verify! p` -> proposal snapshot, parses/compiles proposal as a coherent set in isolated env; no writes to source. At minimum syntax + namespace load across closure; return checks honestly, do not call unrun tests passed.
`try! p` -> verification/session evaluation, does not set Live.
`save! buffer-or-proposal` -> updated snapshot; buffers do basis guards; proposals require current verification and all basis guards before mutation. Workspace-owned receipt stores prior bytes for supported undo. Save without Live, Live without Save both supported. Proposal change writes are eager, not lazy map side effects. Failure rollback must avoid overwriting unrelated current bytes; clearly scope prototype crash recovery.
`make-live! p` -> evaluate the complete staged namespace bundle into workspace-owned runtime env, with old runtime preserved on failure. This can use env fork + evaluate all sources then swap workspace runtime-env pointer, rather than mutate global VM namespaces. Report that scope explicitly.
`eval! w source` -> evaluate in workspace's active runtime env; returns printed result string. All UI REPL requests use this, NOT global eval.
`status p` -> {:made :saved :live :status :verification :error}.
`undo! p` -> guarded inverse proposal handle, not immediate destructive rollback.
`remember! w experience-snapshot` -> store/replace experience by id (for gen). `experience w id` -> handle; snapshot handles work. `record! w key value` and `record w key default` optional internal serializable state seam for gen persistence, no global ambient atom.

Per-eval convenience binding for gen/ns: `(play.gen/use! w "src/playground.bl")` establishes context in current eval environment; `(play.gen/ns prompt)` resolves that explicit session context. `(play.gen/ns w source-path prompt opts)` is explicit alternative. Do not invent require function: use `(ns user (:require [dev.workspace :as ws] [play.change :as change] [play.gen :as gen]))` in examples because current BL requires are ns clauses.

## play.gen (orchestrator implements)

`use! w source-path` -> context, `ns` overloads above returns experience immediately. opts has `:provider :fake|:deepseek`, bounded repair count, `:ns` explicit namespace context (prototype may pass as prompt constraint/materializer target).
`await! x timeout-ms` -> terminal snapshot, `refine! x prompt` -> new run version, `cancel! x` -> terminal cancellation with epoch guard; late response cannot publish.
`turns x`, `versions x`, `proposal x` -> values.
`restore! w source-path` reads sidecar as DATA and restores history/last saved proposal, no model call.
`accept! x` explicitly saves verified proposal then updates sidecar accepted pointer; must check source basis and avoid fake saved state on failure. Prototype cross-sidecar transaction caveat must be surfaced if not fully coordinated.
Fake provider emits a real companion edit against fixture `app.invoices/total`, creates `billing.rules/total` and adds a test; fixed quoted forms.
DeepSeek uses existing gen.llm/chat or a narrowly extended pure-BL seam. Read `.env` only to populate the key, never print/return it; no secret-bearing files in model context. Max e.g. 1 initial + 1 repair request per run. Initial spike can stream semantic turns/state, not fake token streaming. Reject any invalid constructor output before source changes.

## UI contract (worker implements)

`play.ui/handler w` -> Ring/Plug-style web conn fn using existing web APIs; orchestrator mounts it alongside existing vm.repl routes in SAME process/runtime server for prototype. Serve BL-generated hiccup HTML using existing live.hiccup, CSS token palettes Carbon/Snow, existing CodeMirror bundle at /repl/editor.bundle.js if desired. JS thin adapter only: forms -> JSON commands, state/view updates, editor sync, focus/collapse, browser-local theme. No state machine/cache/domain policy in JS.

GET /play -> friendly API playground: file navigation, code buffer/editor, contextual generation experience rail, Made/Saved/Live badges, proposal per-file before/after, prompt+visible turns, REPL panel, command receipts/help. Every file/proposal action displays/copies its actual BL form. Buttons: open file, new file draft, save buffer, generate (fake default, explicit DeepSeek selection), verify/try/save/make-live proposal, cancel, focus/pin/collapse, switch themes. Unsupported operations are not advertised as working.
GET /play/state -> sanitized serializable state, GET assets -> CSS/client. POST /play/command -> allowlisted command dispatch directly to ws/gen APIs; all user content escaped; no secrets. Restrict server loopback, enforce request token/origin for mutations using existing web/vm auth pattern. `play.ui/handler` may take optional opts {:token ...} so launcher supplies token. Never interpolate user text into eval strings for buttons; only REPL input invokes ws/eval! explicitly.
If UI worker needs gen before implementation, use known APIs and have orchestrator resolve integration. No provider calls by worker. No global tests/builds by worker. Return exact targeted checks for orchestrator.

## Verification and delivery

Orchestrator runs global/focused tests after join, both fake and bounded actual provider, restart/conflict/cancel tests, API walkthrough script, real browser checks of Carbon+Snow, file editing, generation/turns/proposal previews, Made/Saved/Live actions and REPL. Screenshots saved as artifacts, report unverified portions honestly. Friendly README walkthrough describes behavior from zero context, executable command forms, how to reset only disposable fixture, provider opt-in and safety limits. Never touch unrelated journals or other worktrees.
