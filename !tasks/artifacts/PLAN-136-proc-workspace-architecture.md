# A Beam Lisp workspace made from proc

Status: proposed architecture, not feature implementation. Main has been merged into `repl` as `c1bd7a56`, with a BL compiler fix and regenerated seed. This design supersedes the earlier stateless-looking `dev.workspace` sketch. All new domain logic, orchestration, state transitions, cache logic, view composition, and themes are Beam Lisp. Existing OTP/NIF/CodeMirror/browser transport primitives remain substrate, not a place to put a second implementation of the domain.

## 1. Start with the interaction

```clojure
(gen/ns "Build a namespace for recurring invoices. Separate calendar rules
         from money calculations; make both pleasant to experiment with.")
```

The user points at the form and evaluates it. No request map, manually allocated session, or cache key is needed. The evaluator already knows the project, buffer revision, enclosing namespace/definition, source span, and REPL session; it supplies that context to the operation.

The contextual sidebar opens the source symbol/call-site's **experience**:

- the prompt and visible conversation turns, arriving as they happen;
- request/validation/repair progress, with cancel available;
- a new namespace version, opening in the SAME structural buffer as hand-written code;
- definition outline, eval-form/selection, navigation, diagnostics, diff against the previous version;
- a short follow-up prompt and explicit Accept / Try in session / Publish actions.

`gen/ns` generates a namespace, not a renamed single-function generator: its candidate is a namespace declaration plus a coherent set of definitions. The current spike only accepts one `defn`, so its extraction/validation must be extended deliberately, with target-namespace ownership, project requires, and restoration of the caller's namespace checked. Existing `gen/f` and `gen/call` retain their function-oriented behavior and gain the optional namespace context; both feed the same experience/version machinery rather than two generation implementations.

A generation is a real stateful value. Evaluating the form returns its address immediately, printable in a terminal and renderable in the browser. It is not a blocking magic function whose state exists only inside an HTTP request.

Moving away collapses the experience to a row: symbol label, running/ready/error state, unread-turn count, and accepted version. It does NOT cancel the run, discard the buffer, accept a candidate, or move another browser's focus. Clicking the row reopens it; pinning prevents automatic collapse. Moving from the source into the sidebar keeps the same experience focused. Every encountered symbol/call site with an experience stays in that project's sidebar, grouped by file/namespace. This is a general experience registry, not a special popup attached to the text `gen/ns`.

Unsaved scratch buffers work too, but persistence is explicitly shown as session-only until attached to a source file. A generated namespace gets a stable derived identity from its source site; the optional `:ns` override remains available for programmatic use. The model cannot silently choose to overwrite a different live namespace.

Loading a file normally resolves accepted generated code. It never starts a paid model call because the cursor moved, a page reconnected, or a watcher reloaded the file. Explicit interactive evaluation starts/refines generation. Missing accepted code is reported as unresolved with a Generate affordance. This distinction must be an explicit evaluator/expansion contract, not a heuristic in JavaScript. Compile-time accepted expansion is deterministic and includes the sidecar content digest in freshness.

## 2. Process ownership, not a bag of functions

```text
existing project daemon / vm.session
└─ workspace supervision subtree (proc.super)
   ├─ directory                    proc/defserver + registry clause
   ├─ notifications                proc/defserver + bus clause
   ├─ workspace owner, per project proc/defserver
   │  ├─ file/buffer owners        proc/defserver, one writer per source/sidecar pair
   │  └─ experience owners         proc/defserver, active conversations/runs
   ├─ validation pipeline          proc/defserver + pipeline clause
   └─ maintenance worker           queue/sched only for suitable local work

existing vm.repl session
├─ forked project environment     experiments live here
├─ view state                    focus, pinned experiences, selected versions
└─ connection adapter            subscription + reconnect watermark, no domain authority
```

Logical handles contain project and object IDs, not a PID that becomes stale after restart. The directory resolves the current owner through `proc.reg`. Registry query keys use ordinary data; do not manufacture an atom per file, prompt, or run. Existing proc queue/pipeline declarations have VM-global names/read-model keys, so shared workers are daemon-scoped and all messages carry project/run identity. A separate same-named pipeline per experience would collide and is NOT the design.

### Ownership table

| State | Authority | Lifetime / recovery |
|---|---|---|
| Project identity, source inventory, buffer directory | workspace owner | daemon lifetime; reconstructed from project + stored artifacts |
| Buffer bytes, revision, source basis, edit plans | file/buffer owner | process restart continuity through held read-model state; disk changes reconciled explicitly |
| Prompt, turns, candidate versions, accepted pointer | source-owned ledger; file owner serializes writes | `.name.cache.bl`, survives daemon restart |
| Active request, provider request ID, cancellation epoch | experience owner and monitored worker | marked interrupted/uncertain if process/VM dies; never silently rebilled |
| Snapshot/index/progress rows | `proc.table`-held table, written by owners | survives keeper death; NOT disk durability |
| Session definitions/eval and current namespace | existing REPL session env | reattach retains the session while daemon lives |
| Focus, pinning, cursor, selected candidate | per-session view state | independent across clients; not shared project mutation |
| Published definitions | live project environment through `reload` | explicit publication, with coherence verdict |

The command owner does not run the LLM, compile candidate code, wait on a slow browser, or do long verification inside `handle-call`. It checks revision/auth/state, assigns an operation ID, dispatches bounded work, and responds. Worker results carry object ID, basis revision, and run epoch. A result for a cancelled/superseded epoch is recorded as stale, never installed as the latest candidate.

Reads are immutable snapshots projected from published rows, following the new pipeline pane's rule: **the read model is a fact, not a call to the process being inspected**. Repeated reads create no owners/tables, and the sidebar can still describe an interrupted run while its owner is restarting.

## 3. Actual proc primitives and their roles

Read directly in the merged source:

- `priv/std/proc.bl`: one require; `proc/defserver` is qualified because bare `defserver` is still the boot special form. Registry, bus, tick, queue, pipeline are clauses, not additional wrapper servers invented by the application.
- `proc.server`: compose state slices and DOWN handling through the clause expander.
- `proc.reg`: `register`, `whereis`, `where`; monitored identity lookup.
- `proc.super`: `defsupervisor`, child/pool specs, `children`, `child-of`; supervision with explicit restart intensity. A normal completion/cancellation must not restart a paid job.
- `proc.table/hold`: owner/heir continuity for ETS. It does NOT survive node death.
- `proc.bus/publish` and `proc.flow/subscribe`: fan-out with demand and per-subscriber lag policy.
- `proc.pipeline`: bounded stages, worker PIDs, throughput/lag/error rows; current `(from ...)` accepts a flow PID, sequence, or producer function.
- `proc.fence`: monitored child, deadline, crash/timeout as a value. This bounds work; it is not a security sandbox.
- `proc.tick`: debounce transient analysis/notifications where that is useful. Not a polling substitute for messages.
- `proc.sched`: declared maintenance deadlines; no private recurring timer loops.
- `proc.queue`: suitable for explicitly retryable local work. It is at-least-once and currently uses a held ETS-backed datom store. `cancel!` cancels work not yet started, not an active provider request. Neither exactly-once billing nor disk persistence is supplied by the bundle.

Example declaration SHAPE using existing proc syntax; application functions below are proposed:

```clojure
(ns dev.workspace.runtime
  (:require [proc :as proc]
            [proc.pipeline :as pipeline]))

(proc/defserver directory
  (registry (keys :project :kind :id)))

(proc/defserver notifications
  (bus (demand 16)))

(proc/defserver validation
  (pipeline
    (from (candidate-stream))
    (stage :read parse-candidate {:concurrency 2})
    (stage :check check-candidate {:concurrency 2})
    (stage :compile compile-in-isolated-env {:concurrency 1})
    (stage :report report-candidate)
    (on-lag :block)
    (on-error :fail)))

;; Real inspection APIs, not a parallel progress counter:
(pipeline/pipeline-of :validation)
(pipeline/worker-vitals worker-pid)
(proc/where directory {:project project-id :kind :experience})
```

The candidate stream must obey demand; a bare fire-and-forget mailbox is not backpressure. Validation stages pass a typed result envelope so a normal syntax/type failure becomes a repair turn, not an accidental stream crash. Infrastructure failure is surfaced to the owner. The conversation loop remains in the experience state machine: provider response -> validation -> candidate or repair request. It is not an unbounded `on-error :requeue` pipeline around a billable request.

Supervision restarts services; explicit run policy decides whether an operation is safe to retry. Rebuilding a crashed UI subscription is safe. Reissuing an LLM request with uncertain completion is not. Record that uncertainty and let the user resume, or use provider idempotency only where actually supported.

## 4. State transitions and public API

Separate two state machines:

```text
run:       queued -> requesting -> streaming -> validating -> ready
                                          \-> repairing -> requesting
           any active state -> cancelled | failed | interrupted
version:   candidate -> accepted
buffer:    clean -> modified -> verified -> saved
runtime:   unchanged -> staged -> applied | held
view:      collapsed <-> focused; pinned is independent
```

Acceptance and publication are different operations. Trying a candidate uses the session environment. Accepting saves the chosen version into the source-owned ledger. Publishing uses `reload/stage` and coherent `reload/commit` against the project image. A held publication leaves the old project code serving. The UI can offer an explicit combined Accept & Publish command, but the receipt must distinguish durable acceptance from runtime publication; a filesystem write and a live-image commit are not one atomic transaction.

Proposed programmatic surface (not existing APIs):

```clojure
(require '[dev.workspace :as ws]
         '[gen :as gen])

(def w (ws/attach! "."))             ; stable handle to daemon-owned workspace
(def b (ws/open! w "src/billing.bl")) ; stable buffer identity + revision
(ws/snapshot b)                      ; immutable value, not mutable state exposed
(ws/definitions b)

;; The ordinary experience needs none of that setup in a loaded REPL buffer:
(def x (gen/ns "Recurring invoices, with calendar rules separated from money"))

(ws/snapshot x)                      ; same value that the sidebar renders
(ws/turns x)
(ws/versions x)
(ws/refine! x "Handle leap-day anniversaries explicitly")
(ws/cancel! x)

;; Candidate source is an ordinary structural buffer:
(def v (ws/version-buffer x :latest))
(ws/definitions v)
(ws/eval! v '(invoice/date {:day 29 :month 2} 2028)) ; session-only

;; Commands carry a basis automatically from the addressed snapshot/selection.
;; Conflicting edits return a conflict receipt, not last-writer-wins data loss.
(ws/accept! x (:version (ws/snapshot v)))
(ws/stage! v)
(ws/publish! w)                      ; -> applied or held with reasons
```

API naming will follow existing conventions during implementation. The invariant is the important part: queries return ordinary composable values, commands target stable owned objects and return operation/receipt values, and every mutation has a checked basis. No global ambient workspace atom; the evaluator's convenience context is explicit and bound to the session.

## 5. Events, streaming, and reconnect

The source owner assigns monotonically ordered event revisions. Persist semantic conversation turns, candidate source and acceptance before acknowledging those durable actions. In-progress token chunks may be coalesced; completed turns cannot be silently dropped. Do not fsync every token.

Notifications are invalidations/progress, not the only copy of history. A bounded subscriber can use `:drop-oldest` for replaceable view notifications; a revision gap causes a snapshot refresh. Reliable turn recovery reads the ledger. This prevents a hidden/suspended browser from blocking generation, and avoids claiming that `proc.bus` is a durable replay log.

Reconnect protocol: subscribe, acquire a snapshot/watermark, then apply buffered events newer than that watermark. Dedupe by revision. Missing revisions force resynchronization. Focus/hover messages also carry buffer revision; a delayed hover response for an older edit cannot open the wrong experience.

`gen.llm/chat` currently returns a complete response, not a token stream. Real token streaming requires extending the SAME pure-BL provider seam using OTP HTTP streaming, parsing the provider stream in BL and emitting events. Do not fake streaming with typewriter animation after the response has finished. Visible turns/progress work independently of token streaming.

## 6. One source file, one ledger; one buffer protocol

`src/billing.bl` owns `src/.billing.cache.bl`. The ledger contains all that source's experience identities, visible turns, immutable namespace versions, validation provenance, and accepted pointers. The model's private reasoning is not a UI requirement; show only returned content, explicit tool actions, and validation/repair steps.

Identity is structural source ownership, not cursor line number or the spelling `gen/ns`. Use enclosing symbol plus structural call-site identity and persisted matching information. A move preserves history when unambiguous; duplicate/ambiguous sites require reconciliation instead of attaching another site's accepted code. Prompt/context changes mark accepted code stale rather than silently presenting a cache hit. Revision/basis checking covers external editor writes and simultaneous tabs.

The accepted-version macro parses the ledger as data and emits only the accepted version. Never evaluate historical entries to find the accepted one. Sidecar hashes participate in AOT freshness. Generation workers cannot race direct file writes; all updates go through the source owner and the existing guarded edit transaction path. File replacement uses the existing filesystem substrate; new policy/orchestration is BL.

Namespace, file, definition and generated version are addresses into one buffer protocol. Reuse reader spans, `span-rewrite`, `lsp`/`codebase`, `dev.change`, and `reload`. Existing `dev.change` is a thin BL namespace over an Elixir executor; that substrate can be called, but no new domain rules go into it. If missing multi-target/whole-buffer semantics require moving its orchestration to BL, that is a cutover of the one executor, not a second editor beside it. No claim of multi-file atomic rename until its transaction and rollback contract is implemented and tested.

## 7. Pure-BL UI and scope boundaries

Compose views in BL with the existing live/loom primitives and shared design tokens. Carbon and Snow change palettes, not component behavior. Keep CodeMirror as the editing substrate and the existing JavaScript transport as a thin DOM/editor adapter. It forwards cursor/selection/edit events and applies server-authored view/effect values; it does not own generation state, cache policy, or a parallel workspace model.

The file sidebar and experience sidebar may be two sections of one rail; focus expands the contextual section, leaving source navigation available. Accessibility: keyboard focus can enter the panel without collapsing it, pin/unpin and cancel are keyboard-reachable, progress is announced without announcing every token, and both themes preserve contrast/focus indication.

## 8. Implementation and proof sequence

1. Stateful workspace addresses/read model/owners and the evaluator context; CLI loads a file in the project's daemon session exactly once.
2. Shared buffer/navigation/edit/reload protocol in BL, with explicit saved/staged/live states and conflict receipts.
3. `gen/ns`, source-owned experience identity, version ledger and accepted expansion/freshness; deterministic fake-provider tests before live-provider smoke.
4. BL sidebar/view projection plus thin existing editor adapter; focus collapse/pin/reopen; Carbon/Snow tokens.
5. Streaming provider transport, cancellation epochs, reconnect watermarks and fault/recovery tests.

Proof includes cold daemon restart, owner crash, lost connection mid-turn, stale candidate arrival after cancel, duplicate evaluate requests, concurrent edits/acceptance, Unicode cursor offsets, whole namespace compile/coherence failure, source move/ambiguous identity, cache corruption and changed accepted version invalidating AOT. Never claim that compilation, a fence or a forked environment sandboxes arbitrary generated code.
