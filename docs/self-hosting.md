# Self-hosting beam-lisp

*How the language came to be written in itself — from zero context.*

## What "self-hosting" means here

beam-lisp is a Lisp that runs on the BEAM (the Erlang virtual machine). You
write Clojure-shaped code — `(map inc [1 2 3])` — and it runs with Erlang's
processes, supervision, and hot code loading underneath.

Originally, the machinery that turned your beam-lisp text into a running program
was written in **Elixir**: a *reader* (text → data) and a *compiler* (data →
Elixir syntax tree, which Elixir then turns into BEAM bytecode). So the language
was described in a different language.

Self-hosting means: **that machinery is now written in beam-lisp itself.** The
reader is `priv/boot/reader.bl`. The compiler is `priv/boot/compiler.bl`. They are
beam-lisp programs that read and compile beam-lisp.

## What stays Elixir, and why that is correct

Not everything leaves Elixir, and that is the design, not a compromise:

- **The final lowering** — turning the Elixir syntax tree the compiler produces
  into actual bytecode — is `Code.eval_quoted`, an Elixir standard-library call.
  We keep it deliberately. It IS the BEAM's compiler; rewriting it would delete
  the project's whole thesis (that Elixir's compiler is already a native-code
  backend with a homoiconic AST, so beam-lisp only needs the missing middle).
- **The OTP host** — the application, supervisor, and `mix` tasks that start the
  VM — stays Elixir. That is the process that *runs* the language, not the
  language, exactly as Clojure keeps a JVM launcher.
- **A frozen `.beam` seed** — the AOT-compiled reader+compiler — breaks the
  one irreducible circularity: you cannot read the reader without a reader, or
  compile the compiler without a compiler. Every self-hosted language ships a
  seed. Ours is `Elixir.BeamLisp.Ns.Compiler.beam`, built on every `mix`
  compile.

So the floor is: one stdlib call + Erlang/OTP + a build artifact. Nothing about
the *language* is maintained in Elixir.

## How it was built: prototype by prototype, graded by an oracle

The old Elixir compiler still works, so it is the **answer key**. Every piece of
the new compiler was checked by feeding the same input to both and asserting
they produce the **same Elixir syntax tree**. This "differential oracle"
(`priv/self/oracle.bl`) gated every step, so a mistake failed a check instead of
shipping.

The build climbed one feature at a time (each with a runnable gate under
`research/shN_*/`):

| step | what it added |
|---|---|
| P0 | the seed round-trips: a tiny `.bl` compiler runs in a bare `erl` VM |
| P1 | the shared "what is a form" vocabulary (`reader-node.bl`) |
| P2 | the reader (`reader.bl`) — 308/309 files read identically |
| P3–P9 | **every ~35 special forms** — literals, calls, `let`/`loop`/`recur`, `fn`/`defn` + full destructuring + guards, `def` + var-linking, macros + syntax-quote + hygiene, `defmulti`/`defprotocol`/`defrecord`/`reify`, `defserver` (a real gen_server), `try`/`receive`, `ns` |
| CK1 | **the whole standard library compiles**: 932/932 top-level forms, byte-identical |
| P12 | the compiler analyzes itself — a datalog query answers "what breaks if I change this?" |

## The proofs that it is real

- **932/932** — every top-level form of the entire prelude compiles to the same
  syntax tree as the old compiler (`research/sh_checkpoint1/`).
- **The fixpoint holds** — the `.bl` compiler compiles ITS OWN SOURCE
  identically: `compile(compiler-source) ≡ oracle(compiler-source)`. The
  compiler reproduces itself (`research/sh13_cutover/fixpoint.bl`).
- **It runs** — not just matching trees: the compiler's output is evaluated and
  produces correct values (`(loop [i 0 acc 0] …) → 45`)
  (`research/sh12_selfanalysis/end_to_end.bl`).
- **34 native tests** — the compiler's test suite is itself beam-lisp
  (`test/bl/self_hosting_test.bl`, `mix beam_lisp.test`).

## The mind-blowing part: the compiler is a program the language reasons about

Because the compiler is now beam-lisp source, the language's own tools consume
it:

- `codebase` indexes `compiler.bl` into a datom database — 121 functions, zero
  arity mismatches. *"What breaks if I change `compile-body`?"* is a datalog
  query returning its 8 callers (`examples/self/compiler-as-codebase.bl`).
- The **optimizer becomes a set of datalog queries** over the program-as-facts:
  "functions called exactly once" (inline candidates), "functions never called"
  (dead code — which found real unused helpers in the compiler itself).
- AST passes (line-stamping) become **optics traversals** — `path + transform`,
  composable, not hand-rolled recursion.

Self-hosting closes a loop: the analysis tools and the compiler now meet — the
compiler is the first large program the language reasons about about itself.

## The remaining work (honest status)

- **The runtime cutover** — making the live `Compiler.compile/2` delegate to
  `compiler.bl` and deleting the ~2400 lines of Elixir lowering — is scoped and
  de-risked (the fixpoint is the green light) but deserves a dedicated session
  with the full `mix test` as the per-step gate, because it modifies the
  load-bearing compiler. The recipe is in `research/sh13_cutover/README.md`. The
  one dependency to resolve: `compiler.bl` calls back into `macroexpand_1`, so a
  thin `Compiler` module (`compile` delegating + `macroexpand_1` + `new_env` +
  `read_all_data`) stays; the rest moves to `bootstrap/genesis/`.
- **The runtime substrate** (the 335 `rt` primitives, the persistent Vector) is
  *deliberately* retained as benchmark-exempt substrate: `first` is called 140×
  by the compiler itself, on the hottest path. Porting it to `.bl` and AOT-
  linking produces the same BEAM code but adds a bootstrap-ordering hazard, so
  by the project's own floor principle ("substrate migrates only if `.bl`-
  expressible without a benchmarked perf loss") it stays until a benchmark
  earns the move. The cutover does not touch it.

## In one sentence

beam-lisp's reader and compiler are now written in beam-lisp, compile the
language's entire standard library byte-identically, reproduce themselves, and
are analyzed by the language's own tools — with Elixir kept, on purpose, as the
final AST→BEAM step and the OTP host.
