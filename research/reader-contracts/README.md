# reader-contracts — the four reader contracts, prototyped in beam-lisp

```
cd <tree>
BEAM_LISP_AOT_CACHE_DIR=/tmp/aot-rc BL_NO_LOCK=1 \
  ./bl -p research/reader-contracts test research/reader-contracts/rc_test.bl
#   ✓ rc_test  87 passed        ✓ all green

BEAM_LISP_AOT_CACHE_DIR=/tmp/aot-rc BL_NO_LOCK=1 \
  ./bl -p research/reader-contracts run research/reader-contracts/rc-demo.bl
#   the demo: six unbalanced sources, diagnosed and repaired
```

The cache env vars are only needed while a concurrent session holds the shared
AOT cache lock (`~/.cache/beam_lisp/aot.lock`); without them `bl` waits, and on
a contended tree it can exit silently. Drop them when the tree is quiet.

Two further traps in this venue, both measured (PLAN-135 lists the rest):
`./bl` never loads the tree's own `priv/boot/reader.bl` — the drop ships a
**compiled** `reader`, so `-p priv/boot` does *not* override it, and a change
there needs a rebuilt drop (or a renamed copy) to be exercised at all; and a
long-running `bl` (past ~35 s) can be SIGTERM'd by a concurrent session clearing
runs, so keep verification runs short or expect to retry them.

Files, all beam-lisp, all under `research/` — nothing in `priv/` or `lib/` is
touched:

| file | what it is |
|---|---|
| `rc-reader.bl` | `(ns rc-reader)` — the reader: scanner, parser, diagnostics, options, stream |
| `rc-repair.bl` | `(ns rc-repair)` — candidate repairs, forward verification, the message |
| `rc_test.bl` | 87 assertions, `deftest`/`is`, run by `bl test` |
| `rc-demo.bl` | the demo; every output quoted below is printed by it |

**Why a second reader exists at all.** It does not, for long. This is a spike
under `research/`, wired to nothing: the deliverable is the *policy*, and the
port is a transcription into `priv/boot/reader.bl` (§Port). When that lands,
`rc-*` is deleted. A reader that is *not* the compiler's front door is exactly
what the study says not to keep — the reason to write it here is that the
policy has to be RUN to be believed, and the tree's own toolchain is being
edited by other sessions.

---

## The vision, in one paragraph

The reader is the first act of the harness. It decides **what may be written**
(the reader's options are the admission contract), **what comes back when it is
wrong** (a diagnostic is data, and names the delimiter that was opened and
where), and **where** (a span carrying the offsets that locate AND slice the
type checker and the LSP). Today `priv/boot/reader.bl` answers all three with a
hard-coded policy: three entry points, positions on lists only, a bare message
on failure, no offsets, no stream. edamame shows all of that can be values
(`research/edamame/README.md` is the study); this is the prototype.

And the concrete goal: **an unbalanced paren is the most common mistake a person
or a model makes, and the reader must be able to say which delimiter, where it
was opened, and what to do about it — including "I cannot tell, there are two
repairs".**

## The four contracts

| # | contract | the prototype's answer |
|---|---|---|
| 1 | options are a **value** | `(read src {:location :lists\|:collections\|:none  :read-cond :select\|:preserve  :diagnostics :collect\|:raise  :file "x.bl"})` |
| 2 | positions carry **offsets** | a `pos` is `{line col file offset}`; a span carries `:offset`/`:end-offset`; `(slice src span)` **is** the form's own text |
| 3 | errors are **data** | a map: `:kind :message :span :expected :opened :opened-span :eof-span :unclosed` |
| 4 | reading is a **stream** | `(read-next st)` → `[:ok form st]` \| `[:eof st]` \| `[:error diag st]`; `(read-next-string st)` → `[:ok form text st]` |

Plus `read!`, the raise-y face for the compiler path — the exception's message
still carries `file:line:col`, because that is what FUP-102 asks of `bl run`.

The node vocabulary is not re-implemented: `rc-reader.bl` **requires**
`reader-node` and emits its shapes (`{:list …}`, `{:meta node pos}`, a bare
scalar as itself). What the spike adds is the *policy* — `:location` decides
which nodes get the wrapper, `:read-cond` decides what a conditional becomes,
`:diagnostics` decides whether a failure collects or raises.

## Goal #1 — the unbalanced paren

Verbatim from `rc-demo.bl`:

```
## unclosed, and there is real source AFTER it — where the closer goes is a choice

   1 | (defn f [x]
   2 |   (inc x
   3 |
   4 | (defn g [y] (dec y))
   5 |

demo.bl:2:3: unterminated ( — the source ends before it is closed — 1 other opener(s) unclosed too
  2 |   (inc x
    |   ^

  note: also unclosed: ( at demo.bl:1:1
  help: 2 different repairs each balance the file — which did you mean?
    1 edit (clears the file) — add )) at the end of the file
    1 edit (clears the file) — add )) at the end of line 2 — there is more source after it, so the closer probably belongs there, not at EOF (the two give different programs)
    2 edits (still broken) — delete the ( at 2:3 — it opens nothing

   fix loop: insert-closers-at-boundary — 1 round(s), reads cleanly
```

Four deliberate properties, none of which today's reader can produce:

- **The caret lands on the OPENER**, not on EOF. "Here is the one you forgot" is
  the useful sentence; "here is where the file stopped" is not.
- **The outer openers are listed**, so a three-deep nesting names all three.
- **A long line is windowed** around the caret rather than truncated — the
  mistake is usually at the END of a long line (`priv/lib/web.bl:479` is 80
  columns), so truncating the tail would hide exactly the character in question.
- **The help is generated, ranked, and verified** — and it will not pretend.

And FUP-102's acceptance, printed by the same run:

```
## FUP-102 acceptance: read! on an unbalanced file
   stderr: priv/std/proc/sched.bl:2:3: unterminated ( — the source ends before it is closed — 1 other opener(s) unclosed too
   exit:   1
```

## Repair: abduce, then verify forward

`rc-repair` is the diagnostic run **backwards**: instead of "is this balanced?",
"what edit would balance it?" Ranking is by **edit count** — a measurement, not a
taste — and then every candidate is applied and the result **re-read**
(`solves?`). That forward check is what turns a guess into an answer:

```
(when x [1 2)
  replace ) with ]     → (when x [1 2]     → still unterminated   ✗
  insert ] before )    → (when x [1 2])    → reads cleanly         ✓
```

Two candidates at one edit each; only one yields a text that parses. The tie
**collapses**, and `ambiguous?` says so. This is
`research/p21_repair/spike_repair.bl`'s move — abduce the candidate, check it
forward — one layer down: the syntax instead of the state machine.

Where the tie does **not** collapse, the tool must not guess. `(a b))` has two
one-edit repairs that both read cleanly (delete the stray `)`, or insert the `(`
that was never typed). The message says so and lists both; `choose` still picks
one, but returns `:policy` and `:others`, so a harness can tell a model *"I
guessed, and here is what else it could have been"* instead of passing a guess
off as a fact.

And the one-pass/loop distinction is honest: `(defn f [] (str "hello` has an
unterminated string **and** two unclosed openers, so no single edit clears it.
`fix-all` is the loop — fix, re-read, fix — and the demo shows it taking two
rounds (`insert-quote-at-line-end -> insert-closers-at-eof`). A machine that
reported "repaired" after one pass would be lying. Where no candidate clears the
file at all, the message says so rather than naming a repair that does not work:

```
  help: close the string at the end of line 1 — a PARTIAL repair: this source has more than one defect, and the fix loop
        resolves them in turn (each candidate is verified before it is offered).
```

## The lexical traps

A balance checker that miscounts sends a person to the wrong line, so the suite
pins the cases where a `)` is not a `)`:

- a closer inside a **string** (`(str ")")`),
- an opener inside a **comment** (`; ( ( (`),
- a closer inside a **character literal** (`\)`),
- a `}` that must close a `#{`, not a `)`.

All four are asserted to read cleanly; the last is also asserted to produce a
`mismatch` expecting `}` when it does not.

## Why the tree shape is the risk — the honest answer

Making `:location` a value is cheap. Making the compiler *see* a wider set of
wrapped nodes is not, and this is where the spike earns its keep as a warning.

**The failure mode is silent, not loud.** `node-tag/1` on a wrapped vector
returns `:meta`. Nothing crashes. A `cond` arm that expected `:vector` simply
does not fire, and the compiler quietly takes a different path — a wrong answer
in place of an error. In `priv/`, roughly **90 tag matches and 88 raw
`tuple_to_list` uses** sit outside the two accessors designed to be safe:
`compiler.bl` alone has 49 tag matches and 18 `tuple_to_list` uses, then
`lib/system/core.bl` 21/18, `std/typed.bl` 19, `std/span-rewrite.bl` 13,
`lib/lsp.bl` and `lib/live/lint.bl` 10 each.

**The safe channel already exists and is already wide.** `reader-node.bl`'s
`node-form/1` peels exactly one `:meta`, and `node-items/1` peels before reading
children — and its own header already documents `{:meta, node, pos}` as the
general wrapper for *any* node, not just a list. The vocabulary was built for a
reader that wraps composites; the reader narrowed to lists. 368 call sites go
through `node-form` and 267 through `node-items`; those are unaffected.

**The cost has already been paid once, and it is recorded.** The prototype that
wrapped every composite (`research/p2_positions`, still in the tree) writes:

> *Meta wraps composite nodes only — and helpers must peel it. First version
> missed every bug because `walk-if`'s test and each `->>` step arrive
> meta-wrapped; `node-items` on a meta node returns the inner tuple, not its
> items. Fix: `node-form` peel + meta-transparent `node-items`.*

That is a debugging round lost to a silent mis-branch, and it is why the change
must be **defaulted off** for the parse paths the compiler reads — which is what
the prototype does: `:location :lists` is the default and reproduces today's
shapes, `:collections` is opt-in per consumer.

**So: nothing is bad about it IF the change is an option and the gate is beam
identity.** Three rules, and the spike implements the first:

1. **Default off.** `:lists` is the default; the compiler's tree does not move.
2. **Audit the ~90 raw-tag sites** before turning it on for a compile path. They
   are enumerable, and a lint ("a `node-tag` whose argument was not peeled
   first") can name them mechanically.
3. **Gate on identical beams**, not on green tests: compile the corpus before and
   after and require the same output — the tree's own rule that the same source
   must give the same beam.

## What this spike does NOT do

- **It is not the real reader.** No `ns` handling, no tagged-literal semantics
  (a `#tag form` is read as `{:tagged tag form}` and left alone), **no `#(…)`
  function-literal desugaring** (a reader-macro detail with no policy question in
  it), no atom-table guard, no `#d[…]`/`#inst`, no multi-line string rule, and
  string escapes cover only `\n \t \r \" \\`. The parts it omits are the parts
  with no policy decision to make.
- **Offsets are CODEPOINT indices, not bytes.** The tree's reader threads a
  `{line col file}` tuple; this one adds a 4th slot. The unit is codepoints
  because that is what the one existing consumer indexes by — `span-rewrite`
  walks `(String/codepoints src)` and cuts with `subvec` — so
  `(subvec cps (:offset pos) (:end-offset pos))` substitutes for
  `(+ (get line-offsets line) (dec col))` with no conversion. An LSP needs UTF-16
  code units, which it converts to from whichever unit it is handed; a byte
  offset is a separate decision, not this one.
- **`fix-all` is greedy.** It takes the chosen repair each round and does not
  backtrack, so a source where the second repair only works if the first was
  different would not be solved. No such fixture is claimed.
- **No repair for a *semantic* mistake** — a form that parses and is wrong. That
  is `research/p21_repair`'s territory; the split is deliberate.
- **No performance claim.** Nothing here is timed, and the forward check re-reads
  the source once per candidate. That is fine on a diagnostic path and would not
  be on a hot one.
- **87 assertions, not coverage.** They pin the contracts and the traps; they do
  not bound the reader over arbitrary input.

## Port — the transcription, in order

Each step is shippable alone and names what it deletes or unblocks. The
transcription is now file-to-file: `rc-reader.bl`'s `pos`/`span`/diag builders
map onto `priv/boot/reader.bl`'s `make-pos`/`advance-pos`/`syntax-error`, and
`rc-repair.bl` is new code that does not exist there at all.

### 1. `syntax-error` carries the position, and the opener

`priv/boot/reader.bl`. Today: `(defn- syntax-error [message] (erlang/error
(BeamLisp.Reader.SyntaxError/exception message)))`, and the read loop keeps no
delimiter stack. Port `rc-reader`'s four diagnostic builders and the stack that
feeds them; put the position in the MESSAGE too, because the CLI path loses the
struct (FUP-102).

- deletes: the `bl run` silence (exit 141 / `unexpected )` with no file and no line)
- unblocks: `bl check` diagnostics; a repair rung; mid-typing LSP
- accept: `bl run FILE` on an unbalanced file prints `FILE:L:C: …` and exits 1

### 2. offsets in the position map

LANDED in the reader: `make-pos` gained a 4th slot,
`advance-pos`/`advance-to` count it, and `pos-meta`/`pos-meta-span` emit
`:offset`/`:end-offset`, so a span can slice its own source. The unit is
CODEPOINTS — measured, not assumed: the one existing consumer, `span-rewrite`,
walks `(String/codepoints src)` and cuts with `subvec`, so the substitution is
direct.

Measured: every top-level form's span slices back to its own text, including the
form after a multi-byte `→` and a form with an inner comment; and three rich
sources (295 top-level forms — `priv/boot/reader.bl`, `priv/boot/core.bl`,
`priv/lib/web.bl`) parse **structurally identically modulo the two new keys**.

- deletes (NOT yet — and the gate is the point): `span-rewrite.bl`'s
  `line-offsets` and the three arithmetic sites built on it. The gate is that
  EVERY producer of a pos map carries offsets — including the compiler's
  synthesized positions for desugared macro nodes (`research/p2_positions`),
  which are built outside the reader. Until those carry offsets, `slice-node`
  needs its fallback and the table stays; deleting the table first would make a
  rewrite degrade to `pr-str` instead of failing loudly.
- unblocks: a rewriter or an LSP that slices a span with no table, no arithmetic
- accept (met): `node-pos` carries `:offset`/`:end-offset`

### 3. `read` takes an options map

`(read src opts)`; `read_string/2`, `read_all/1`, `read_one/1` become thin
aliases. Start with `:location` and `:diagnostics` only — enough to delete
`read_all`-as-a-strip-phase and to give the harness a restricted mode.

- deletes: the second entry point that exists to express one boolean; the
  post-hoc `unwrap-deep` for a caller that never wanted positions
- unblocks: `trust-boundary.md`'s boundary stated in the call (no reader macros,
  no tagged readers, no novel atoms) instead of enforced afterwards
- accept: `grep -rn "read_all\b" priv/` finds only the alias

### 4. `read-next` / `read-next-string`

The reader already threads its position; the stream is the same code with the
loop hoisted out. `rc-reader`'s state map is the shape to copy.

- unblocks: form-at-a-time REPL evaluation; `bl watch` re-reading a suffix; a
  harness loop reading a model's partial output and answering per complete form
- accept: `read-next-string` yields the form and its own text, comments intact

### 5. `:location :collections`, LAST, behind the three rules above

- unblocks: the trivia-preserving rewriter (`research/structural-rewrite` stops
  degrading a captured vector or map to `pr-str`)
- accept: a rewrite whose capture is a multi-line vector keeps its comments
  byte-identically, with identical beams on the corpus

### 6. the repair layer, then the four contracts wired to what exists

`rc-repair.bl` is new: it has no counterpart in `priv/`. Port it after the
diagnostic contract lands, because the forward check depends on `read` returning
diagnostics as data.

- `research/edamame/oracle.clj` is the **external** gate: edamame's reading of
  the same source, with a `:dialect` profile for the cases where beam-lisp is
  deliberately more permissive.
- the diagnostic contract becomes the **tool-contract** contract: FUP-003's
  proposal schema becomes a projection of one reader value — the argument of
  `research/edamame/README.md` §7.

## What to read next

- `research/edamame/README.md` — the study: what edamame is, what it does that we
  do not, why the dependency is the wrong move and the ORACLE is the right one.
- `research/p2_positions/README.md` — the earlier wide-location prototype, and the
  recorded cost of getting the peel wrong.
- `research/p21_repair/spike_repair.bl` — the same abduce-then-verify move, for
  state machines instead of syntax.
- `!tasks/follow-ups/FUP-102-…org` — the acceptance §1 is written to.
- `!tasks/plans/PLAN-135-…org` — the build order §Port expands.
