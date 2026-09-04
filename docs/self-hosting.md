# Self-hosting beam-lisp

*How the language is written in itself — from zero context.*

## What "self-hosting" means here

beam-lisp is a Lisp on the BEAM (the Erlang virtual machine). You write
Clojure-shaped code — `(map inc [1 2 3])` — and it runs with Erlang's processes,
supervision, and hot code loading underneath.

The machinery that turns your beam-lisp text into a running program is itself
written in beam-lisp:

- the **reader** (text → data) is `priv/boot/reader.bl`
- the **compiler** (data → Core Erlang → BEAM bytecode) is `priv/boot/compiler.bl`

They are beam-lisp programs that read and compile beam-lisp. There is no Elixir
compiler or reader for the language — the code you edit to change how the
language works is `.bl`.

## The path from source to bytecode

```
source text
   │  reader.bl            (text → reader forms)
   ▼
reader forms
   │  compiler.bl          (forms → bl-ANF, a small neutral IR)
   ▼
bl-ANF
   │  self/core.bl         (bl-ANF → Core Erlang)
   ▼
Core Erlang
   │  :compile.forms       (Core Erlang → .beam)  ← an Erlang/OTP stdlib call
   ▼
BEAM bytecode
```

Every arrow except the last is beam-lisp source. The last arrow is the BEAM's
own code generator, reached through one Erlang stdlib call — that IS the native
backend, and reusing it is the whole point (beam-lisp writes the missing middle,
not a new machine-code emitter).

Core Erlang is the target because it is the BEAM's simplest real input: a tiny,
well-specified functional core the Erlang compiler accepts directly. The same
bl-ANF middle is designed to feed other backends later (an MLIR/LLVM path)
without touching the compiler front end.

## What stays Elixir, and why that is correct

Not everything is beam-lisp, and that is the design, not a compromise:

- **The final code generator** — `:compile.forms` / the Erlang compiler — turns
  Core Erlang into bytecode. It is the BEAM's compiler; rewriting it would delete
  the thesis.
- **The OTP host** — the application, supervisor, and `mix` tasks that start the
  VM — is the process that *runs* the language, not the language, exactly as
  Clojure keeps a JVM launcher.
- **The runtime substrate** — the `rt` primitives and the persistent `Vector`,
  `Set`, `Env` — is benchmark-exempt substrate the compiler leans on for speed
  (`first` runs on the hottest path). It migrates only if a `.bl` version is as
  fast, so it stays until a benchmark earns the move.
- **A thin facade** — `lib/beam_lisp/compiler.ex` and `reader.ex` are ~230 lines
  total, holding no compiler logic. They keep the well-known module names
  (`BeamLisp.Compiler.eval_string/3`, `BeamLisp.Reader.read_one/1`) that host
  code calls, map the reader's errors onto host exception types, and run the
  boot step. Every entry point delegates straight to `BeamLisp.Ns.Compiler` /
  `BeamLisp.Ns.Reader`, the modules compiled from the `.bl` source.

So the floor is: one Erlang stdlib call + Erlang/OTP + the runtime substrate + a
name-keeping shell. Nothing about the *language* lives in Elixir.

## The seed: how a language compiles itself

There is one irreducible circularity: you cannot compile `compiler.bl` without a
compiler, or read `reader.bl` without a reader. Every self-hosting language
breaks it the same way — with a **checked-in compiled artifact**, the seed.

The seed is `priv/bootstrap/seed/`: the whole `priv/boot` toolchain
(compiler, reader, reader-node, core, sugar, the build system) as Core-Erlang
`.beam` files, plus a manifest of their hashes and the toolchain key they were
built under. It is committed to git, and it is byte-reproducible — a fresh build
of the current source produces exactly these bytes.

At boot, `BeamLisp.Bootstrap` copies the seed into the build's code path and the
language interns it from those bytes — no compile, no bootstrap language. From
there the toolchain is live and rebuilds everything else.

### Editing the compiler: the staging ladder

When you edit `compiler.bl` (or any boot source), its toolchain key changes, so
the committed seed no longer matches. That is fine: the seed is still a *working
compiler of the previous generation*, and a self-hosting compiler is
bootstrapped by the previous generation of itself. `Bootstrap.install!` STAGES
the seed — installs it as gen-N — and the build uses it to compile your edited
gen-N+1 source into fresh, correctly-keyed beams that supersede it.

To bless a new generation as the committed floor, rebuild and regenerate:

```
mix compile.beam_lisp
mix run priv/bootstrap/gen_manifest.exs   # copies the fresh boot beams → seed/
```

Git history is the ultimate recovery floor: any past seed is a `git checkout`
away.

## Backends: Core Erlang by default

`:aot_backend` selects how a namespace's functions are lowered:

- `:core` (default) — bl-ANF → Core Erlang → `.beam`. No Elixir compiler on the
  path. Proven reproducible and behaviourally identical to the Elixir path.
- `:elixir` — the legacy path via Elixir's AST. Kept available with
  `config :beam_lisp, :aot_backend, :elixir`.

A Core-built beam and an Elixir-built beam of the same source get different
toolchain keys, so the AOT cache never serves one for the other.

## Packaging

`mix release` is the one supported packaging tier, wrapped by `mix bl.build`
(which also packs the native tier into a self-extracting `bl` drop). An escript
is deliberately not built: it is a single BEAM archive with no way to carry
native artifacts (the `defnative` Rust NIFs, z3, Explorer), so it can never
package a full beam-lisp.

## The mind-blowing part: the compiler is a program the language reasons about

Because the compiler is beam-lisp source, the language's own tools consume it:

- `codebase` indexes `compiler.bl` into a datom database; *"what breaks if I
  change `compile-body`?"* is a datalog query over its callers
  (`examples/self/compiler-as-codebase.bl`).
- Optimizer questions become datalog queries over the program-as-facts:
  functions called once (inline candidates), functions never called (dead code).
- AST passes (line-stamping) are optics traversals — `path + transform`,
  composable, not hand-rolled recursion.

## In one sentence

beam-lisp's reader and compiler are beam-lisp programs that lower the language
to Core Erlang, boot from a byte-reproducible committed seed, bootstrap each new
edit from the previous seed generation, and are analyzed by the language's own
tools — with Erlang/OTP kept, on purpose, as the final Core-Erlang→BEAM step and
the host.
