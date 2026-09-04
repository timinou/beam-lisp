# The livebook, maximalist — one document, three renderings

**Thesis under test:** the literate file the README promises — `.bl.md`, and
for the nerdier among us `.bl.org` — should not be a *feature*. It should be
the normal shape of a beam-lisp program, and the notebook, the docs site, and
the CI run should be three renderings of that one document. This doc names the
format, the five decisions everything hangs on, the affordances the runtime
already has, the ones it is missing, and the wave order that closes them. It
is written against the real code; every "already exists" is a file you can open.

---

## 0. The one idea

A livebook is a **namespace wearing prose**.

The file is plain markdown or org — your editor, git, Obsidian, and emacs all
treat it as a first-class citizen, because it is one. Inside it, fenced code
cells are the top-level forms of one namespace. The narrative around them is
not documentation *of* the code; it is the other half of the same artifact.

And because beam-lisp already decided that a web page is data (hiccup), that
state is a log (datom), and that an edit is a transaction (reload), the
maximalist version collapses to one sentence:

> **Store the document as text, project it as hiccup, and run it as facts.**

| rendering | verb | what it is | already proven by |
|---|---|---|---|
| **serve** | `bl live doc.bl.md` | a notebook app: every cell run, output, and edit is a fact; N viewers converge through the log | `examples/live/05-two-tabs.bl`, the Pulse loop in `docs/live-architecture.md` |
| **build** | `bl doc build docs/` | a static docs site: the same hiccup, frozen to HTML | `docs/tutorial-full-stack-ssg.md`, `live.hiccup/hiccup->html` |
| **run** | `bl doc run doc.bl.md` | CI: every cell evaluates in order under isolation, results are re-written into the file, deftest cells run | `priv/std/bl/cli.bl`, `reload.ward`, `priv/std/test.bl` |

No fourth artifact. When the narrative, the code, and the outputs live in one
file that is itself a namespace, "docs drift" stops being a category of bug.

So: is the maximalist version "hiccup interspersed with beam-lisp"? **No — and
the refusal is the design.** Hiccup-in-the-file would make the document a
render target (Diff hostile, Obsidian hostile, editor hostile). Hiccup is the
*projection*; the file stays text. The pipeline is one direction:

```
text file ──slice──▶ doc graph (facts) ──project──▶ hiccup ──▶ { live DOM · static HTML · result spans }
              ▲                                                            │
              └────────────── the only writer: owned result spans ────────┘
```

---

## 1. The format: both dialects, day one

Both formats are first-class from the first wave. They are two skins over one
slicer. Neither requires a new editor.

### 1.1 `.bl.md`

````markdown
# Payroll, explained

Prose is byte-sacrosanct. The tool never touches it.

```beam-lisp id=gross
(defn gross [rate hours]
  (* rate hours))
```

And now we call it:

```beam-lisp id=sanity frozen
(gross 50 160)
```

```bl-result sanity
8000
```
````

- The fence info string carries the grammar: `beam-lisp id=NAME [frozen] [silent]`.
  Unknown tokens are preserved verbatim, forever — the format can grow without
  a migration.
- A cell's result lives in the **owned span**: a ` ```bl-result <id> ` fence
  placed adjacent to its cell. This span is the only region the tool may
  write. Obsidian and GitHub render it as an ordinary code block.
- A cell with no `id=` gets one derived from content (hash of heading-path +
  first def name), minted **once**, then stable across edits.

### 1.2 `.bl.org`

```org
* Payroll, explained
#+begin_src beam-lisp :id gross
(defn gross [rate hours]
  (* rate hours))
#+end_src

And now we call it:

#+begin_src beam-lisp :id sanity :frozen
(gross 50 160)
#+end_src

#+RESULTS: sanity
: 8000
```

- `#+begin_src` / `#+RESULTS[name]` are exactly org-babel's shapes, so emacs
  users keep `C-c C-c` muscle memory for free, and orgzly/mobile org apps
  render the file natively. `:PROPERTIES:` drawers carry future metadata.
- Scope honesty: this is the **babel subset** (src blocks, results, properties,
  headlines), not an org parser. Full org is somebody else's lifetime.

### 1.3 What "first-class" obligates us to

1. **The round-trip covenant.** The tool owns exactly one span kind. Everything
   else — prose, whitespace, unknown attributes, BOMs, CRLF quirks — is
   preserved byte-for-byte. The contract is a fixed point:
   `render(slice(file)) == file` whenever results are unchanged, and `run`
   edits only its spans. This is what keeps `git diff` meaningful and editors
   safe. Every other notebook-format decision is downstream of this one.
2. **The document is a namespace.** The first cell carries `(ns my.book ...)`.
   `find_file` learns to resolve `my.book` to `my.book.bl`, `my.book.bl.md`, or
   `my.book.bl.org`. Code elsewhere can `:require` a document. A document can
   be AOT-compiled into a real `.beam`. Literate files are not beside the
   program; they *are* the program.
3. **Document order is run order.** Like Clerk: cells evaluate top to bottom.
   A cell that references a name defined later is incoherent — and reload's
   static coherence gate already knows how to hold it and say why.

The slicer is the one function both dialects compile to:

```clojure
(slice-doc path) ;; → {:format :md|:org
                 ;;    :ns "my.book"
                 ;;    :spans [{:kind :prose|:cell|:result, :id …, :owned? …,
                 ;;             :text …, :start-line …}]
                 ;;    :pos-map {ns-line → file-line}}  ;; errors point home
```

`pos-map` is the unsung hero: runtime errors and coherence failures carry
namespace line numbers; the livebook must translate them back to *document*
positions, or the narrative and the errors drift apart — the exact disease
this format exists to cure.

---

## 2. Prior art — what each system got right, and the wall it hit

Nine systems shaped this. The last column is the point: beam-lisp already
ships the piece each one lacked, so the mapping is mostly naming.

| system | what it got right | the wall it hit | what beam-lisp already owns |
|---|---|---|---|
| **org-babel** | results live *in the file* (`#+RESULTS:`); the file is the round-trip unit; `:exports both` | buffer state diverges from running state; no live anything | owned spans (same trick), plus the log |
| **Jupyter** | mandatory cell IDs (nbformat 4.5); per-cell outputs; kernel protocol | JSON: hostile diffs; prose second-class | text formats; IDs; **no kernel protocol needed — the image is the kernel** |
| **Livebook** | `.livemd` is markdown with metadata in HTML comments; Kino rich outputs bound to variables; smart cells | its own app is the only real editor; formats follow the app | the file stays text-first; results render anywhere via hiccup |
| **Clerk** | the notebook *is* a program; static build; content-hash cache; viewers = data → hiccup presentation | static: re-open means re-evaluate; no live diffing | hiccup→html (same move), **plus** the live diff loop already built |
| **Pluto** | reactive: static analysis of cell deps, minimal re-eval, exports static HTML | reactivity surprises; Julia-centric graph analysis | `codebase.bl` call-graph facts + `impact` are the same analysis, already queryable |
| **Wolfram notebooks** | the notebook is a pure expression; outputs are values in the file; Dynamic cells | proprietary box language; the file *is* the app | the doc graph is facts in datom — queryable by the language itself |
| **Smalltalk playground** | the livebook is a *view of the image*, not a separate runtime | image and file diverge; text tools lost | reload bundles keep image and file converged; the file stays portable |
| **Gorilla REPL** | hiccup-ish rich output saved back into the source file | died with its REPL | the live layer is maintained, tested headless and in Chromium |
| **knitr/Quarto** | chunk options; `freeze`/cache; publication-grade output | sidecar state; R/Python churn | `frozen` cells; results as facts; hiccup→html output |

Three extractions:

1. **Every surviving format is text.** JSON notebook formats lost the diff war
   everywhere they were optional. `.livemd`, Clerk's `.md`, org-babel — text.
2. **Every surviving system eventually wants the *live* half.** Clerk is
   static and users ask for re-eval; Pluto exports static HTML; Livebook grew
   from REPL to app. Beam-lisp is the only stack here where the live half is
   the *pre-existing* substrate rather than the aspiration.
3. **Reactivity is a dependency-graph problem, and graphs are databases.**
   Pluto rebuilt its graph per-edit inside the runtime. `codebase.bl` already
   transacts source into `:fn/…` and `:call/…` facts — "which cells must
   re-run" is a datalog query, not new machinery.

---

## 3. The five linchpins

Five decisions carry the whole design. Everything else is derivatives.

### L1 — The document is a namespace (the unit of coherence)

A cell is too small to be a unit of truth; reload settled this years ago
("`reload.bl`: the unit is the NAMESPACE"). So the doc's cells are *views over
one namespace*: editing a cell recomposes the ns source (concat of cell bodies
in document order) and stages that. Coherence, atomicity, held bundles — all
reload machinery, untouched. The slicer's `pos-map` makes every held-bundle
reason point at the right paragraph.

### L2 — Owned spans only (the round-trip covenant)

The tool is a guest in your file. It may write ` ```bl-result <id> ` fences
and `#+RESULTS:` blocks, and nothing else — not formatting, not IDs you didn't
mint, not prose. Fixed-point tests in wave 1 enforce this mechanically:
parse→render is the identity on any file whose results didn't change.

### L3 — Static coherence = the notebook never lies

Jupyter's shame is the stale kernel: the outputs on screen were computed from
code that no longer exists. Beam-lisp cannot have that bug by construction —
a bundle that doesn't cohere is *held*, old code keeps serving, and the
reasons print next to the cell. An amber cell with an explanation beats a
red herring.

### L4 — Results are facts

Every run transacts into the session conn:

```clojure
{:run/id "…", :run/cell "sanity", :run/status :ok
 :run/value "8000", :run/stdout "", :run/ms 3
 :run/basis 42, :run/at #inst "…"}
```

The file's result span is a *projection* of the last committed fact — not a
second source of truth. From this one decision, three features fall out for
free: **time travel** (view the doc as-of any basis — `09-undo-redo.bl` is
this pattern), **collaboration** (two tabs, one log — `05-two-tabs.bl`), and
**history with receipts** (every output ever, with the code that made it).

### L5 — Deterministic serialization (diffs are the UI)

Results are printed through `print_str` → Elixir `inspect`, which sorts map
keys; vectors are ordered; the runner bounds and truncates huge outputs by
policy. Therefore: same code → same bytes → result spans only change when the
world changed. The moment serialization jitters, the format stops being
git-native, so this is a requirement, not a nicety.

---

## 4. What already exists (build on these, don't rebuild)

| affordance | file | role in the livebook |
|---|---|---|
| string eval, last value out | `BeamLisp.eval/1` (`lib/beam_lisp.ex`) | cell evaluation |
| hiccup → HTML | `priv/lib/live/hiccup.bl` | the projection layer, everywhere |
| keyed tree diff + ops | `priv/lib/live/diff.bl`, `client.js` | live re-render of notebook views |
| socket loop (`defview`/`deflive`) | `priv/lib/live/socket.bl` | the notebook app's loop |
| datom log: `q`/`as-of`/`watch`/history | `priv/lib/datom/` | results, sessions, time travel |
| stage → static coherence → atomic commit | `priv/std/reload.bl` | cell edits as transactions (L1, L3) |
| file watcher w/ `auto_commit` | `lib/beam_lisp/reload_watcher.ex`, `bl watch` | save = stage (needs the W3 extension) |
| AOT per-file → `.beam` + `__bl_init__` | `BeamLisp.AOT` | docs compile to real libraries |
| source → call-graph facts, `impact` | `priv/std/codebase.bl` | reactive re-run scope (Pluto's half) |
| clojure.test port, ETS registry | `priv/std/test.bl` | deftest cells run in CI |
| isolated coherent forks | `reload.ward` | `bl doc run` isolation |
| env-conveying spawn | `priv/lib/system/core.bl` | cell processes inherit session world |
| capability capture / sandbox tiers | `priv/std/env.bl`, `docs/trust-boundary.md` | untrusted docs, capped cells |
| design tokens + components | `priv/lib/loom/` | the notebook chrome, themed |
| live catalog over code facts | `tooling/catalog.bl`, `docs/explorer.md` | the precedent: docs as queries |

## 5. What is missing (the honest gap list)

| # | gap | evidence | closed in |
|---|---|---|---|
| G1 | no doc format: no slicer, no cell IDs, no result spans | 0 hits for "markdown" under `priv/` | W1 |
| G2 | loader resolves only `<ns>.bl` | `loader.ex:283` — literal `<> ".bl"` | W3 |
| G3 | watcher filters `.bl` only | `reload_watcher.ex:111` | W3 |
| G4 | no print capture (no `with-out-str`) | `env/capture` is env-conveyance, not IO | W2 |
| G5 | cell edits must recompose ns source before staging | reload stages whole-ns strings (by design) | W3 |
| G6 | no result-viewer registry (hiccup passthrough first, registry later) | — | W5 |
| G7 | no `bl live` / `bl doc` commands | `priv/std/bl/cli.bl` command map | W2, W5 |
| G8 | no md→hiccup / org-subset→hiccup prose renderer | — | W4 (build) |
| G9 | output truncation policy for huge results | `print_str` is unbounded | W2 |
| G10 | re-run-on-edit wiring (the `impact` query exists; the behavior doesn't) | `codebase.bl` | W6 |

---

## 6. The waves (each shippable alone, in order)

**W1 — the format and the covenant.** `priv/std/bl/doc.bl`: `slice-doc`,
`render-doc`, both dialects; ID minting; the fixed-point property as tests
(`parse∘render = id`; `run` touches only owned spans). Zero runtime
integration — this wave cannot break anything, which is why it goes first.
*Acceptance: round-trip fixture corpus (real docs from `docs/`, org, md,
CRLF, Obsidian-mangled) is byte-stable.*

**W2 — `bl doc run` (the README promise, kept).** Slice → recompose ns →
eval under ward with a kill timer → capture value + stdout (spawned,
env-conveying process, swapped group leader) → transact result facts → write
owned spans → exit 1 on failure. deftest cells register and run. *Acceptance:
`bl doc run docs/tutorial-full-stack-ssg.md` green in CI; a second run
produces an empty `git diff`.*

**W3 — the document joins the ecosystem.** `find_file` tries `.bl`, `.bl.md`,
`.bl.org` (`:require [my.book]` loads a doc); watcher accepts the extensions
and stages via recomposition; coherence errors mapped through `pos-map`.
*Acceptance: a `.bl.md` is required by a plain `.bl` program and by `mix compile` AOT.*

**W4 — `bl doc build` (the static site).** md/org-subset → hiccup; cells →
highlighted code + result spans; loom theme; search index over doc facts;
`hiccup->html` out. The tutorial thesis lands: build docs and build the SSG
blog with the same verb. *Acceptance: `docs/` renders to a navigable site;
every code example in it is the code that ran.*

**W5 — `bl live` (the notebook app).** Serve a doc as a Pulse-style app:
view = f(doc facts), events = facts, results = facts; per-viewer session
conn for drafts; hiccup passthrough for rich results plus a viewer registry
(`result-viewer!`); frozen cells styled as frozen. *Acceptance: two tabs
editing one doc converge through the log; `as-of` slider shows any prior run.*

**W6 — the reactive close.** Save a cell → `impact` over the doc graph →
re-run exactly the stale downstream cells, coherence-gated; doc-test mode
(`bl doc run --check`) fails CI when stored results don't match fresh ones;
unify with the explorer (`^:catalog` examples and livebook cells are one
kind of thing) and expose the doc graph over MCP for agents.

---

## 7. The hard parts (named now, so they don't bite later)

1. **External editors.** Obsidian reflows, org apps re-indent, git may CRLF.
   The slicer is tolerant; the renderer is conservative; the covenant is
   tested against *mangled* fixtures, not pristine ones.
2. **Position mapping.** Without `pos-map`, coherence errors point into a
   recomposed string nobody can see. This is W1/W3's real engineering, not
   the parsing.
3. **Runaway cells.** A notebook invites `(loop [] …)`. Cell evals run in a
   spawned process under a kill timer — ward already times and isolates; the
   livebook inherits it rather than inventing a sandbox.
4. **Unprintable values.** Pids, conns, closures: print via the ref-type
   `inspect` fallback, never crash; a value too large is summarized, not
   truncated silently (policy prints the elision).
5. **The atom table.** Notebooks mint symbols like nothing else; the reader's
   atom-exhaustion hazard (PLAN-009) is *the* known landmine in this exact
   territory. Land that fix before `bl live` invites free-form evals.
6. **Security.** A served doc is arbitrary code. `bl live` is a dev tool with
   capability caps (env capture / sandbox tiers), and the trust-boundary doc
   says so in public. No notebook mode ever widens caps silently.
7. **Two dialects forever.** The org subset stays small on purpose. When a
   feature would need full org semantics, the answer is "express it in the
   subset," not "grow a parser."

---

## 8. What this buys that no prior art has

- **The docs are requireable.** `:require [my.book]` — the tutorial's code is
  importable, AOT-able, and type-checkable, because the doc *is* a namespace.
- **The notebook never lies.** Static coherence held bundles mean on-screen
  results always correspond to code that coheres — Jupyter's original sin,
  closed by construction.
- **Time travel is `as-of`.** The doc's history is a log; viewing yesterday's
  notebook state is a query, not a backup.
- **One render path, live and static.** The same view functions that draw the
  served notebook freeze into the docs site — the SSG tutorial's thesis,
  applied to the docs themselves.
- **Agents read and write it natively.** A generative author edits cells;
  `bl doc run` proves the narrative and the code agree; the doc graph answers
  "which cell defines this?" over MCP. Self-documenting code, enforced.

The README says beam-lisp is a language for the generative era, and that
`.bl.md` makes code self-documenting. Maximalist livebook is simply taking
that sentence literally: the document is the program, the program is a log,
and the log is rendered — live, static, and in CI — from one source of truth.

---

## 9. Phase 2 — the live editor (design now, build later)

Phase 1 (§§1–8, shipped) makes the document a first-class program: `.bl.md`
and `.bl.org` slice into cells, run into one namespace, and write back only
their result spans. Nothing above needs a browser. Phase 2 puts a **live
editor** in front of that same document — and the design rule is that the
editor changes *nothing* about the covenant. The file on disk stays the truth
*of what to load* (the full ordering is LOG ⊐ FILE ⊐ IMAGE —
`live-architecture.md` §2); the editor is one more renderer that can also
emit facts.

### 9.1 Why Lexical, and what "the shim" means

We do not write a text editor. Rich-text editing (selection, IME, undo,
collaborative carets, accessibility) is a decade of browser edge cases;
[Lexical](https://lexical.dev) (Meta's editor framework) already solves them
and exposes a clean, serializable node model. We adopt Lexical for **keystroke
handling and caret-level state only**, and wrap it in a thin
**beam-lisp-maximalist shim** whose entire job is to keep Lexical's editor
state and the server's document facts in agreement.

The shim is deliberately small. It is *not* a port of Lexical's model into
beam-lisp, and it is *not* a place where document semantics live. It is a
translation membrane with two directions:

```
  Lexical editor state  ──(local edit → intent fact)──▶  server (datom truth)
  server document facts  ──(fact → editorState patch)──▶  Lexical
```

Everything that *means* something — a cell's identity, its source, its last
result, whether it is frozen — is a **server fact**. Lexical holds only the
ephemeral typing buffer and the projection of those facts into editable nodes.

### 9.2 The division of authority (the load-bearing decision)

> **Lexical owns keystrokes. The server owns truth.**

This single split resolves every hard question below. Concretely:

| concern | owner | why |
|---|---|---|
| caret, selection, IME composition | Lexical | sub-frame latency; must be local |
| in-progress text of the focused cell | Lexical | a keystroke cannot round-trip to the server |
| cell identity / order / source of record | server | the document is a namespace; order is run order |
| result spans, freshness, freeze state | server | results are facts, produced by `run` |
| "what does cell X define / depend on" | server | the doc graph already answers this (§6, W6) |
| conflict resolution across viewers | server | one log, `as-of`; the editor never merges |

The editor may *propose*; only the server *commits*. A local edit becomes an
**intent fact** the moment it settles (debounced on pause / blur / explicit
run), the server folds it into the document log, and the resulting document
facts flow back as an editorState patch. Lexical never mutates cell identity
or result spans directly — it cannot, because it never holds them as authority.

### 9.3 Events as facts (reuse `live.bl`, don't reinvent)

Phase 2 introduces **no new sync machinery**. `bl live` (§6, W5) already serves
a document as a Pulse-style app where *view = f(doc facts)*, *events = facts*,
*results = facts*. The Lexical shim is simply a richer client for that same
loop:

- **an edit is an event** → `{:cell/edit id :text "…" :basis <tx>}` — a fact,
  logged like any other; `:basis` is the tx the edit was made against, so a
  stale edit is detected at fold time, never silently merged.
- **a run is an event** → `{:cell/run id}` → the server evaluates under ward
  (spawned process, kill timer — §7.3) and transacts `:cell/result` facts.
- **a result is a fact** → it flows back to every viewer as a patch; the shim
  renders it into a *non-editable* Lexical decorator node (see §9.5).

Because edits and results are the same kind of thing the rest of the system
already speaks (datom facts on a log), time travel (`as-of`), multi-viewer
convergence, and CI doc-tests all keep working with zero editor-specific code.

### 9.4 State tiers — SHARED / SESSION / LOCAL

Live editing needs three tiers of state, and each maps cleanly onto a
`live.bl` scope. Getting a piece of state into the right tier is the whole
game; the tiers are:

| tier | lifetime & reach | examples | backing |
|---|---|---|---|
| **SHARED** | the document, all viewers, durable | cell source, result spans, freeze flags, cell order | the doc log on disk (the file is the fold) |
| **SESSION** | one viewer's connection | draft text not yet committed, cursor, scroll, selection, per-viewer viewer-registry choices | per-conn state in `live.bl` (dropped on disconnect) |
| **LOCAL** | one Lexical instance, sub-commit | IME composition buffer, in-flight keystrokes, transient decorator UI | Lexical editorState only; never leaves the browser until it settles into SESSION |

The rule that falls out: **a keystroke lives in LOCAL, settles into SESSION on
pause, and is promoted to SHARED only by an explicit or debounced commit.**
SHARED is the only tier that touches the file. SESSION is the draft buffer that
makes editing feel instant without lying to other viewers. LOCAL is Lexical's
private business and the server never sees it.

Promotion is monotone and one-directional per edit: LOCAL → SESSION → SHARED.
Demotion never happens; a rejected commit (stale `:basis`) surfaces as a fresh
SHARED fact that the shim reconciles into SESSION, and the viewer sees the
authoritative text with their draft rebased or flagged — never a silent
clobber.

### 9.5 Mapping the document onto Lexical nodes

The shim projects document facts into a small, fixed set of Lexical node
kinds. Prose is ordinary rich text; the two things that are *not* free text are
represented as **decorator nodes** (Lexical's escape hatch for
non-text-editable regions the framework still tracks for selection/undo):

- **prose block** → native Lexical rich-text nodes (headings, lists, quotes,
  tables) — editable, and serialized back to md/org on commit by the same
  renderer Phase 1 already owns, run in reverse.
- **cell (code)** → a `CodeCellNode` decorator: a CodeMirror/textarea island
  for the source, editable as text, but a single unit to Lexical's model. Its
  identity is a SHARED fact; its buffer is SESSION; its keystrokes are LOCAL.
- **result span** → a `ResultNode` decorator: **read-only**, rendered from the
  `:cell/result` fact (hiccup passthrough + the viewer registry from W5). The
  user cannot type into a result, which is exactly the covenant — the tool
  writes result spans, humans do not.
- **frozen cell** → the same `CodeCellNode`, styled frozen and marked
  non-runnable; the freeze flag is SHARED.

Crucially, the md/org ⇄ nodes mapping *is* Phase 1's slicer/renderer used in
both directions. There is no second parser. On load: file → spans → nodes. On
commit: changed nodes → spans → file, touching only what changed, result spans
still owned solely by `run`. `render(slice(x)) == x` (the Phase 1 covenant)
guarantees the editor cannot corrupt a byte it did not intend to change.

### 9.6 The commit path, end to end

```
keystroke
  → Lexical editorState (LOCAL)
  → debounce / blur / ⌘↵                     ; settle
  → shim diffs changed nodes → span deltas   ; SESSION draft
  → intent fact {:cell/edit id :text :basis} ; promote to SHARED (proposed)
  → server folds into doc log                ; commit or reject (stale basis)
  → doc facts patch broadcast to all viewers
  → shim applies patch → Lexical editorState ; SHARED → visible
  ⟂ on {:cell/run}: eval under ward → :cell/result fact → ResultNode
```

Every arrow that crosses the browser/server boundary is a fact on the existing
log. The editor is stateless with respect to truth: reload the tab and the
document reconstitutes from SHARED facts; the only thing lost is LOCAL (an
in-flight keystroke) and SESSION drafts the viewer hadn't committed — which is
the correct and expected loss.

### 9.7 Trust model — assume a trusted user, say so in public

Phase 2's target is a **single trusted author** (or a small trusted team) on
their own machine or a trusted host. A served document is arbitrary code;
`bl live` inherits ward's capability caps (§7.6) and **never widens them for
the editor**. The editor adds no new authority: it can only emit the same
`:cell/edit` / `:cell/run` facts a scripted client could already emit against
`bl live`. We do not build a multi-tenant sandbox in Phase 2; if untrusted
multi-user editing is ever wanted, that is a separate capability-tiering
project, and the trust-boundary doc will say so before a single untrusted
keystroke is accepted.

### 9.8 What Phase 2 must *not* do (guardrails)

- **No document semantics in JS.** The shim translates; it never decides cell
  identity, order, or result freshness. Those are server facts.
- **No second parser.** md/org ⇄ nodes is Phase 1's renderer, both directions.
- **No editable results.** Result spans are tool-owned; the editor renders them
  read-only. This is the covenant, enforced at the node level.
- **No silent merge.** Concurrent edits reconcile through the log with an
  explicit `:basis`; a stale edit is surfaced, never blindly applied.
- **No cap widening.** The editor emits the same facts a script could; it gains
  no authority the served app didn't already grant.

### 9.9 Prerequisites and sequencing

Phase 2 sits on top of W5 (`bl live`) and therefore on W1–W4 (shipped in
Phase 1) plus W5's per-viewer session conn and viewer registry. The one hard
prerequisite named in §7.5 stands: **the reader's atom-exhaustion fix
(PLAN-009) must land before a live editor invites free-form evals** — a
notebook mints symbols like nothing else, and the editor is the ultimate
free-form eval surface. Ship PLAN-009, then W5, then the Lexical shim.
