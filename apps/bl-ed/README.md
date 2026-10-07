# bl-ed — a `.bl.org` editor written in Beam Lisp

bl-ed is a modal, structural editor for literate Beam Lisp documents
(`.bl.org`). Every decision it makes is Beam Lisp: the document model, the
selections, the modes, the key bindings, the motions, the commands, the org and
form structure, and what each line looks like. That code is compiled to
JavaScript by the **sync JS profile** (`priv/lib/js/`) and runs in the
browser. The page (`web/host.mjs`) only turns input into events, draws the view
model BL returns and performs the effects BL asks for. A small BEAM server
(`serve.bl`) reads and writes files and evaluates cells.

It is the first real consumer of the JS target outside the actor demos and the
split apps (PLAN-161).

## Run it

```sh
apps/bl-ed/build.sh                      # BL → ES modules into apps/bl-ed/web/out/
bl run apps/bl-ed/serve.bl               # http://127.0.0.1:8790/
# open a repo document:
#   http://127.0.0.1:8790/?file=docs/tools/02-lsp.bl.org
# serve another tree:
BLED_ROOT=~/notes BLED_PORT=8791 bl run apps/bl-ed/serve.bl
```

Without the server the page still works from any static host. It edits the
welcome document, and `C-s` downloads the file.

## Using it

Selection first, then action, as in Helix: a motion selects what it moves over,
and an action (`d c y p`, `>`, `C-c`, `space r`, …) applies to every selection.

| keys | what |
|---|---|
| `h j k l` `w b e` `W B E` | move / select by character, word, WORD (`3w` repeats) |
| `x` `v` `;` `,` `C` | select line (repeat extends) · select mode · collapse · keep primary · add a cursor below |
| `i a I A o O` · `Esc` | insert before / after / line start / line end / open below / above · back to normal |
| `d c y p P u U` | delete · change · yank · paste after / before · undo · redo |
| `> <` `C-c` | indent · dedent · toggle `;` comments |
| `/ n N *` | search (smart-case), next, previous, word under cursor |
| `] h` `[ h` `g u` | next / previous heading · parent heading |
| `] b` `[ b` | next / previous source block |
| `space o` · `Tab` | outline overlay · fold the section |
| `m m` · `g j g k g H g L` | select the form under the cursor · form motion: first child / parent / previous / next |
| `m i (` `m a (` `m s` `m c` `%` | inside / around the enclosing form · the section · the cell · matching delimiter |
| `space r` `space w (` `space s` | raise · wrap · splice (structural edits in beam-lisp cells) |
| `space e` / `C-Enter` | evaluate the cell where it may run (● in the page, ◆ on the BEAM) and write `#+RESULTS` |
| `C-s` | save |
| `:` | evaluate a Beam Lisp form against the live editor |
| `space space` / `M-x` | command palette (fuzzy) |
| `space k` `space ?` | describe the next key · show the keymap |

The form motions follow the contract in `docs/design/form-first-interaction.md`:
first child else next sibling, parent else next top-level form, no wrapping,
and a message when a move cannot advance. `g j/k/H/L` is the web chord for the
native `Ctrl+J/K/H/L`, which browsers reserve.

### The editor is a Lisp machine

`:` evaluates real Beam Lisp IN THE PAGE — the self-hosted reader,
compiler and macros (`priv/lib/js/eval.bl`, built into `web/out/` beside the
editor), so `defn`, `defmacro`, destructuring, `->>`, `for`, exact decimals
and every core macro work exactly as on the BEAM (`bl test
test/bl/js_diff_test.bl` holds the two to the same answers). The language
starts with the page (~0.5 s: core.bl's macros from source); one command
takes 0.2–1.5 ms. The `ed` namespace is the live editor:

```clojure
(ed/outline)                          ; [[level title line] …]
(ed/goto 120)                         ; jump to line 120
(ed/find "defn")                      ; select every match
(ed/bind :normal "Q" :doc-end)        ; rebind a key, now
(ed/defcmd :mine "My command." (fn [ed] ed))   ; add a command
(ed/cmd :heading-next)                ; run any command by name
(count (ed/commands))                 ; 72 named commands
(-> (ed/state) :sels count)           ; inspect the editor value
(defmacro twice [x] `(do ~x ~x))      ; your own macros…
(defn deepest [] (->> (ed/outline) (map first) (reduce max)))   ; …and fns
```

Every key is bound to a NAMED command in one table (`ed/commands.bl`), and
keymaps are plain data (`ed/keymap.bl`). So anything a key does, the palette
and `:` can do; `describe-key` can explain it; and rebinding is a value change.

## How it is built

```
ed/text.bl      the document: a persistent vector of lines; [row col] positions
                with col a GRAPHEME index (é and 👍🏽 are one column each)
ed/org.bl       the span partition bl.doc uses (prose/cell/result/prose-code/
                heading) + the outline; total, never fails mid-edit
ed/forms.bl     a lenient reader for beam-lisp cells: forms with exact spans,
                recovering from stray, mismatched and unclosed delimiters
ed/core.bl      the editor value, selections, multi-cursor edits, undo, and the
                incremental structure update
ed/motion.bl    motions as (text, pos) → pos: Helix words, org, forms
ed/commands.bl  the named command table (72), including paredit-style edits
ed/keymap.bl    keymaps as data, counts, key sequences, the dispatcher
ed/num.bl       number parsing that behaves the same on BEAM and JS
ed/main.bl      events in, view model out; minibuffer; palette
web/host.mjs    DOM, input (hidden textarea: IME, dead keys, paste), effects
web/theme.css   snow & coffee, matte pastel
serve.bl        GET/save/eval over HTTP on loopback; eval runs through bl.doc
```

**Purity.** Every command is `(fn [ed] ed')`. Saving, clipboard writes and
evaluation are effects returned as data (`:effects`). The host performs them
and reports back with an event. The same core runs headless in Node for the
tests, and `ed.selftest` runs identically on BEAM and in JS.

**Round trip.** The text is never re-serialized from structure. Structure is
derived from the lines, so a document saves byte-for-byte as it was read. The
tests check this on all 30 `.bl.org` files in the repo.

**Speed.** Measured in headless Chrome on `docs/changelog/v2026.4.bl.org`
(1,161 lines). A full frame is BL `handle` + BL `render` + DOM update:

| action | p50 | p95 |
|---|---|---|
| type a character | 4.6 ms | 11.0 ms |
| `j` | 4.2 ms | 13.9 ms |
| `w` | 3.5 ms | 10.2 ms |
| `u` | 2.2 ms | 6.2 ms |
| `] h` | 9.2 ms | 21.3 ms |

BL's own share of a keystroke is under 0.4 ms (cursor move 0.04 ms, typed
character 0.31 ms, render 2.5 ms). Four changes made it this fast:

- Typing inside a non-structural line shifts the partition and re-reads one
  cell, instead of re-deriving the whole document. This is property-tested
  equal to a full derive over 450 random edits on 3 real documents.
- Block lookup is a binary search.
- Code marks are computed only for visible cells.
- Grapheme segmentation is cached per string in the core.

## Tests

```sh
apps/bl-ed/build.sh
BLED_OUT=apps/bl-ed/web/out BLED_ROOT=. node --test apps/bl-ed/test/drive.test.mjs   # 16 tests
cd apps/bl-ed && bl run ed/selftest_beam.bl                                           # 42 checks on BEAM
```

The drive tests feed real key sequences to the compiled editor and check:
motions, counts, insert/undo, multi-cursor, line selection, org and form
navigation, paredit, the command line, the palette, describe-key, search,
effects, eval reload, the render model, round trip, and incremental ==
full structure.

## Limits (honest)

- Evaluation is trusted code execution on the BEAM, exactly as `bl doc run` is.
  The server binds to loopback only.
- `:` interprets a subset of Beam Lisp (data, `fn`, `let`, `if`, `cond`,
  `when`, `do`, `def`, `->`, calls of core and `ed/` functions). There are no
  macros and no `ns` in it; compiling full BL in the browser is FUP-134.
- Folding is per section (`Tab`). Folds are a view property and are not saved.
- Column positions on screen are measured from the DOM per line, so emoji and
  CJK are positioned honestly. Very long lines are not virtualized
  horizontally.
- IME composition is handled through the input sink (`compositionend` delivers
  one `:text` event). It has been tested with synthetic events, not yet with a
  real CJK input method.

## Split cells: where does each cell run?

On open and after every save, bl-ed asks the BEAM where each cell may run
(`POST /api/place` → `system.place`, one whole-document analysis). A cell
that is pure and provably terminates is marked **●** in the gutter and
`space e` evaluates it **in the page**, through Beam Lisp compiled to JS, and
writes its `#+RESULTS` at once (no round trip). Any other cell is marked
**◆**; hover it to read why (`effect in an expression: footprint
{:opaque-world :W}`), and `space e` runs it on the BEAM as before. Both
write results through the same `bl.doc.spans/write-results`. Try it:
`?file=apps/bl-ed/web/split-demo.bl.org`.
