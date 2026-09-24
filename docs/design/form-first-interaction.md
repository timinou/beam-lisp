# Form-first interaction

A form is the unit of attention. The source editor highlights a readable form under the pointer or selected by keyboard, then evaluates **that exact form** on explicit request. Hovering never evaluates. Source selection is visible before action, following the selection-first model; evaluation is CIDER-inspired but bound to the workspace's own runtime, not nREPL. See [the source-first workspace](workspace-editor.md) for full-size source, contextual inspector and a Source/Stream Activity view.

This is a product contract and implementation guide, not a claim that the current prototype supports structural editing. The prototype uses CodeMirror's Clojure stream highlighter, with no client syntax tree or `eval-form` command. The BL tree-sitter grammar exists separately; the runtime reader is authoritative for executed source.

## Beginner journey

- Open a file and type normally. The mode badge reads **Edit · type freely**. A first-use hint points to the command palette's “Explore forms” action without listing keys. No movement key is stolen from a text field.
- Point at `(+ 1 2)`: an outline hugs the entire form and its exact source, kind and position appear in the selected-form sidebar. The sidebar offers **Evaluate form** and **Explore children** as named actions. Pointer motion inside source updates this preview, without a click or runtime call. Leaving source retains the last selected form without pretending the pointer still hovers it.
- Click the form or press `Esc` while the editor has focus to enter **Explore · form selected**. `i` returns to Edit at the form's start; `Enter` may also enter Edit only after a visible prompt describes that choice. `Esc` from Explore clears transient menus but does not erase the selected form; a second Esc may clear the selection. Ordinary typing in Explore does not change source. A small mode cue identifies Explore; the command palette names every movement and its active shortcut. The editor does not display a permanent key map.
- `Ctrl+Enter` evaluates the visibly selected complete form from either editor mode. There is no selection → no implicit eval. The result appears near the form and in the selected-form sidebar; its durable receipt in the owning Stream or Source Activity includes source path, revision, namespace and request ID. Clicking **Evaluate form** is equivalent. Explicit “Evaluate top-level form” and “Load file” are separate named commands; they must not be hidden fallback behavior.
- `Ctrl+J/K/H/L` traverse form structure in Explore. Searchable command-palette actions expose the same moves by name, with their active bindings and a web-safe fallback. The four shortcuts never act while focus is in a prompt, dialog, console input, or browser content outside the editor.

### Selection model

The document is a forest of complete top-level forms. A form has a kind, a half-open source interval `[from,to)`, a parent, ordered children, and a document revision. Forms include atoms, strings, lists, vectors, maps, sets and complete reader-prefix forms (`'x`, `@x`, `#(...)`, metadata and reader conditionals); delimiters belong to their containing form. A prefix is one selectable whole form with a child when the parser can express it. Children are syntactic forms in source order. Punctuation, gaps, comments and discarded `#_` forms are not executable selections. A map's children are its alternating key and value forms unless a later parser deliberately exposes entries as stable grouped nodes. A string is an atomic form; hovering characters inside it selects the whole quoted string. Comments may get an inspection tooltip but not an Eval target.

**Pointer:** map editor coordinates to a document offset, then choose the smallest complete executable form containing the pointed codepoint. On a delimiter, select the collection or prefix owning it. On whitespace/comment, do not guess a nearby expression or replace a keyboard selection. A new intentional pointer movement over code changes the active highlight; mere scroll, layout shift, or a stationary pointer after keyboard navigation does not steal it. Click pins the current form for keyboard movement. Keyboard focus remains on the editor; the decoration is not browser text selection. A soft hover outline and a strong active outline distinguish preview from selected, and both have text alternatives in the form cue.

**Edit:** preserve a selection across text changes only when its exact form remains parseable and can be mapped to the new revision. If not, clear it with “Form changed; choose a form” rather than evaluating stale text. An inline result stays associated with its original revision and becomes “from an earlier draft” after an edit. Moving a selection does not change a draft or runtime.

### Structural motion contract

The user's keys define motions; they are **not** line directions. “Sibling” means a node with the same parent. The invisible document root groups top-level forms and is never selectable. Search for ancestor siblings only where a rule explicitly says to do so. No wraparound at file boundaries.

| Key | Preferred move | Boundary fallback | If none |
| --- | --- | --- | --- |
| `Ctrl+J` | Select first child | Select next sibling of the current form | Stay and say “No child or next sibling” |
| `Ctrl+K` | Select parent form | If at top level, select next top-level sibling | Stay and say “Already at last top-level form” |
| `Ctrl+H` | Select previous sibling | Climb to the nearest ancestor with a previous sibling (“previous parent”), then select that sibling's **last child**; repeat last-child descent to the deepest executable descendant | Stay and say “First form” |
| `Ctrl+L` | Select next sibling | Climb to the nearest ancestor with a next sibling (“next parent”), then select that sibling's **first child**; repeat first-child descent to the deepest executable descendant | Stay and say “Last form” |
| `Ctrl+Enter` | Evaluate exactly the highlighted form | None; disabled for invalid/no selection | Explain why without calling runtime |

The `H/L` descendant rule makes crossing a parent boundary useful rather than landing on a giant neighboring form. A sibling found at the **current** level is selected as a whole; descend only after an ancestor fallback. `J/K` are not exact inverses at boundaries by design. A movement that cannot advance leaves the selection in place and gives a brief, screen-reader-announced cue, never wraps to a surprise form. Repeating a key yields predictable movement, not a different kind of action. This interpretation of “last child of previous parent” and “first child of next parent” is the proposed normative contract and should be validated with users before implementation.

```
A = (def x 1)               B = (map inc [1 2])             C = (println x)
    def ─ x ─ 1                 map ─ inc ─ [1 2]               println ─ x
                                              1 ─ 2

B --J--> map --J--> inc --H--> map --K--> B
[1 2] --J--> 1 --L--> 2
2 --L--> println  (climb from vector to B; next top-level C; first child)
map --H--> 1       (climb from B to previous top-level A; last child)
B --K--> C         (no selectable parent; next top-level sibling)
```

A motion target is a form, not a token guessed from nearby whitespace. `Esc` and `i` are scoped to the focused source editor in Explore; ordinary browser shortcuts, input methods and screen-reader keys remain untouched. The command palette exposes all motions by name and active binding; accessible palette actions work with keyboard, mouse or touch. The source surface shows no shortcut legend. Key hints are platform-specific, not a universal `⌘` glyph.

### Key reservation and browser reach

`Ctrl+H` (history), `Ctrl+J` (downloads), `Ctrl+K` (search), and `Ctrl+L` (address bar) are browser-reserved in common browsers. A web page cannot promise to capture them before browser chrome. The native WebKitGTK window without browser chrome is the intended home for these keys, **after real platform tests**; do not assume every WebView backend delivers them. The browser edition exposes a safe `g` then `h/j/k/l` chord in Explore mode, the same named actions in the command palette, and remappable keys. The palette shows the active binding for that host. `Ctrl+Enter` is available where delivered. No accessibility or essential feature depends solely on capturing a reserved chord. A user shortcut preference can choose an alternative without changing the traversal semantics.

### Parsing, offsets and stale source

Client structure is a preview of the **current CodeMirror document**. The shipped bundle exports StreamLanguage and syntax coloring, not a syntax tree. A future client parser must cover BL forms and error recovery, and match the runtime reader's interpretation of prefixes, comments/discards, metadata, strings, Unicode and reader conditionals. The existing tree-sitter grammar is a candidate, not an authority by name. Generate parity fixtures against `BeamLisp.Reader/read` with diagnostics collected. A parse error elsewhere in a file need not prevent a clearly bounded complete form from being selected, but an error intersecting the target does. If a boundary is uncertain, no Eval action appears; there is no “evaluate nearest line” fallback.

CodeMirror offsets count UTF-16 code units. The BL reader's `:offset` and `:end-offset` count Unicode codepoints. On a draft containing `😀` before a form, raw offsets differ. Convert using a tested offset map or agree on a single encoding at the boundary. Ranges are half-open; delimiters and reader prefixes must be included exactly once. Test CRLF, astral characters, combining marks, tabs, nested forms, empty collections, unterminated strings and edits between pointer move and keypress.

`eval-form` sends a buffer/working-context ID, document revision or content digest, exact selected range, and draft source (or a server-acknowledged snapshot ID). The server validates that the range slices the submitted draft to the highlighted text, parses that text with the authoritative reader, checks that it is one complete form, and evaluates in the intended workspace image/namespace through the explicit allowlisted command. It rejects a stale, mismatched or empty target; it does not silently fall back to evaluating the whole buffer, a neighboring form or the latest saved file. The unsaved draft may be sent for verification without being written to disk. The current `eval` command accepts free-form console text; it is not sufficient proof that the selected range belongs to a buffer.

Evaluation is **real code execution** in the workspace session. It may read files, mutate values or define vars. A first-use explanation and a runtime/namespace indicator in the selected-form sidebar are appropriate; never evaluate on hover. An expression inside a lexical `let` or function may refer to locals unavailable to session evaluation; show that error and offer named alternatives (evaluate enclosing top-level form or inspect source) rather than claiming local context was captured. Evaluating a selected `ns` form can change the current namespace; display the new namespace. A form in a proposal diff is not executable against a candidate unless a separate explicit Try mode with a verified candidate environment exists. In Source or an attached source pane, Eval targets the selected draft form in the named workspace image. In a Stream's fenced `beam-lisp` cell, Run cell uses the Stream harness namespace and appends its authoritative `bl-result` to that document; evaluating a subform there needs its own explicitly named harness action and exact cell revision. The sidebar states which runtime receives each action.

Each eval gets a request ID, source path, document revision, form range/text, workspace image identity, namespace before/after and result/error. At most one inline receipt occupies a form; prior receipts remain in the owning Stream document or Source Activity. The selected-form sidebar shows the latest receipt with its revision. An async result arriving after source edit or a switched file stays attached to its original revision, marked stale, and never rebinds to the currently highlighted form. Cancellation/interrupt needs an actual backend guarantee before showing a Stop action. Preserve errors and output as text (escaped), never HTML from evaluated source.

### Evidence and tests

Prove behavior with a **motion table** on nested lists/vectors/maps and multiple top-level forms. Every edge in the table above gets forward and boundary assertions; no movement wraps. Use pointer hit tests for delimiter, atom, quoted string, whitespace, comment and `#_` discard. Include accessibility tests for keyboard-only navigation, focus, announcements and both visual states; no forced modal mode in the fallback textarea. Test source changes mid-navigation, surrogate pairs before and within forms, stale eval replies, multiple simultaneous receipts, namespace changes, missing lexical locals, errors, a browser-reserved chord and native shortcut delivery. Browser fake-parser tests are not enough: compare selected source slices to authoritative reader spans and run one end-to-end real workspace evaluation from an unsaved draft without a disk write.

### Why these references

- [CIDER's source-buffer keybindings](https://docs.cider.mx/cider/keybindings.html#evaluating-code) distinguishes sexp-at-point from defun-at-point, selection and load-buffer. This design makes the selected form explicit rather than guessing which of those a key meant.
- [CIDER result overlays](https://docs.cider.mx/cider/usage/code_evaluation.html#overlays) explain a useful near-source receipt; the owning Stream or Source Activity keeps the durable counterpart.
- [Helix selection-first editing](https://docs.helix-editor.com/usage.html#selection-first-editing) motivates visible selection before action, while [syntax-aware motions](https://docs.helix-editor.com/syntax-aware-motions.html#moving-the-selection-with-syntax-aware-motions) motivate tree navigation. Our keys and fallbacks follow the user's contract, not Helix's keymap.
- [WAI-ARIA keyboard interface](https://www.w3.org/WAI/ARIA/apg/practices/keyboard-interface/) informs focus and mode discoverability; this code editor is not an ARIA `treeview` just because its data are tree-shaped.
