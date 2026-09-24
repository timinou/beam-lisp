# A Stream is a working document

A Stream is a named exploration with its own durable `.bl.md` document. It may begin with no source file, then inspect, evaluate, and propose changes to several files. It can also end without changing any file. The document is simultaneously the operator's spec, the model's context, executable cells with results, comments, and the history of what happened. A source file's activity view projects the portions of Streams that touch it; the file does not own a second copy of that history.

Open a Stream from the project switcher or command palette; a file tree drawer remains available without occupying editor width. Its document takes the full-size editor. The selected heading, cell, or form fills the contextual sidebar. Source and diff panes open on demand beside it, each labeled with the file and revision it represents. A Stream does not become a file-scoped generation merely because the first attached source is selected. See [workspace editor](workspace-editor.md) for the shared shell and [form-first interaction](form-first-interaction.md) for syntax selection.

## Document shape

`.bl.md` is the initial format: [the harness](../../priv/lib/harness.bl) already writes prose, fenced `beam-lisp` cells and paired `bl-result` blocks, and [harness.doc](../../priv/lib/harness/doc.bl) delegates slicing to [bl.doc](../../priv/std/bl/doc.bl). A project can put a Stream at `streams/<slug>.bl.md`; a stable ID in its metadata, not the path or title, identifies it after a rename. The path is project-relative, sanitized and guarded against traversal/symlinks outside the root. The header and operator prose are editable; generated history retains the harness's sections and role semantics.

````markdown
# Stream · Invoice edge cases

<!-- stream:id=invoice-edge-cases-v1 -->

## Spec

Explore late fees and decide whether they belong in the invoice total.
No source changes until the computation and its tests agree.

## Sources

- src/app/invoices.bl — investigate `total` (current saved basis: 4)
- src/billing/rules.bl — possible new module

## Comments

### cmt-1 · operator · on Spec
Check what happens when the due date is missing.

## task

Compare the two representations; do not write source yet.

## model · t1 · 1

```beam-lisp id=c1
(+ 40 2)
```

```bl-result c1
42
```

## steer

Focus on the edge case in `src/app/invoices.bl`.
````

The example shows the format, not a shipped Stream renderer. `## task`, `## steer`, `## model`, `## eval`, numbered cells and `bl-result` are the harness's real append conventions. A result is produced by evaluation, never accepted from model-authored text. Stream-specific headings such as Spec, Sources, Comments and user comment IDs are a proposed extension; they must not masquerade as the harness-generated section headings. Unknown prose remains prose, so ordinary Markdown stays portable and a plain text editor can edit the document.

An `.bl.org` document can become an alternate dialect through `bl.doc`'s Org source/result spans. The current harness accepts `.bl` and `.bl.md` inputs and writes `.bl.md` sessions; it **does not** append Org sections or reconstruct chat roles from Org headings. Org parity requires a dialect adapter with the same cell/result ownership and single-writer guarantees. Do not label a `.bl.org` Stream fully supported until evaluation, comments, history and recovery pass the same tests. A conversion must preserve stable Stream/cell/comment IDs and source links.

## One document, one writer

The harness currently owns `.local/harness/<session>.bl.md`, appends whole titled sections through a keeper, and runs model turns in the project's warm VM. It does not permit editing an earlier Spec block or selecting an arbitrary Stream document path. The design extends that keeper, not a parallel browser transcript:

1. `open-stream` binds a stable Stream ID to one validated project document path, with a unique session namespace. Existing `.local/harness` sessions keep their current path and append behavior.
2. The keeper serializes **both** operator edits to editable sections and appends of comments/turns/cells/results. Spec edits use a basis digest and an atomic document replacement; an external edit or concurrent turn produces a conflict view, never a silent overwrite. Generated history is not rewritten by a spec edit.
3. Model steps read a complete document snapshot. A turn receives later operator comments through the existing `steer-turn` semantics; a comment not addressed to the model remains a comment, not an invisible steer. Status distinguishes queued, running, paused, failed, stopped and completed.
4. Each cell and generated block has a stable ID and its own result. The one writer prevents eval and model output interleaving by bytes. `bl.doc`'s result writer must not concurrently rewrite an active Stream document outside the keeper; route result updates through its owner or reject the operation.
5. A document reload reconstructs Stream ID, editable regions, comments, cells, results, turn boundaries, references and last state from the file. A derived search/index accelerates views but is disposable; it cannot be the only place holding history.

Stream edits are explicit **Save Stream** operations. A submitted comment or turn becomes durable when the keeper acknowledges its append. A draft Spec is visibly unsaved and survives switching views. Saving a Stream does not save, accept or publish a source-file proposal. Deleting or renaming a Stream is separate from deleting or renaming any source it references. The user can export/read the entire Stream as plain Markdown without running the app.

## Spec, comments, history: one reading flow

The Stream opens at its title and short editable Spec. A compact Sources section lists the file revisions currently being investigated. Below it, blocks follow in document order: operator notes, questions, model steps, evaluated cells with inline results, verification receipts and proposal candidates. The visual rhythm is that of an annotated notebook: subtle author labels, indentation and linking lines when replying to a specific block. No giant chat bubbles, fake token streaming, or a bare event log of verbs. Collapsible runs summarize long raw traces without hiding their existence.

A comment can reply to the Stream spec, a document heading/cell/turn, a candidate, or a source form. Each stores an anchor ID and, for source, file path + basis revision + form range/digest. If the source changes, show the comment against its captured revision and offer an explicit re-anchor; do not silently attach it to a new expression at the same line. Replies remain in reading order with a lightweight thread cue; the `.bl.md` document retains a stable, readable representation. A resolved thread stays in history and is searchable.

A source-pane action **Attach source** may open several files at once. Each pane names its path and current/historical revision. Selecting a reference in the document opens the relevant pane; selecting a candidate shows its diff there without replacing the Stream document. On narrow tiles, one source pane takes the foreground with a visible breadcrumb back to the Stream. Pane layout is ephemeral view state; paths, anchors and decisions are durable document state. The selected form's sidebar can show its symbol, type/proof if available, last evaluation, comments and related proposal hunks, always scoped to the pane it came from.

## Source Activity is a projection

The Source view has an optional **Activity** lens on its file. It shows manual saves (when instrumented), form evaluations, Stream references, candidate hunks, verification and publication that explicitly name the file. A file can appear in many Streams; activity groups by Stream with clear provenance. Opening an event switches to its owning Stream and exact block, or opens its captured file basis as a read-only history lens. Filtering by selected form never changes the underlying Stream document or source file. A file activity feed with no tracked events says so; it does not invent events from filesystem timestamps.

A Stream view includes its own spec, comments, cells, results and decisions even before any file is attached. It may link to a proposal involving multiple files; those file views project only the events relevant to each path. History is neither duplicated into every source file nor tied to whichever file happens to be active. A stable cross-reference records Stream ID, block/event ID, source path, basis and candidate version. Rename migration updates references transactionally or retains a resolvable alias until it can. This index is a **projection** over documents and authoritative source/proposal receipts; rebuilding it cannot alter decisions.

## Working example

1. Create **Stream · Invoice edge cases** without choosing a file. Draft a Spec and save it as `streams/invoice-edge-cases.bl.md`.
2. Ask a question in the Stream. The harness-like turn appends its task, model response and any evaluated cells/results. Comment on one result and steer the turn when appropriate.
3. Attach `invoices.bl` and `rules.bl`; open both as temporary source panes. Select a form in `invoices.bl`: its sidebar shows exact form, namespace, source revision, any proof/docs, related Stream comments and last eval. `Ctrl+Enter` evaluates it explicitly in the intended workspace image; the result appends to the Stream document if that Stream is the active context, and remains attributed to the original form/revision.
4. Start a generation with an explicit set of source bases. The Stream records the request, provider disclosure, completed response, checks and immutable candidate version as readable blocks. Its diff opens in a side pane. A follow-up appends another candidate; previous versions remain available.
5. Verify, save source and make live as separate decisions. Source Activity now points back to the relevant Stream blocks. A read-only history lens shows the old basis without touching an unsaved current file draft.

The current generator only accepts a source path. Multi-file/frozen-draft generation and Stream-owned receipts require backend contracts; the UI must not depict them as working until those contracts exist. A Stream's task can be purely analytical and end with no candidate. A model response is data to inspect, not permission to execute arbitrary code or publish source.

## Failure and acceptance

- A model turn and a Spec save racing are serialized by the keeper. A stale basis triggers a conflict, preserving both the draft and appended history.
- A crash between evaluation and append has an explicit uncertain/failed receipt or recoverable journal; it never claims a result that was not recorded. Cell IDs and section ordering survive restart.
- A comment on a deleted source form remains on its original captured revision and can be re-anchored explicitly. A file rename preserves or migrates references without orphaning the Stream.
- A provider cancellation leaves its earlier candidate and comments intact. A late result is recorded as ignored, not made current.
- Multiple source panes never change console binding merely by hover. A diff pane cannot evaluate proposed text against the current image without explicit Try semantics.
- Tests cover two simultaneous Stream turns in different sessions, one-turn-per-Stream, comment/steer races, Spec conflict, reload reconstruction, result provenance, path traversal, source rename, offline/no-provider and read-only fallback. Browser tests cover full-size Source/Stream editing, contextual sidebar, palette-only command discovery, source pane focus and a narrow niri tile.
