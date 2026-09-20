# edamame — what it is, what it is worth to us, and what we should steal

**Question.** `borkdude/edamame` is the Clojure world's answer to "read code as
data, with positions, safely". We already have a reader that does that
(`priv/boot/reader.bl`, self-hosted). Is edamame worth adopting, worth porting,
or worth ignoring — and either way, what does its existence tell us about the
reader we have?

**Verdict.** Do not adopt it, and do not port it. **Steal four contracts from
it, and use it as an external oracle.** edamame is a mature third-party
implementation of *tooling-grade reading*; our reader is a compiler front door
with three hard-coded policies where edamame has values. The four contracts —
**options are a value · errors are data · every node has a span with offsets ·
reading is a stream** — are cheap for us, each deletes code or unblocks a tool
we already prototyped, and the first one repairs a defect this session hit twice
(**FUP-102**).

**The prototype is `research/reader-contracts/`** — all four contracts plus the
friendly-diagnostic goal, written in beam-lisp and runnable:
`./bl -p research/reader-contracts test research/reader-contracts/rc_test.bl`
(87 assertions, green) and `… run research/reader-contracts/rc-demo.bl` (the demo,
whose output its README quotes verbatim). The ordered port map is at the end of
that README. §5 below is the plan the prototype was built from; where they
disagree, the prototype is what was measured.

---

## 1. How edamame works

Read from source (`src/edamame/impl/parser.cljc`, 1085 lines) plus a live run
(`bb`, which ships it built in — see §6).

**The engine is an indexing pushback reader.** `edamame.core/reader` wraps a
string in `clojure.tools.reader.reader-types`' *indexing* reader: a cursor over
`:s` with an `:idx`. Everything downstream is `read-char` / `unread` /
`skip-whitespace`, and `get-line-number` / `get-column-number` are O(1) reads
off that cursor — so line, column **and byte offset** are all free at every
moment.

**One `ctx` map threads the whole read.** Options are not flags baked into
branches; they are a value passed down every `parse-*` call. `normalize-opts`
expands `:all true` into the explicit set. The notable options:

| option | what it buys |
|---|---|
| `:all` | the Clojure-default reader macro set (`'` `@` `` ` `` `~` `#'` `#()` `#""`) |
| `:location?` | a **predicate** deciding which values get positions |
| `:end-location` | attach end coordinates (and so spans) |
| `:postprocess` | a hook `(fn [{:obj v :loc loc}])` run on every value the reader hands back |
| `:read-cond` `:features` | `:allow` (select a branch) or `:preserve` (keep all branches as data) |
| `:readers` | the `#tag` dispatch table |
| `:read-eval` | **off by default** — `#=` is refused unless you ask |
| `:auto-resolve` / `:auto-resolve-ns` | resolve `::alias/kw` using an explicit map, or by reading the `ns` form as the stream goes |
| `:map` / `:set` | constructors, so a map literal can become an ordered map |
| `:row-key` / `:col-key` | name the position keys |

**Positions ride as metadata on the values.** A form *is* the value it denotes,
carrying `{:row :col :end-row :end-col}` — transparent to everyone downstream.
`:postprocess` exists for values that cannot carry metadata (numbers, strings);
with it, attaching location becomes the caller's job, explicitly.

**Errors are data.** `throw-reader` wraps `ex-info` with the position *and* the
delimiter state — measured:

```clojure
(try (e/parse-string "{:a (let [x 5")
     (catch Exception ex (ex-data ex)))
;; {:row 1, :col 13,
;;  :edamame/expected-delimiter "]",
;;  :edamame/opened-delimiter "[",
;;  :edamame/opened-delimiter-loc {:row 1, :col 10}}
```

That is enough for `fix-expression` — the documented repair loop, which we ran:
`"{:a (let [x 5"` → `"{:a (let [x 5])}"`. `Delims` is one record field carrying
`{expected char row col}` of the innermost open collection, so the diagnostic is
built as the stack unwinds, not reconstructed afterwards.

**Reading is a stream.** `reader` + `parse-next` yields one form per call;
`parse-next+string` on a `source-reader` yields **the form and its own original
source text** — measured, comments intact:

```clojure
(let [r (e/source-reader "(defn f [x]\n  ;; c\n  (inc x)) 42")]
  (e/parse-next+string r))
;; [(defn f [x] (inc x)) "(defn f [x]\n  ;; c\n  (inc x))"]
```

**Deterministic reader macros.** `#(* % %1 %2)` reads as `(fn* [%1 %2] (* %1 %1 %2))`
— gensyms are *stated*, not minted, so the same source reads to the same tree in
every process. Our reader converged on this independently (`p1__`, `rest__`).

**Auto-resolve reads the `ns` form.** `parse-ns-form` yields
`{:name :aliases :requires …}`; `:auto-resolve-ns` then resolves `::set/foo` to
`:clojure.set/foo` **while reading**, from a single file, with no compile step.

---

## 2. What we have

`priv/boot/reader.bl` (928 lines) reads source text to `reader-node` tuples —
`{:symbol} {:keyword} {:list} {:vector} {:map} {:set} {:record} {:meta}` — over
a charlist, with `{line,col,file}` positions threaded as a return value (the
returned position is the head of the *unconsumed* source, so siblings thread
linearly; `advance-to` walks exactly the consumed prefix).

It is **strong where edamame is weak**:

- **It is the language's own front door.** Bootstrapped from the committed seed,
  shared by the compiler, the type checker, `source-graph`, `deodorant`, the
  rewriter and the LSP — one vocabulary (`reader-node.bl`) with one documented
  meaning per tag. edamame is a Clojure library; adopting it would put a second
  reader beside this one, which is the parallel implementation our whole doctrine
  exists to forbid.
- **It knows the language's semantics** — `1.5M` → a `BeamLisp.Decimal`, `7N`,
  char literals as codepoints, records, a live data-reader registry.
- **It guards the atom table.** `BeamLisp.AtomGuard/account!` runs per interned
  token, turning an uncatchable full-table VM abort into a catchable error.
  edamame has no analogue (a JVM process cannot exhaust its atom table).
- **It is not bounded by the value's type.** edamame puts a location on a value as *metadata*, so only values that can carry metadata get one — measured: with `:location? (constantly true)`, `[1 {:a 2}]` gave positions to the vector and the map and `nil` for the scalars `1`, `:a`, `2` (`:postprocess` is the escape hatch, and using it makes attaching the location the caller's job). Our positions ride in a `{:meta node pos}` *tuple wrapper*, so nothing is out of reach — a scalar can be positioned, and edamame cannot say that. The freedom to choose *where* positions go is worth taking; the metadata channel is not.
- **It carries spans** for the forms it positions (`{:line :col :end-line
  :end-col :file}`, `pos-meta-span`), and that span rides to `:ann` in bl-ANF,
  where every engine reads it. This is the one-form work, and it is ahead of
  edamame: edamame gives *a location*; we give a span that the compiler, the
  proof engines and the error printer all read off the same node.

It is **rigid where edamame is configurable**:

```
BeamLisp.Reader.read_string/2   positioned, lists only
BeamLisp.Reader.read_all/1      same, positions deep-stripped
BeamLisp.Reader.read_one/1      exactly one form, bare
```

Three entry points, no options, and the only difference between the first two is
one boolean. Positions are attached to **lists only** (`wrap-list-pos` is called
from the list/prefix/dispatch paths and nowhere else); `read-all` then
deep-unwraps with `unwrap-deep`. Reader conditionals always *select* —
`CONDITIONAL-FEATURE` is the constant `"clj"` — and a conditional with no
matching branch reads as **nothing** (correct for a compiler, lossy for a tool).
Errors carry a message and nothing else:

```clojure
(defn- syntax-error [message]
  (erlang/error (BeamLisp.Reader.SyntaxError/exception message)))
```

The file's own comments record that several of these policies are **bug-for-bug
parity with the deleted Elixir genesis reader** — `#()` bodies, record literals
and data-reader payloads deliberately *undercount* their column, "matched for
parity". The genesis reader is gone. The policies it left behind are not
semantics; they are the shim's implementation details, frozen.

---

## 3. The gaps, each with what it costs

| gap | evidence | what it blocks |
|---|---|---|
| **No options** | three fixed entry points; `read-all` exists only to express "strip positions" | one reader per consumer: the harness cannot ask for a *restricted* read (no reader macros, no tagged readers), a *lossless* read, or a *narrow* read, so each such consumer grows its own filter — FUP-003's schema heredoc is exactly this disease one layer up |
| **Positions on lists only** | `wrap-list-pos` call sites; `span-rewrite`'s `has-span?` falls back to `pr-str` for anything else | Tool 1 (trivia-preserving rewrite) loses comments whenever a captured sub-form is a vector or a map, not a list — measured cliff in `research/structural-rewrite/README.md` |
| **No offsets** | `span-rewrite.bl`'s `line-offsets` re-scans the whole source to build a line→offset table; `slice-node` and `rewrite-source` each re-derive `(+ (get offs line) (- col 1))` | the rewriter and the LSP both reconstruct, per source, what an indexing reader knows for free; a span of line/col cannot slice bytes |
| **Errors are a bare message** | `syntax-error`; **FUP-102** — an unbalanced paren made `bl run` print *nothing* and exit 141, "the single most common mistake a person makes, and it is currently UNDIAGNOSABLE from the CLI" | `bl run` and `bl check` both fail silently; no repair loop; no mid-typing diagnostic; no way to say *which* paren is missing |
| **Batch only** | `read-forms*` loops to EOF and returns a list | streaming REPL, `bl watch` re-read of a changed prefix, and any "read what the model has written so far" harness loop |
| **`:read-cond` select-only** | `CONDITIONAL_FEATURE`, the missing-branch-reads-as-nothing rule | any formatter or rewriter over a `.cljc` file: the branches it did not take are **gone from the tree**, so they cannot be preserved in the text |
| **No auto-resolve** | resolution happens at compile time, in the compiler | a cold single-file pass over an unsaved buffer (LSP) cannot resolve `::alias/kw` without compiling the world |

None of these is a bug. Each is a *policy* that happens to be hard-coded in the
one place every consumer of the language has to go through.

---

## 4. Why not adopt edamame itself

Two independent reasons, either decisive:

1. **No JVM under the BEAM.** `edamame.impl.parser` requires
   `clojure.tools.reader.reader-types` and `clojure.tools.reader.edn`; the `:clj`
   lane is built on `java.io.PushbackReader`/`Reader`. `docs/babashka-compat.md`
   draws the line explicitly: no `java.io`, no Maven dependency, "a category
   boundary, not a gap to be closed". The `:cljd` shim proves a non-JVM host is
   *conceivable*, but it is a shim for ClojureDart, not for us.
2. **A second reader is a second truth.** Every consumer here — compiler, type
   checker, source-graph, deodorant, LSP, rewriter — already agrees on one node
   vocabulary that the language defines and documents. Adding edamame would mean
   two ways to read the same language, drifting.

---

## 5. What to take, in build order

Ranked by value over blast radius. Each item names what it *deletes* or
*unblocks* — the point of taking a contract is that something downstream gets
simpler.

### 5.1 Error data, and the position in the message  ← do this first

`syntax-error` should carry `{:line :col :file}` plus the open-collection state
— `{:edamame/expected-delimiter … :opened-delimiter … :opened-delimiter-loc …}`
in our own spelling — and the *message* should name the position, because the
CLI path loses the struct (FUP-102: the failure arrives as `:terminated`).

- **Deletes:** the `bl run` silence; FUP-102; half of `bl check`'s
  `unreadable (FILE)` with no diagnostic.
- **Unblocks:** a repair rung in the harness (`fix-expression`, ported); an LSP
  that can say "unclosed `(` opened at 3:7" while the user is still typing.
- **Acceptance:** an unbalanced file, `bl run FILE` → `FILE:12:34: unterminated
  collection, opened ( at 12:30`, exit 1. Today it prints nothing and exits 141.

### 5.2 Offsets in the span

Thread a running codepoint offset beside the position (`{:offset :end-offset}`
on the `{:meta …}` wrapper). The charlist scan already walks every character
once; the offset is an integer carried, not a second pass.

- **Deletes:** `span-rewrite`'s `line-offsets`, and the three copies of the
  line/col→offset arithmetic built on it.
- **Unblocks:** byte-exact slicing for Tool 1 and Tool 2 from one field; UTF-16
  conversion in the LSP has a source to convert *from*.

### 5.3 Span every collection, not just lists

Beam-lisp has no `IObj` metadata channel, so positions are a wrapper tuple and
"where do positions go" is a *choice*, not a type constraint. edamame makes that
choice a predicate defaulting to `seq?` for two reasons that do not apply here
(metadata is free on JVM collections; non-IObj values need `:postprocess`).
Our equivalent default is "lists only", inherited from a deleted shim.

- **Deletes:** the `has-span?` → `pr-str` fallback cliff in Tool 1.
- **Note the honest cost:** `{:meta …}` wrappers are visible to every consumer
  (`node-form` peels one layer), so widening the set changes tree shapes that
  `read_all` currently normalizes away. Do it as a *reader option*, defaulted to
  today's behaviour for the parse paths the compiler reads, on for tooling.

### 5.4 `read` takes an options map

One entry point; the three existing ones become aliases.

```
(read src {:file "a.bl"
          :location? :lists | :collections | :none
          :read-cond :select | :preserve
          :readers {...}          ; the dispatch table as data
          :read-eval false        ; the trust boundary, stated as a value
          :intern true})          ; the atom guard, stated as a value
```

- **Deletes:** `read-all` as a separate entry point; the "strip after the fact"
  step (`unwrap-deep`) for a caller that never wanted positions.
- **Unblocks:** a *restricted* read as the harness's admission contract —
  `trust-boundary.md`'s boundary stated in the reader instead of enforced
  afterwards; `:preserve` for the formatter/rewriter; a second reader mode for
  EDN-shaped data that must never intern a novel atom.

### 5.5 Reading is a stream

`(read-next reader)` / `(read-next+string reader)` over a reader value, both
returning the next form and the reader advanced (our `pos` threading already
models exactly this — the returned position is the unconsumed head).

- **Unblocks:** form-at-a-time REPL evaluation; `bl watch` re-reading a suffix;
  and the harness loop that reads what a model has written *so far* and reports
  diagnostics per complete form instead of refusing the whole buffer.

### 5.6 `:auto-resolve-ns`

Read the `ns` form, keep its alias table, resolve `::alias/kw` as the stream
goes. edamame's `parse-ns-form` is 40 lines.

- **Unblocks:** a cold, single-file LSP pass over an unsaved buffer.

Items 5.1 and 5.2 are small and delete code today. 5.3 is the one to argue
about (it changes the tree a compiler reads). 5.4–5.6 are the platform.

---

## 6. The other half of the answer: edamame as an oracle

The repo already pins behaviour to third parties rather than to its own
expectations — the decimal codec to 1051 `java.math.BigDecimal` rows, the Java
manifest to JVM-captured oracle rows, `bl.json` to two independent parsers. That
is the pattern for a reader: **it should be bounded by a reader we did not
write.**

edamame is the right oracle because it is *mature, widely used, and built into
`bb` on this host* — zero setup. `research/edamame/oracle.clj` runs in two modes:

```
bb research/edamame/oracle.clj rows         # EDN oracle rows for the case corpus
bb research/edamame/oracle.clj scan DIR…    # read every .bl under DIR; positioned diagnostics
```

`rows` emits, per case, either `{:ok true :forms "…"}` or
`{:ok false :error {:row :col :expected :opened :opened-loc}}` — the shape a
beam-lisp test can assert against. `scan` is the field tool.

### What `scan` found on this tree, today

237 `.bl` files under `priv/`, `lib/`, `spell/`, `bin/`; **14 refused, 0 unbalanced.**
Every refusal is a lexical rule where beam-lisp is *deliberately* more permissive
than an EDN reader, so each one is a *measurement*, not noise — exactly the rows
a conformance corpus has to encode, and the reason an oracle needs a dialect
profile rather than a bare `parse`:

| source | edamame | happens |
|---|---|---|
| `erlang/=/=` | `Invalid symbol` | Clojure's symbol rules reject `=/=` |
| `+1→inc` | `Invalid number` | a symbol starting `+` reads as a bad number to Clojure |
| `"\0BLOCK\0"` | `Invalid digit B in unicode character` | Erlang-style `\0` string escape |
| `"\("` | `Unsupported escape character` | Erlang-style escaped delimiter |
| `:"=<"` | `Invalid keyword` | a keyword named by a string literal |
| `::foo` | `Use :auto-resolve …` | a relative keyword needs an alias table |

Nothing in the tree is unbalanced. One file *was*, and that is §5.1's case:

```
priv/lib/web.bl — Unmatched delimiter: ) at 479:79
```

Verified independently of any reader (a string/comment/char-aware balance scan
over the tree): `priv/lib/web.bl:479` closes four more parens than it opens, and
it is the **only** production source in the tree that does not balance. The
tree's own build fails on it:

```
$ ./bl run examples/hello.bl
** (BeamLisp.Reader.SyntaxError) unexpected )
    (beam_lisp 0.1.0) .../priv/boot/reader.bl:16:...
```

— no file, no line, no column, four frames of reader internals. That is §5.1's
case, produced by the tree's own tooling, in this session. (A concurrent session
repaired `web.bl` later the same morning — the scan no longer flags anything —
which is *also* the point: the defect cost two people time, and neither the
compile error nor the CLI said which file or which line.)

---

## 7. Bold: the reader is the harness contract

FUP-003 says the *shape of a proposal* must be derived from the reader, because
the shape of a proposal is the language's own reasoning. Take that one step
further. A harness has three things to say to a model: **what you may write**,
**what you get back when it is wrong**, and **where it went wrong**. Today all
three live in hand-written artifacts — a JSON-Schema heredoc, an English refusal
message, and (usually) no position at all.

With the four contracts, all three are projections of one value:

- *what you may write* = the reader's options. A restricted read **is** the
  admission contract: which reader macros exist, whether tagged readers are
  live, whether `#=` is even a concept, whether a novel keyword may intern an
  atom. `trust-boundary.md`'s boundary stops being a policy enforced after the
  fact and becomes a property of the reader call.
- *what you get back* = structured error data, in the language's own vocabulary,
  rendered for the model by the same code that renders it for a human.
- *where* = the span, shared with the compiler, the type checker and the LSP, so
  "the model's error" and "the programmer's error" are the same object with the
  same caret.

And then the step that a JVM library cannot take: because the reader is *in the
language*, a repair is just a program. `fix-expression` closes a bracket; a more
interesting harness move reads the model's partial output **as a stream**,
compiles the forms that are complete, and answers with the diagnostics for the
ones that are not. The failure mode stops being "refused, try again" and becomes
"here is the tree so far, and here is the one thing missing."

That is the same shape as the rest of this tree — position lives in the IR,
proofs live in the IR, one channel for every reader — one layer up. The reader
is the first act of the harness, and edamame is the evidence that it can be
total, cheap, and a value.

---

## 8. Not claimed

- **No beam-lisp measurement of edamame.** edamame does not run here (§4), so
  every edamame number above is from `bb` on this host, and every beam-lisp
  claim is read from source, not timed. No cost figures are given for the
  proposed changes — none was measured.
- **The `scan` dialect profile is not a conformance suite.** The 14 refusals are
  classified by hand (§6); the script now *labels* the dialect cases it knows,
  but nothing yet compares the reader's *acceptances* tree-by-tree against the
  oracle, which is the half that would catch a silent mis-read.
- **`priv/lib/web.bl` was not fixed here** — a concurrent session repaired it,
  and the tree still does not build (the failure moved on to another file); that
  is their work, not this note's.
- **§5 items were not implemented in `priv/boot/reader.bl`.** A prototype of all
  four contracts exists, is written in beam-lisp, and runs
  (`research/reader-contracts/`), but the real reader is untouched: no file under
  `priv/` or `lib/` changed, and the port is unstarted. §5.1's `bl run` behaviour
  was observed before any change, on this tree.

## Reproduce

```
bb research/edamame/oracle.clj rows               # 16 rows, EDN: the four contracts
bb research/edamame/oracle.clj scan priv lib spell bin
# → "scan: 237 files read, 14 refused / unbalanced (a defect in the source): 0"
#   exits 1, and names the file and the span, the moment one does not balance.
```

The corpus asserts the *contracts*, so its rows are the acceptance criteria for
§5: `:expected`/`:opened`/`:opened-loc` for 5.1, `:locations` for 5.3, the
`:stream` pairs (form + its own source text) for 5.5, and `:read-cond-preserve`
/ `:read-eval-refused` / `:auto-resolve-ns` for 5.4 and 5.6. A beam-lisp test
reads those rows and asserts the self-hosted reader agrees — except on `:dialect`
rows, where it must assert the *difference*.
