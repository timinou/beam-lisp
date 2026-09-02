# How beam-lisp uses Elixir

*Zero-context primer. Read this before `targeting-core-erlang.md`.*

Elixir plays **three roles** in beam-lisp. They look alike from the outside
("it's all Elixir modules") but they are different kinds of dependency, and
only one of them is a dependency on the Elixir *compiler*. Keeping the three
apart is what makes the question "could we compile directly to BEAM?" answerable
at all.

```
role                what it is                       replaceable?
──────────────────  ───────────────────────────────  ─────────────────────────
A. backend          bl AST → Elixir quoted → .beam   yes — this is the topic
B. runtime library  BeamLisp.RT / Vector / Env …     independent of A
C. OTP host         application, supervisor, mix     no, and correctly so
```

## The pipeline as it runs today

```
"(defn f [x] (inc x))"
   │  reader.bl                          text → reader nodes (data, with positions)
   ▼
 bl AST
   │  compiler.bl                        special forms → Elixir QUOTED AST
   ▼                                     {:def, meta, [{:f, [], [x]}, [do: …]]}
 Elixir quoted
   │  Module.create / :elixir_compiler.quoted      ← role A starts here
   │    elixir_expand      resolves aliases/imports/requires, expands Elixir macros
   │    Module.Types       Elixir's type inference over the emitted code
   │    elixir_erl         quoted → Erlang abstract format
   ▼
 Erlang abstract format
   │  :compile.forms                     erl_lint → v3_core
   ▼
 Core Erlang                             ← the layer targeting-core-erlang.md aims at
   │  sys_core_fold → v3_kernel → beam_ssa (type opt, alloc opt) → beam_validator → beam_asm
   ▼
 .beam  (JIT'd by the VM on load)
```

Everything from "Elixir quoted" to "Erlang abstract format" is Elixir's
compiler doing work on machine-generated code. Everything below Core Erlang is
Erlang's compiler and stays no matter what frontend feeds it.

## Role A — Elixir as compiler backend (the semantic dependency)

`compiler.bl` does not emit BEAM; it emits Elixir **syntax** and asks Elixir to
mean it. That is a dependency on Elixir's *semantics*: the meaning of every
node the compiler emits is defined by the Elixir language, not by beam-lisp.

Counted over `priv/boot/compiler.bl`, the emitted node vocabulary is small:

| Elixir node | count | what beam-lisp uses it for |
|---|---|---|
| `:else` / `:do` / `:when` | 35 / 15 / 23 | clause bodies and guards |
| `:__block__` | 19 | sequencing |
| `:__aliases__` | 8 | naming modules (`BeamLisp.RT`, `GenServer`) |
| `:require` / `:alias` | 7 / 1 | making a module name resolvable |
| `:fn` | 7 | closures |
| `:def` | 5 | the shim/body topology (`emit.ex`) |
| `:try` / `:after` / `:catch` / `:throw` / `:raise` | 2 / 3 / 1 / 2 / 1 | `try`, `throw` |
| `:case` / `:cond` / `:receive` | 2 / 1 / 1 | branching, `receive` |
| `:__MODULE__` | 1 | defserver self-reference |
| `Macro.escape` | 7 | turning a literal *value* into a literal *AST node* |

Plus one module attribute: `@behaviour :gen_server` on a `defserver` module.

Three observations about this table:

1. **Every node has a direct Core Erlang counterpart** except `:cond`, `:raise`
   and `:__aliases__`/`:require`/`:alias`. `cond` is nested `case`; `raise` is
   `erlang:error/1` on an exception map; alias resolution disappears entirely
   because Core names modules by atom.
2. **Nothing Elixir-specific is used as a *language feature*.** No Elixir
   macros are emitted for the user, no `with`, no `for`, no `defstruct` from
   generated code, no string interpolation, no protocol *definitions* in
   emitted code. beam-lisp implements its own macros, protocols, multimethods
   and records in beam-lisp + role-B library calls.
3. **Elixir's compiler adds cost without adding meaning.** The type-inference
   pass (`Module.Types`) is explicitly disabled in both `emit.ex` and `aot.ex`
   (`infer_signatures: false`) because it costs orders of magnitude more than
   the rest of compilation on generated code — 93 s with, 63 ms without, on one
   dense `defn`. `aot.ex` bypasses `Code.compile_quoted/2` for the primitive
   `:elixir_compiler.quoted/3` to avoid `Module.ParallelChecker`, which spun for
   13+ minutes verifying a generated namespace against every loaded module. The
   checks are for hand-written Elixir; generated code is correct by construction
   or wrong in ways they cannot see.

So role A is: **the emitted vocabulary is a lisp-shaped subset of Elixir that
Elixir then translates — with linear extra passes — into what Core Erlang says
directly.**

## Role B — Elixir as runtime library (straight function calls)

The other face of Elixir in beam-lisp is plain remote calls: `Module.fun(args)`
in emitted code, `Module/fun` in source. These are **not** a dependency on the
Elixir compiler. A call to `BeamLisp.RT.first/1` is `call
'Elixir.BeamLisp.RT':'first'(X)` in Core Erlang, byte-for-byte the same BEAM
instruction whether the caller is compiled by Elixir, Erlang, or beam-lisp.

The library surface, by module (`lib/beam_lisp/`):

| module | role |
|---|---|
| `rt.ex` (335 defs) | the substrate: `first`, `get`, `invoke`, `hash`, seq ops. Hottest path; `first` is called 140× by the compiler itself |
| `vector.ex` / `set.ex` / `sorted.ex` / `lazy_seq.ex` / `transient.ex` | persistent data structures. Each is an Elixir struct with `Enumerable` (and `Inspect`) implementations so bl values flow through `Enum`, `IO.inspect`, interop |
| `record.ex` | `defrecord` → a `defstruct` module (so records ARE Elixir structs — interop sugar) |
| `multi.ex` | multimethods + bl protocols (bl's own dispatch, not Elixir protocols) |
| `server.ex` | `defserver` start/stop wrappers routing around `GenServer` |
| `env.ex` / `link.ex` / `refs.ex` / `atom_guard.ex` | namespaces, var linking, heap/caps bounds, atom-table guard |
| `reader.ex` / `compiler.ex` / `emit.ex` / `aot.ex` / `loader.ex` | the *Elixir* reader/compiler (oracle + seed) and module topology |

The `.bl` side is tiered under `priv/`: `boot/` (reader-node, reader, compiler,
core, sugar, data-readers — the toolchain closure), `std/` (typed, codebase,
termination, reload, …), `lib/` (datom, system, veritas, auth, …), `self/`
(the compiler's own oracle). Role A lives entirely in `priv/boot/compiler.bl`
plus `lib/beam_lisp/emit.ex`.

Two facts about role B matter for any backend discussion:

- **It is target-agnostic.** Swapping the backend does not touch it. Whether
  each module later migrates to `.bl` is governed by the substrate floor rule
  (migrate only if `.bl`-expressible without a benchmarked perf loss) — a
  separate decision from the backend.
- **It is where Elixir *interop sugar* lives.** `%BeamLisp.Vector{}` being a
  struct with `Enumerable` is what lets `Enum.map(bl_vector, f)` work from
  Elixir. This is a property of the *value representation*, defined once in
  `lib/`, not of the code that produces the value. A Core backend emits the
  same maps with the same `__struct__` key and gets the same interop for free.

User-level interop is role B too: `(String/split s ",")` in a `.bl` file is a
remote call. `core.bl` uses ~30 such calls (`String/*`, `Map/delete`,
`Enum/to_list`) alongside ~20 `erlang/*` calls. All survive any backend.

## Role C — Elixir as OTP host

`application.ex`, `supervisor.ex`, the `mix beam_lisp.*` tasks, `escript.build`,
`mix release`, the `drop` bundler's payload. This is the process that *runs*
the language — exactly as Clojure keeps a JVM launcher. It has no opinion on
how `.beam` files are produced and is not part of the language.

## The one-line summary

beam-lisp depends on Elixir **semantically** in exactly one place: the moment
`compiler.bl`'s output is handed to `Module.create`. Every other use of Elixir
is a remote function call (role B) or the process that boots the VM (role C).
Replacing role A leaves B and C untouched — that is what makes a Core Erlang
backend a bounded, not a total, rewrite.
