# What "simpler" means

*A compiler that emits Core Erlang is about a third shorter than one that
emits Elixir quoted AST. That number is the least interesting part. This
document is about the kind of simplicity — what disappears, and what stays
exactly as hard.*

Read `how-beam-lisp-uses-elixir.md` first if "quoted AST" and "Core Erlang"
are new words. Short version: Elixir quoted is the tree the Elixir compiler
reads; Core Erlang is the tree the Erlang compiler reads, one stage lower.
beam-lisp's compiler emits a tree; which tree it emits decides how much of
the compiler is *the language* and how much is *encoding tricks for the
target*.

## Part 1 — five things that stop existing

### 1. Every special form is one Core constructor

Core Erlang has exactly one construct for each thing a Lisp does:

| beam-lisp form | Core construct | what it *is* |
|---|---|---|
| `let` | `c_let` | bind a name to a value, then a body |
| `loop` / `recur` | `c_letrec` + `c_apply` | a local recursive fun and a tail call to it |
| `if` · `cond` · `case` · pattern dispatch | `c_case` | choose a branch by matching |
| `fn` | `c_fun` | a closure |
| `(f x)` | `c_call` (known module) · `c_apply` (a fun value) | call |
| `try` / `catch` / `finally` | `c_try` | run, catch `<Class, Reason, Stack>` |
| `receive` | `c_receive` | wait for a matching message |
| `do` | `c_seq` | sequence |

Each row is a direct correspondence — no intermediate shape. So the compiler
for a special form is: compile the pieces, hand them to the constructor. `let`
is a fold of `c_let` over its bindings, twelve lines. `loop` is a `c_letrec`
whose fun's body compiles with `recur` meaning "apply the fun", thirty-five.

Elixir quoted has no `let` and no `letrec`. A compiler targeting it has to
*build* them: `let` becomes an immediately-applied anonymous function
(`(fn x -> body).(value)`, nested once per binding); `loop` becomes a fun that
receives itself as an argument so it can call itself (the "self-apply
scaffold"); `recur` needs two code paths, one for the scaffold and one for a
named `defn` where the BEAM can do a direct call. The scaffolds work. They are
also ~450 lines that describe the *target*, not the language.

With Core, the compiler reads as a specification: one `cond` arm per special
form, each arm a few constructor calls. What remains between the reader and
those arms is resolve (which name is this?) and macroexpand (what does this
form mean?). Resolve + macroexpand + a table.

### 2. Literal ambiguity vanishes

A literal value in a program — `{:a 1}`, `[1 :a "s"]`, a quoted form — must be
turned into *code that produces that value*. In Core Erlang there is one
function for this, `cerl:abstract/1`: give it any Erlang term, get a literal
node. A tuple is a tuple. A map is a map. A list of pairs is a list of pairs.

In Elixir quoted, the representation of a literal depends on its shape:

- a 2-tuple is written bare: `{:a, 1}` is itself the AST for the tuple `{:a, 1}`
- a tuple of any other size is a node: `{:{}, [], [:a, 1, 2]}`
- a list whose elements are 2-tuples with atom keys is a *keyword list*, which
  several constructs (`if`, `try`, `def`) read as their option syntax
- a value that must be stored *as data* rather than *run as code* (metadata,
  `quote`) goes through `Macro.escape/1` — which re-encodes every tuple inside
  it by the rules above
- a variable is `{name, meta, context}` — a 3-tuple, which is a valid *literal*
  tuple by rule one unless it is in a position where it reads as a variable

Every one of these is a place where a value and the code for that value can
be confused. A compiler targeting quoted AST must know, at each site, which of
the five it is producing. The genesis compiler's source carries the scars as
comments: *"a 2-tuple literal is a BARE tuple in Elixir AST, not a `{:{},[],…}`
node"* · *"`__STACKTRACE__` is a bare special variable, not a call"* · *"the
Kernel `apply/3` node carries the import metadata Elixir stamps"*. Each comment
marks a bug that was found by running.

Core has one rule. `cerl:abstract` takes the term. The class of bug does not
exist because the ambiguity that produced it does not exist.

### 3. Guards are a property, not a whitelist

A **guard** is a test on a clause head — `(defn f [x] {:when (pos? x)} …)` —
that the VM evaluates *before* entering the clause, without allocating and
without a stack frame. The BEAM permits only certain functions in guards:
those that cannot have side effects and cannot fail in a way that needs
unwinding (`is_integer`, `>`, `element`, `map_get`, arithmetic, …). This is a
property of a function: **guard-safe**.

Elixir exposes guards through a fixed list of `Kernel` macros. A compiler
targeting Elixir quoted inherits that list: a beam-lisp guard is compiled by
rewriting each predicate into whichever `Kernel` guard macro Elixir happens to
offer, and predicates without a counterpart cannot be guards at all.

Core Erlang exposes the property directly. A guard is a Core expression built
from guard-safe BIF calls; the compiler's linter checks the property. So the
question the beam-lisp compiler asks becomes *"is this BIF guard-safe?"* — a
predicate over a function name, answerable from a table beam-lisp owns. That
table is the same shape as `system.smt`'s translatable-fragment table (the
functions the prover understands); the two overlap almost entirely, because
"pure, total, cheap" is what both are looking for. Deciding guard-safety in
beam-lisp means the prover and the compiler agree on what a predicate is.

### 4. Tail calls are structural

The BEAM turns a call in **tail position** — the last thing a function does —
into a jump, so a loop written as recursion runs in constant stack. `recur` is
beam-lisp's word for "jump back to the start of this loop or fn".

In Core, `loop` is a `letrec`: a local fun bound by name in scope of its own
body. `recur` is `apply` of that name in tail position. The Erlang compiler
sees a tail self-call and emits the jump. There is nothing to arrange; the
shape *is* the guarantee.

Elixir quoted has no local named fun, so a compiler targeting it needs the
self-application scaffold (item 1) and, because scaffold calls are slower than
direct calls, a second path: a `defn` recurs by a direct `Module.name(args)`
call instead. Two representations of "jump", chosen by an environment flag
(`:self` versus `:self-call`), each with its own arity check. In Core there is
one.

### 5. No compiler-option juggling

The Elixir compiler runs passes designed for hand-written Elixir: type
signature inference, a whole-image undefined-function checker, module
redefinition warnings. On machine-generated code they cost without helping —
signature inference has measured at 93 seconds for one dense function (63 ms
without); the checker at 13 minutes for one namespace. A compiler targeting
Elixir quoted must switch them off at every compile site, reach for a private
compiler primitive to bypass the one that has no switch, and create a
throwaway module per evaluated form because Elixir has no "compile this
expression" entry point.

`compile:forms(Core, [from_core])` has none of these passes. There is nothing
to switch off. The only options are the ones every BEAM compiler shares
(`binary`, `return`), and evaluating one form is: wrap it in a fun named
`run/0`, compile, load, call. The Core path measures ~1.8× faster per module
than `Module.create` (`research/ce1_core_erlang/bench.bl`), and the speed is
the least of it: the *absence* of a knob is what makes the path uniform across
REPL, reload and AOT.

## Part 2 — five things that stay exactly as hard

Targeting Core changes the *lowering*. These are not lowering.

### Destructuring

`(let [{:keys [a b] :or {b 0} :as m} v] …)` binds three names from one map. In
beam-lisp a vector is a struct (`BeamLisp.Vector`), a map is a map with
hashed keys, and `nil` is a legal absent value with defaults — none of which a
Core pattern can express. So destructuring compiles, on any target, to a
sequence of *steps*: bind the whole to a temporary, then each name to
`RT.get(whole, key, default)` or `RT.nth(whole, i)`. The ~230 lines that
expand `:keys` / `:strs` / `:or` / `:as` / nested patterns into steps are the
language's semantics of binding. They emit the same steps for Core as for
quoted; only the constructor around each step changes.

### Namespace resolution, macros, hygiene, `ns`

*Which thing does this symbol name?* — a local, a var in this namespace, a var
in a required namespace under an alias, a linked runtime function, a host
module function, a private var that must be refused. *What does this form
mean?* — macroexpansion, syntax-quote, gensym hygiene, the `&form`/`&env`
protocol. *What does this file bring into scope?* — `ns` with `:require`
specs. This is the language. It runs before lowering and produces a tree
where every symbol is already resolved; the lowering reads that tree. Roughly
1200 lines, the same on every target.

### Protocols, multimethods, records, servers, natives

A `defprotocol` compiles to a call to `BeamLisp.Multi.define_protocol`. A
`defrecord` compiles to `BeamLisp.Record.define`. A `defserver` compiles to a
module with `@behaviour gen_server` and one fun per callback; the client
functions are calls into `BeamLisp.Server`. These are thin lowerings onto the
runtime library — the runtime does the work, the compiler names it. The
constructor changes (`ast-mod-call` becomes `c_call`); the shape does not.

### The oracle

A compiler is trusted by comparing it against something. The Elixir-quoted
compiler is compared against the genesis Elixir compiler *tree for tree*:
same input, same quoted output, 932 of 932 prelude forms. That comparison is
only possible because both produce the same kind of tree.

A Core compiler produces a different kind of tree. Its oracle is *value*
identity: the same form, evaluated through both backends, yields `=` values —
the gate in `research/ce1_core_erlang/ce1.bl`. This is the stronger claim (it
tests what the code *does*, not what it looks like) and it is the claim
`veritas.property` already makes about functions. But it is a different gate,
and it has to be carried to the whole prelude form by form, exactly as the
tree gate was. That work is not smaller because the compiler is.

### Error surface

Hand a malformed tree to Elixir and Elixir explains: *"undefined variable x"*,
*"invalid quoted expression"*, with a file and line. Hand malformed Core to
`compile:forms` and `core_lint` says `{pattern_mismatch, {run, 0}}` — which
function, what kind of mismatch, no line. For generated code this is fine; a
generated tree is either right or wrong in ways no message would clarify. But
when the *compiler itself* has a bug, the quoted target hands back a sentence
and the Core target hands back a tuple. Source positions must be stamped as
Core annotations (`cerl:set_ann`) by the compiler, deliberately, to get them
back in errors — one more thing the compiler owns rather than inherits.

## The shape of the trade

Part 1 is the target-encoding layer: ~1050 lines of scaffolds, literal rules,
inherited whitelists, dual code paths and option juggling, collapsing into
~350 lines of one-to-one constructor calls. Part 2 is the language: ~1700
lines, unchanged, plus an oracle rebuilt on values and an error surface the
compiler must furnish itself.

The compiler gets shorter. More importantly it gets *legible*: what is left
is a description of beam-lisp, with the target reduced to a table.
