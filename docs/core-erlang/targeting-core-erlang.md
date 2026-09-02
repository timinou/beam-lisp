# Targeting Core Erlang

*How beam-lisp would emit Core Erlang instead of Elixir quoted AST, what that
buys, and the `.bl` modules it would grow. Companion to
`how-beam-lisp-uses-elixir.md`.*

## 1. What ANF is

**A-normal form** (administrative normal form) is a way of writing programs
where **every argument of every operation is trivial** — a variable or a
literal — and every non-trivial computation is bound to a name first.

Ordinary expression:

```clojure
(f (g x) (h (k y)))
```

The same program in ANF:

```clojure
(let [t1 (g x)]
  (let [t2 (k y)]
    (let [t3 (h t2)]
      (f t1 t3))))
```

Nothing is nested inside a call. The order of evaluation is now *written
down*: `g` before `k` before `h` before `f`. Three consequences follow, and
they are the whole reason compilers use ANF:

1. **Every intermediate value has a name.** An analysis (type, effect,
   liveness, escape) attaches facts to names; in ANF there is nothing
   anonymous left to attach facts to.
2. **Control flow is explicit.** `let` sequences and `case` branches are the
   only shapes. There is no "evaluate the arguments in some order the
   language leaves unspecified".
3. **Transformations are local.** Inlining `h` means substituting its body for
   `(h t2)` — the arguments are already variables, so no capture or
   duplication of work can happen.

ANF is what a lisp program looks like after `let`-hoisting every subexpression.
For a lisp, going to ANF is not a change of language; it is a change of
*discipline* that the compiler can impose mechanically.

## 2. Core Erlang is ANF-ish

Core Erlang is the intermediate language of the Erlang compiler
(`erlc +to_core` prints it; `compile:forms(Core, [from_core])` consumes it).
It is a small, strict, lexically-scoped functional language with:

```
module · fun · apply · call (remote) · primop · let · letrec · case · receive
try · catch · do (sequence) · literals · tuples · lists · maps · binaries
```

Its shape is ANF-*ish*, not strict ANF: nested calls are allowed syntactically,
but the compiler's own first pass (`sys_core_fold` → `v3_kernel`) hoists them,
and `v3_core` — the pass that turns Erlang into Core — emits let-bound
intermediates. In practice, hand-emitted Core that is already ANF is what the
optimizer wants: every let binds one value, every `case` scrutinises a
variable, every call's arguments are variables or literals.

Why this fits a lisp compiler unusually well:

| Core Erlang construct | beam-lisp special form | note |
|---|---|---|
| `let <X> = e1 in e2` | `let` (one binding) | bl `let` with n bindings = n nested Core lets |
| `letrec 'f'/1 = fun … in …` | local recursive `fn`, `loop`/`recur` | `recur` is a self-call in tail position — Core has no loop, it has tail calls |
| `case <X> of <pat> when <guard> -> … end` | `case`, `cond`, `if`, destructuring, guard clauses | one construct covers everything that branches |
| `fun (X, Y) -> …` | `fn` | closures are values; captured vars are free vars |
| `apply F (A, B)` | calling a fn value | |
| `call 'mod':'f' (A)` | interop, `RT` calls | the whole of role B |
| `receive <pat> when <g> -> … after <t> -> … end` | `receive` | |
| `try e of <v> -> … catch <k, r> -> … end` | `try`/`catch`/`throw` | |
| `primop 'match_fail' (…)` | clause fall-through | |
| `do e1 e2` | `do` | |

There is no `cond`, no `if`, no `when` outside `case` clauses, no macros, no
aliases, no attributes beyond a flat list, no strings (binaries and charlists
only). Everything Elixir's expander does — alias resolution, import lookup,
macro expansion, `Kernel` special-form rewriting — is absent because the input
is already resolved. **Core Erlang is what Elixir quoted becomes after Elixir
has finished thinking about it.**

## 3. The emit rewrite

The change is confined to the **lowering** step of `priv/boot/compiler.bl` and the
**module topology** of `emit.ex`. Reader, macroexpansion, analysis, the
shim/body split, AOT caching, the loader — untouched in concept.

### 3.1 Today: two passes fused

`compiler.bl` walks a bl form and directly builds Elixir quoted tuples:
`(ast-node :case …)`, `(ast-alias …)`, `Macro/escape`. Analysis (resolve a
symbol, choose a clause shape) and lowering (build the tuple) happen in the
same function. That is fine when the target is a syntax tree that closely
mirrors the source — Elixir quoted is one.

### 3.1b The short path — verified (`research/ce1_core_erlang/`)

The compiler's emitted quoted tree is *already* the IR described below: every
symbol resolved, every macro expanded, a closed vocabulary of ~16 node kinds
with one-line Core counterparts. A ~600-line `.bl` reader of that tree
(`ce1/lower` + module topology) drives `cerl` directly. Verified: 7582
prelude/example forms lower with none rejected; six test suites (142 tests,
583 assertions) run through the Core backend with zero divergence from the
Elixir backend; `defn`, `defserver` and `Link.defvar` (body + shim modules,
closure survival across redefinition) all work in Core; module builds are
1.7–2.0× faster than `Module.create`. The three-pass design below remains the
*destination* (a bl-owned ANF the toolbench reads); the short path is how to
get a working Core backend first, with the same def-tuple seam and no
compiler rewrite. The cutover recipe is in the spike's README.

### 3.2 With Core: three passes, one IR

```
bl form ──analyse──▶ resolved bl ──normalise──▶ bl-ANF ──lower──▶ Core Erlang (cerl)
           (exists)                 (new)                  (new, replaces emit)
```

**bl-ANF** is a beam-lisp data structure: bl forms with every subexpression
let-bound and every symbol resolved to one of `{:local var}`, `{:var ns name}`,
`{:remote mod fun}`, `{:literal v}`. It is small (≈12 node kinds) and it is
*the* IR: typed, footprint, system.model, the optimizer queries all read it.

**Lowering** is then a fold over bl-ANF into `cerl` records (Erlang's Core AST,
`cerl:c_let/3`, `cerl:c_case/2`, `cerl:c_call/3`, `cerl:c_fun/2`, …), built via
`erlang/`-style interop from `.bl`. `cerl` is a public OTP library; the terms it
produces are consumed by `compile:forms/2` with `[from_core, binary, return]`.
Nothing else is needed to get a `.beam` binary.

### 3.3 Module topology stays

`emit.ex`'s invariant — real code in a never-reloaded **body module**, thin
**shims** in the namespace module — survives verbatim. A shim in Core is:

```
'f'/2 = fun (A, B) -> call 'Elixir.BeamLisp.Ns.Fn.M123':'f'(A, B)
```

Guarded shims carry the guard exactly as today (`emit.ex` explains why: clause
selection happens where the caller enters). The module names keep their
`Elixir.` prefix so stack frames, tests and interop see no change.

### 3.4 What is deleted, what is added

| gone | added |
|---|---|
| Elixir quoted node construction throughout `compiler.bl` | `priv/self/anf.bl` — normaliser |
| `Macro.escape` (literals are Core literals) | `priv/self/cerl.bl` — bl-ANF → cerl |
| `Module.create`, `:elixir_compiler.quoted`, `Code.compiler_options` juggling, `infer_signatures: false`, `ignore_module_conflict` | `compile:forms/2` + `code:load_binary/3` |
| alias/require emission | — (atoms) |
| the Elixir expander, `Module.Types`, `ParallelChecker` from the hot path | — |
| the differential oracle *on trees* (`priv/self/oracle.bl`) | a differential oracle *on values*: run both backends, compare results |

The oracle change is the one real cost. The 932/932 tree-identity gate is
Elixir-shaped; a Core backend needs a **behavioural** oracle: the same form
evaluated through both pipelines yields equal values (and equal *effects*, via
`footprint`). This is a stronger guarantee than tree identity and the
machinery already exists — `veritas.property` runs functions and asserts over
their outputs.

## 4. What Core enables

Each item is a consequence of owning the lowering, not of any cleverness.

**Compile latency on the reload path.** Every `def` at the REPL and every
hot-reload today runs the Elixir expander and `Module.create`. Core skips two
compiler stages (expand, erl-translate) and their bookkeeping. This is where
the 93 s / 63 ms and 13-minute incidents live; a Core path cannot have them
because the passes that caused them are not present.

**One IR for the whole toolbench.** `typed`, `footprint`, `system.model`,
`codebase`, `termination`, the sh12b optimizer queries each read source
today, re-deriving structure. bl-ANF gives them one resolved, named,
control-flow-explicit form. Facts in `codebase` become facts about ANF
names — "this let-bound value is never used", "this call's receiver is a
literal atom" — and the optimizer's rewrites become optics over bl-ANF that
the lowering consumes unchanged.

**Guards become first-class.** Elixir restricts guard expressions to a
whitelist and beam-lisp inherits it through emission. Core exposes the real
constraint (guard-safe BIFs) directly, so bl can decide, per predicate, whether
a `system.smt`-translatable predicate is also a *guard*, and lower it as one.
Guards run without allocation and without a stack frame.

**Pattern compilation is ours.** bl destructuring today lowers to Elixir
patterns, which Elixir then compiles to decision trees. With Core, bl compiles
match clauses to `case` trees itself — and `typed`'s clause-reachability
warnings, `system.core`'s coverage proofs and the *emitted* decision tree come
from the same clause analysis. A proven-exhaustive `case` needs no
`match_fail` branch.

**Representation decisions land in the lowering.** A `state-shape` proven fixed
lowers a record to a tuple; a value proven read-only-shared lowers to
`persistent_term:get`; a string proven append-only stays an iolist. These are
one-line choices in `cerl.bl` once the proofs exist (see the Q2 discussion in
the session that produced this document — memory policy as compiler output).

**Debug information is ours.** Core carries annotations per node
(`cerl:set_ann`). Line numbers, source spans, *and* arbitrary facts (the
footprint of this call, the proof that guarded this clause) can be stamped
onto the emitted code and read back from the `.beam`'s abstract chunk or a
custom chunk — the running system becomes queryable about *why* each
instruction is what it is.

**No Elixir version coupling for the language.** Elixir's compiler internals
(`:elixir_compiler.quoted/3`, the `infer_signatures` flag) are private and have
already moved under us once. `cerl` and `compile:forms` are stable public OTP
APIs with decades of history. The OTP host (role C) still depends on Elixir;
the *language* stops doing so.

## 5. The `.bl` modules this grows

All in-house, all in `.bl`, all reading and writing plain data. They live in
`priv/self/` (the compiler's own tier, beside `oracle.bl`) until the cutover,
when `anf`/`match`/`guard`/`cerl`/`beam` move into `priv/boot/` — they become
the toolchain closure — and `oracle`/`opt` stay in `self/`:

| module | job | reads | writes |
|---|---|---|---|
| `self.anf` | let-hoist, resolve symbols, name intermediates | resolved bl forms | bl-ANF |
| `self.match` | clause list → decision tree; exhaustiveness/redundancy facts | bl-ANF `case` | bl-ANF `case` (nested) + facts for `typed` |
| `self.guard` | decide guard-safety of a predicate; lower to guard or to body test | bl-ANF, `system.smt` vocabulary | bl-ANF with `:guard` annotations |
| `self.cerl` | bl-ANF → `cerl` terms; annotations | bl-ANF | Core Erlang |
| `self.beam` | `compile:forms`, load, purge; the shim/body topology (port of `emit.ex`) | Core Erlang | `.beam` binaries |
| `self.oracle` | behavioural differential: eval via both backends, compare values + footprints | forms | verdicts |
| `self.opt` | the sh12b optimizer, as optics over bl-ANF driven by `codebase` queries | bl-ANF + datom | bl-ANF |

Each is a pure function of data to data except `self.beam`, which is the one
effectful edge (load a binary). That is the same "deliberately close to pure"
shape `emit.ex` has today, moved into the language.

## 6. Why this extends the maximalist approach

beam-lisp's thesis is that the language, the harness, the runtime and the
application are one thing — each is data the others reason about. Today that
holds for everything *above* the compiler's output: `codebase` indexes the
compiler, `typed` checks it, `system` proves servers written in it. It stops
at the emitted Elixir tree, which is opaque to every bl tool.

Owning the lowering pushes the thesis one level down:

- **Compiled code becomes queryable data.** bl-ANF is a datom relation like any
  other. "Which emitted `case` has a `match_fail` branch?" "Which calls cross
  a namespace with a non-empty `:W` footprint?" are datalog, answered over the
  *actual* code that will run — not over source that approximates it.
- **Proofs become code shape.** Today a proof produces a verdict; with the
  lowering in-house it produces a *different program*: a dropped branch, a
  guard instead of a body test, a tuple instead of a map. The proof is the
  optimisation.
- **The compiler is a live, hot-reloadable bl namespace like the rest.**
  Improving pattern compilation is `(def match/compile …)` at the REPL,
  gated by the behavioural oracle on the whole prelude — the same loop every
  other bl feature enjoys.
- **The self-hosting fixpoint tightens.** Today: bl compiles bl into Elixir,
  which Elixir compiles. With Core: bl compiles bl into Core, which the
  Erlang compiler — a fixed, stable, public artifact — turns into bytecode.
  The only thing outside the language is OTP itself.

## 7. Boundaries

This document is a design, not a status report. It prescribes:

- a `research/` spike gate before any cutover: the behavioural oracle green on
  the full prelude, and a measured reload-latency delta on the REPL path;
- role B (`lib/beam_lisp/rt.ex` and friends) untouched — the backend and the
  substrate are separate decisions under separate rules;
- the shim/body topology preserved exactly, since the BEAM's two-version purge
  behaviour does not care which compiler produced the module.
