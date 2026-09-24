# The workspace editor

The workspace is one place to write, ask for a change, inspect its consequences, and evaluate a form. Its central object is a **working context**: a file or experience, the source revision it sees, and the proposal (if any) derived from it. Buffer, Generate, and Proposal are not separate destinations. They are views of that context.

This document specifies the intended product, not the current prototype implementation. The illustrated [page-by-page proposal](../../research/workspace-spike/editor-design-proposals.html) pairs real prototype screenshots with schematic future states. [Form-first interaction](form-first-interaction.md) specifies selection and evaluation precisely.

## One work surface

```
Project / file breadcrumb                Session and provider status · Actions
Files + Work rail   │ Source / selected form                 │ Context inspector
                    │─────────────────────────────────────────│
                    │ Generation timeline ↔ review diff       │
                    │─────────────────────────────────────────│
                    │ Console / result shelf (collapsible)    │
```

The center is a **single scrollable story**, not three mandatory columns of full content and not four mutually exclusive tabs. Source is the anchor. A generation attaches a timeline to the source revision it read. A proposal attaches its diff to the timeline version that produced it. Selecting a changed hunk takes the reader back to its source form; returning to the timeline preserves the same proposal, scroll position, and selection. When no generation is selected, the source owns the space. Focus mode may collapse the rail, inspector, timeline, or console independently; it does not discard their state. A narrow niri tile shows one main region and a contextual drawer, with the same relationships and commands.

The rail groups **Files** and **Work**; each row has a clear active state and relevant draft/running count. The header uses a short project/file name, with the full path available on focus or in details. The inspector follows the selected form/file/experience; it never changes a REPL binding merely because the mouse moved. Technical BL forms belong in a searchable API disclosure. Nothing in the shell imitates an OS title bar.

### Source → intent → consequence

1. **Write.** Open a buffer, type in Insert mode, and see an explicit draft indicator. The editor takes the available height. A draft is not a disk save; switching work preserves it. `Save file` is a file operation, not a proposal approval.
2. **Choose scope.** Select a form or a file, type an intent, and review the chosen source revision and provider before starting. Demo is offline. A network provider discloses the file content sent and potential cost. The current prototype's `gen/ns` receives a path; consuming an unsaved draft or form-specific scope requires a new backend contract. Until then the UI must say **Saved source only** rather than suggest draft scope works.
3. **Follow a timeline.** Each run owns its own sequence: request, source basis, provider phase, completed response, validation, candidate version, review, and any later decision. The timeline is a record of observed events, not a simulated token stream. An entry links to its source and proposal version. Follow-ups add versions in the same experience; they do not overwrite prior candidates.
4. **Review in context.** The selected candidate expands a file list and navigable diff directly under its timeline entry. Source and diff share path/form breadcrumbs. A review mode may widen the diff without losing the story. Verification explicitly names the checks performed; namespace load is not a project test run.
5. **Decide deliberately.** Verify, Try, Save source, and Make Live are distinct. A generated candidate's acceptance may also move an accepted-history pointer; the confirmation names both effects. Inverse proposals are new candidates requiring verification and a guarded save, not an instant undo.
6. **Explore.** A selected form can be evaluated in the workspace runtime; a compact inline result sits next to it and a durable receipt goes to the console. The form is not saved, generated, accepted, or made live by evaluation. The runtime may nevertheless change because evaluation is real execution; this distinction remains visible.

### Timeline event contract

A timeline entry has a stable `event-id`, `experience-id`, monotonically ordered sequence, event kind, status, source basis, optional proposal version, and optional artifact/result reference. Useful kinds are `request`, `scope`, `provider`, `candidate`, `verification`, `review`, `save`, `publish`, `cancel`, and `failure`. Backend facts produce entries; the client does not infer a successful save or publication from a button click. A provider response is a **completed response**, not streaming unless the transport actually supplies incremental chunks. Late responses after cancellation remain attached to the cancelled run as rejected/ignored, never to the active candidate.

Selecting an older timeline event opens a **history lens**: its frozen source and diff are read-only, labeled with the event time and basis, while the present draft remains intact behind a visible “Return to current draft” action. A hunk may locate a corresponding form in the current source only when a validated mapping exists; otherwise the historical location remains in the lens. Selection never rewinds or edits today's buffer. This avoids making a past candidate look like the current editable source.

A candidate is immutable as a reviewed version. Refining creates a new candidate with a link to its predecessor and the prompt that changed it. A diff compares a named candidate to its captured source basis, never to whichever file happens to be on disk when the viewer opens it. Review of a stale basis presents a compare/rebase path; saving cannot silently overwrite external edits. The timeline may be reconstructed from authoritative state after reload; its ordering and receipts must not depend on transient DOM state. The current prototype exposes `turns`, `versions`, and snapshots, not this event model. Persisted event identities and phase transitions are prerequisites, not present features.

## Revision and runtime language

| Word | Means | Does not mean |
| --- | --- | --- |
| Draft | In-memory buffer source differs from its saved basis | Saved to disk |
| Made | Candidate materialized from an intent | Valid or saved |
| Verified | Stated checks passed for this candidate and basis | Project tests ran, or arbitrary execution is safe |
| Saved | Source written with basis guards; for a generation, accepted history updated as specified | Running code replaced |
| Live | Proposal revision installed in the workspace runtime image | Global process deployed or source saved |
| Evaluated | A particular source form ran in the workspace session | Its buffer was saved or a proposal became Live |

Made, Saved, and Live are **independent revision pointers**. Save without Live and Live without Save remain first-class states. Form evaluation can mutate the runtime independently of these pointers. A separate “Session evaluated since Live” signal is needed if the interface claims what code is currently executing; never infer that the Live revision exactly describes all session mutations. A source form inside a function may depend on lexical locals that are not available in the REPL; show the runtime error rather than suggesting the editor captured those locals.

The console in this workspace and the standalone `bl repl` are separate sessions. Visual conventions can be shared; source bindings and result histories cannot be silently shared. Evaluation remains an explicit side-effecting action, never a hover side effect or a generation step.

## States and recovery

| Situation | Interface response | Invariant |
| --- | --- | --- |
| Buffer is dirty; user switches file or enters review | Preserve draft and return location; label it as a draft | No implicit disk write |
| Generation starts with a dirty buffer | Present supported scope honestly; either implement a frozen draft snapshot end-to-end or require saved source | No accidental generation against a stale disk revision |
| Verification fails | Keep prompt, draft, candidate and error location; offer refine or inspect | No Save/Live success claim |
| Network fails or run is cancelled | Keep prior version and show retry or cancellation receipt | Late reply cannot become current |
| Save encounters a changed basis | Keep source and show a conflict comparison | No silent overwrite |
| Version is Saved but not Live, or Live but not Saved | Show all three pointers and explicit next actions | Neither state is automatically “fixed” |
| Runtime reconnects or restarts | Reconcile authoritative snapshots, retain local drafts, mark uncertain receipts as such | Do not invent a Live state from a saved file |
| Eval response arrives after an edit | Attach result to its request and original source revision; label stale next to current source | No result reassigned to a different form |
| Browser tile is narrow | Collapse context into a drawer, allow code-local horizontal scroll | No whole-page horizontal overflow or hidden primary action |

Keyboard focus survives background state updates. Announcements distinguish connection, running, success and failure without stealing the caret. All actions are reachable by keyboard and have text labels; status is never color-only. The reference image palette is a direction, not a contrast guarantee; test both themes at normal text and code sizes. Reduced motion removes nonessential animations. A fallback text editor remains fully writable if structural parsing or CodeMirror is unavailable; form-specific actions then explain why they are unavailable.

## Implementation seams

The prototype's `play/ui.bl` owns commands and rendered fragments, `play/ui-client.js` owns CodeMirror and poll reconciliation, and `dev/workspace.bl` owns buffers, proposals and the runtime. The current editor uses CodeMirror **StreamLanguage** for highlighting; it does not have a browser syntax tree. `editors/tree-sitter-beamlisp/grammar.js` is a possible structural source, but parser coverage must be compared against the authoritative BL reader before shipping form actions. The reader reports **Unicode codepoint** offsets; CodeMirror uses UTF-16 offsets. Conversion and stale-revision validation are mandatory. Form parsing and request semantics are specified in [form-first interaction](form-first-interaction.md).

Integrate by replacing duplicated view state with one explicit `WorkspaceContext` (active buffer and draft revision, selected experience and candidate version, selected form, timeline position, inspector target, console binding). IDs, not labels or DOM order, own relationships. The console owns eval receipts keyed by request ID. The server validates source and ranges; the browser may preview structure but is not the authority for execution. Existing allowlisted commands remain explicit; a future `eval-form` command is a distinct path from `eval` typed in the console.

## Build in coherent slices

1. State and provenance: typed context, version/basis identity, timeline event contract and fixture tests. Do not make a timeline out of transient turns if it cannot survive reload.
2. Unified shell + buffer: one source-focused surface, persistent drafts, focus-safe polling, responsive inspector and conflict feedback.
3. Form-first navigation + eval: parser parity and offset mapping tests, keyboard/pointer selection, server-side validation, request-owned receipts and accessibility.
4. Generation + inline review: source scope contract, ordered events, candidate-version diff, review decisions and cancellation/conflict tests.
5. Polish: screenshots of Carbon/Snow, wide/narrow niri tiles, keyboard-only journey, screen-reader names, reduced motion and failure recovery.

Acceptance is a complete journey: create an unsaved draft; navigate to a form; evaluate it without saving; start a generation against an explicit basis; inspect a timeline version and its diff; verify; save without publishing; publish separately; switch away and back without losing form selection or history; reconnect and see the same authoritative state. Every action needs a corresponding test at the ownership boundary.

## Design references

- [CIDER keybindings](https://docs.cider.mx/cider/keybindings.html#evaluating-code) distinguishes sexp-at-point, defun-at-point, region and load-buffer. Our default is explicitly the highlighted form, not an inferred whole file.
- [CIDER code evaluation](https://docs.cider.mx/cider/usage/code_evaluation.html#overlays) uses local result overlays and load-state indicators; a durable receipt supplements a transient overlay.
- [Helix selections](https://docs.helix-editor.com/usage.html#selection-first-editing) and [syntax-aware motions](https://docs.helix-editor.com/syntax-aware-motions.html) inspire selection-before-action and structural traversal.
- [Primer saving](https://primer.style/product/ui-patterns/saving/) supports explicit persistence and recovery from errors.
- [Primer progressive disclosure](https://primer.style/product/ui-patterns/progressive-disclosure/) supports hiding raw details without disorienting the reader.
- [Fluent 2 layout](https://fluent2.microsoft.design/layout) informs spacing and responsive grouping; it does not dictate the editor's identity.
