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
A. backend          bl AST → Core Erlang → .beam     replaced — Core is default
B. runtime library  BeamLisp.RT / Vector / Env …     independent of A
C. OTP host         application, supervisor, mix     no, and correctly so
```

## The pipeline as it runs today

The default backend is Core Erlang — no Elixir compiler on the path:

```
"(defn f [x] (inc x))"
   │  reader.bl                          text → reader nodes (data, with positions)
   ▼
 reader forms
   │  compiler.bl                        special forms → bl-ANF (a small neutral IR)
   ▼
 bl-ANF
   │  self/core.bl                       bl-ANF → Core Erlang
   ▼
 Core Erlang                             the BEAM's simplest real input
   │  :compile.forms                     ← Erlang stdlib; the only backend call
   │  sys_core_fold → v3_kernel → beam_ssa (type opt, alloc opt) → beam_validator → beam_asm
   ▼
 .beam  (JIT'd by the VM on load)
```

Everything above Core Erlang is beam-lisp source. Everything from
`:compile.forms` down is Erlang's own compiler and stays no matter what
frontend feeds it. (An opt-in legacy path, `:aot_backend :elixir`, lowers
bl-ANF through Elixir's quoted AST instead — kept for comparison, not the
default.)

## Role A — the compiler backend

The backend is the layer that turns the compiler's output into a `.beam`. By
default it is beam-lisp: `compiler.bl` emits **bl-ANF**, and `self/core.bl`
lowers that to **Core Erlang**, which the Erlang stdlib compiles. No Elixir
compiler is involved.

The **opt-in legacy path** (`:aot_backend :elixir`) instead has the front end
emit Elixir **syntax** and asks Elixir to mean it — a dependency on Elixir's
*semantics*. It is kept for comparison and is what the rest of this section
describes, because understanding what that path emitted is what made the Core
Erlang target a bounded rewrite. The emitted-node vocabulary was small, which is
exactly why replacing it was tractable:

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
| `emit.ex` / `aot.ex` / `link.ex` / `loader.ex` | module topology, AOT cache/drift gate, var linking, the loader |
| `reader.ex` / `compiler.ex` | ~230-line FACADES: they hold no compiler logic, just the well-known host names delegating to `BeamLisp.Ns.Reader` / `BeamLisp.Ns.Compiler`, error-type mapping, and the boot step |

The `.bl` side is tiered under `priv/`: `boot/` (reader-node, reader, compiler,
core, sugar, data-readers — the toolchain closure), `std/` (typed, codebase,
termination, reload, …), `lib/` (datom, system, veritas, auth, …), `self/`
(`core.bl` — bl-ANF → Core Erlang; `anf.bl` — the neutral IR). Role A lives
entirely in `priv/boot/compiler.bl` (front end) plus `priv/self/core.bl` (the
Core Erlang backend).

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

`application.ex`, `supervisor.ex`, the `mix beam_lisp.*` tasks,
`mix release` (the sole packaging tier), the `drop` bundler's payload. This is the process that *runs*
the language — exactly as Clojure keeps a JVM launcher. It has no opinion on
how `.beam` files are produced and is not part of the language.

## The one-line summary

beam-lisp no longer depends on the Elixir **compiler** at all by default:
`compiler.bl` lowers to bl-ANF, `self/core.bl` lowers that to Core Erlang, and
the Erlang stdlib turns Core Erlang into a `.beam`. The only remaining semantic
Elixir is role B (runtime remote calls) and role C (the OTP host). Role A —
once "bl AST → Elixir quoted → Module.create" — has been replaced; the Elixir
AST path survives solely as an opt-in (`config :beam_lisp, :aot_backend,
:elixir`).
