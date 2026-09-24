# The workspace editor

The workspace has two first-class perspectives: **Source** and **Stream**. Source opens a file's code at full size. Stream opens its literate `.bl.md` document at full size, with a spec, comments, executable cells and history. Either view has an Activity lens; Activity projects work that belongs to the current file or Stream, not a third place where work lives. A Stream may start without a file and later explore several. The editor stays the destination; supporting material opens around it only when requested.

This is a design contract for future implementation. The [illustrated proposal](../../research/workspace-spike/editor-design-proposals.html) shows existing screenshots alongside schematic future states. [Stream documents](stream-workspace.md) specifies persistence and harness integration. [Form-first interaction](form-first-interaction.md) specifies source selection and evaluation.

## The source-first frame

```
Current Source or Stream · short breadcrumb                       Actions / command palette
┌──────────────────────────────────────────────────┬─────────────────────────────┐
│ full-height, full-width-priority source editor   │ selected-form inspector     │
│ (code or literate Stream document)                 │ info · docs · results       │
│                                                  │ comments · related work     │
└──────────────────────────────────────────────────┴─────────────────────────────┘
Optional: Activity lens for this Source or Stream · source/diff panes on demand
```

No permanent three-column dashboard, always-visible timeline, shortcut legend, duplicate open-buffer list, or fake OS title bar. The source takes remaining viewport height and most horizontal space. The contextual sidebar follows the selected form in a file, or the selected heading/cell/comment in a Stream. It shows exact syntax kind and range, namespace and binding, signature/docs/proof where available, last evaluation and its source revision, comments, and proposal hunks referring to that form. A hover may preview these facts; a selected form remains pinned until an intentional pointer move or keyboard selection changes it. An asynchronous lookup keyed to an old selection cannot overwrite the new sidebar. Empty/error states say what is known rather than inventing analysis.

The command palette is the one searchable action catalogue. It offers context-aware actions by name: **Go to first child**, **Go to parent**, **Go to previous form**, **Go to next form**, **Evaluate selected form**, **Save file**, **New Stream**, **Attach source**, **Open Activity**, **Open diff**, **Show API form**, and **Switch perspective**. Search by action or shortcut. Existing `Ctrl+J/K/H/L` and `Ctrl+Enter` bindings retain their form-first semantics; the editor surface does **not** print a four-direction shortcut map. A small mode cue may say Edit or Explore; a first-use hint may point to “Search actions” without displaying chords. Browser-reserved keys get a web-safe mapping and the same palette actions. The palette keeps focus and selection stable on close. The precise motion rules live in [form-first interaction](form-first-interaction.md).

### Source and Stream

A Source view owns a disk basis, an in-memory draft, editor selection and file-scoped activity. A source revision/digest travels with selected forms, evaluations, comments and proposal hunks. Save file writes with a basis guard. Switching to a Stream does not save the file or lose its draft. A source file may be referenced by many Streams; no arbitrary “current Stream” is inferred from the file.

A Stream owns a durable project document, spec draft, comments, cells/results, turn history and links to zero or more source files. Its stable ID survives a title or path rename. The project may choose `streams/<slug>.bl.md`; harness integration extends its one-writer session mechanism to adopt that path rather than duplicating history in `.local/harness`. The first dialect is `.bl.md`, because the harness currently writes it. `.bl.org` requires an explicit adapter for Org headings and result blocks before offering identical behavior. See [Stream documents](stream-workspace.md).

The project switcher in the header/palette lists recent source files and Streams and can open a file tree drawer. This is navigation, not a sidebar occupying source width. A user may keep two source panes open while reading a Stream; each pane names its path, revision and read-only/current state. Opening a reference from a Stream uses a side pane without replacing the Stream document. On a narrow niri tile, the pane becomes a foreground sheet with an unambiguous breadcrumb back. Pane layout and scroll position are view state; source links and decisions remain in the document.

## Activity is a lens, not a bare timeline

A Source file's Activity lens projects only receipts and Stream references that explicitly cite that file, optionally narrowed to the selected form. A Stream's Activity lens reads its own literate document in order: editable Spec, source references, operator comments and questions, model turns, evaluated cells with inline results, checks, candidates and decisions. It should feel like a specification annotated through time—subtle reply indents and author labels, compact history markers and collapsible long runs—not a chat app or a list of timestamped verbs. The default Stream reading view retains the whole document; Activity can focus on its history without hiding the Spec.

An activity item carries a stable owner (Stream ID or direct file operation), block/event ID, source path and basis when applicable, and candidate version when applicable. The Stream document and authoritative source/proposal receipts own those facts; the file view is a rebuildable index/projection. A file mentioned by two Streams shows two attributed threads. A Stream with no files still has its spec and comments. File saves performed outside a Stream appear only if instrumented; no activity is invented from a modification timestamp.

Selecting an older event opens a labeled read-only **history lens** for its frozen source and diff. “Return to current draft” returns without changing a byte. A hunk locates a form in today's source only when its mapping is validated; otherwise it opens the historical basis. A comment on a moved/deleted form stays anchored to its old revision until explicitly re-anchored. The Activity view must not silently rewind the editor or change the active REPL binding.

### From exploration to changes

1. Open Source to write code, or create a Stream to state an intent without choosing a file. The source editor occupies the surface. The sidebar explains the selected form/document block.
2. In a Stream, attach source files as needed; explore them in optional panes. Comments may target the spec, a turn/cell, a candidate or a file/form at a captured revision. Source Activity links back to the owning Stream block.
3. Ask for a change with explicit scope: which source files/bases and which provider. The current prototype generator accepts one path. Multi-file/frozen-draft scope needs a backend contract; until available, label the supported scope **Saved source only** and never silently use stale disk in place of a visible draft.
4. The Stream document appends task, model, cell and real result blocks through the harness keeper. A generation adds a completed provider response, verification receipt and immutable candidate version as evidence, never a fake token stream. Follow-up adds a new candidate without replacing the previous one.
5. Open the candidate diff in a side pane or focused review. It names its frozen basis and offers source references. Verify, Try, Save source and Make Live are distinct actions with distinct receipts. An inverse proposal is a new candidate requiring guards and verification.
6. Evaluate a highlighted source form explicitly. The inline receipt and Stream or Source Activity history point to that form, draft revision and runtime image. Hover does not execute. Session eval can mutate the runtime without saving source or advancing a proposal's Live pointer.

A user can close a Stream after discovering that no source change is needed; the spec, comments, tests and conclusions still form useful work. A Stream can also touch multiple files over multiple turns. Neither requires a fake “primary file.”

## Revision vocabulary

| Term | Meaning |
| --- | --- |
| Draft | In-memory file or Stream spec differs from its saved basis |
| Made | A candidate exists for an explicit set of captured source bases |
| Verified | Named checks passed for that candidate; namespace load does not imply project tests |
| Saved | A basis-guarded source/Stream write was acknowledged; a generated acceptance may also move its accepted-history pointer |
| Live | A proposal revision was installed in the workspace runtime image, not deployed globally |
| Evaluated | A source form or Stream cell ran in a named workspace/harness session; the result has its own receipt |

Made, Saved and Live remain independent pointers. Save without Live and Live without Save are legitimate. A form evaluation may modify the runtime image independently of a proposal's Live pointer, so an exact “running code equals Live revision” claim needs a separate session-mutation signal. An expression inside a function may refer to lexical locals unavailable to session eval; show that error and an explicit enclosing-form alternative. The standalone `bl repl`, the playground workspace image and a Stream harness namespace are distinct execution contexts: the UI must label which one an action targets. Do not silently treat all three as one REPL.

## Ownership and integration seams

The prototype's `play/ui.bl` renders commands and fragments; `play/ui-client.js` owns CodeMirror and polling; `dev/workspace.bl` owns buffers, proposals and the workspace image. `harness.bl` on main adds a project-VM session with a keeper, turn worker and `.local/harness/<session>.bl.md` append-only document. `harness.doc` slices `.bl.md` through `bl.doc`; `harness.model/messages` reconstructs operator/model/result roles from generated sections. The current harness does not accept arbitrary Stream paths, update an earlier Spec, or write `.bl.org`. [Stream documents](stream-workspace.md) defines the required single-writer extension. It must coexist with ordinary harness sessions rather than creating a second transcript implementation.

One typed view context tracks `Source | Stream`, active document ID/revision, selected form/block, inspector request, Activity filter/history lens, open source panes, candidate and console binding. IDs and bases—not labels, line numbers alone, or DOM order—connect events. Background updates preserve focus and local drafts; a stale async response stays with its original request. The browser syntax highlighter is not a parser. Client structural selection needs parity with the BL reader; CodeMirror UTF-16 offsets and reader Unicode codepoint offsets require tested conversion. The server validates exact source/revision before eval. See [form-first interaction](form-first-interaction.md).

## Recovery and acceptance

| Condition | Visible behavior | Invariant |
| --- | --- | --- |
| Dirty Source or Stream Spec; change perspective | Retain draft, selection and return location | No implicit disk write |
| Keeper appends while operator edits Spec | Serialize both operations; stale basis opens a conflict | Generated history is never overwritten |
| Attached source changes externally | Historical anchor remains readable, compare/re-anchor offered | No silent relocation or write |
| Model turn fails, stops or times out | Keep blocks and explicit outcome; retry remains available | No forged result or hanging “running” state |
| Generation cancelled after response begins | Preserve prior versions and cancellation receipt | Late response cannot become current |
| Proposal Verified, Saved or Live | Show each pointer and checks by name | No conflated “applied” state |
| Form eval returns after editor change | Show receipt on original revision and mark stale | No result attached to another form |
| Source Activity has no indexed work | Explain that no tracked events exist | No inferred history from timestamps |
| Narrow tile / screen reader / parser unavailable | Main editor remains readable and writable; pane/palette actions reachable | No keyboard-only invisible capability or whole-page overflow |

Implement in coherent slices: (1) Source/Stream identity and single-writer document contract; (2) source-first shell, drafts, contextual inspector and command palette; (3) form parser/eval and request-owned receipts; (4) Stream spec/comments/history and Source Activity projection; (5) multi-source generation/review and recovery. Test one journey spanning an empty Stream, a two-file exploration, a comment on a form, a turn with a real result, a candidate with a read-only historical basis, separate Save/Live decisions and a restart. Verify native reserved-key delivery and browser fallback before claiming the shortcuts work everywhere.

## References

- [Harness implementation](../../priv/lib/harness.bl), [document blocks](../../priv/lib/harness/doc.bl) and [editor/agent guide](../bl/04-editors-and-agents.md#the-harness--a-live-session-an-agent-drives) ground the Stream format and writer contract.
- [bl.doc](../../priv/std/bl/doc.bl) defines `.bl.md` and `.bl.org` cell/result spans.
- [CIDER evaluation](https://docs.cider.mx/cider/keybindings.html#evaluating-code) distinguishes selected sexp, top-level form, region and buffer.
- [Primer saving](https://primer.style/product/ui-patterns/saving/) informs explicit persistence and recovery; [Fluent 2 layout](https://fluent2.microsoft.design/layout) informs responsive grouping.
