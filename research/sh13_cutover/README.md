# sh13 — the fixpoint + the cutover recipe (CHECKPOINT 2 groundwork)

## The fixpoint holds (`fixpoint.bl`)

The mathematical heart of self-hosting: the `.bl` compiler compiles ITS OWN
SOURCE to the same Elixir AST the existing compiler produces.

```
priv/compiler.bl   self-compile OK: 133  FAIL: 0
priv/reader.bl     self-compile OK: 37   FAIL: 0
priv/reader-node.bl self-compile OK: 10  FAIL: 0
priv/self/oracle.bl self-compile OK: 16  FAIL: 0
```

`compile(compiler-source) ≡ oracle(compiler-source)` for every form. The
self-hosted compiler reproduces itself byte-for-byte — a true fixpoint. Combined
with CHECKPOINT 1 (932/932 of the whole prelude) and the end-to-end run proof,
the self-hosted frontend is complete and correct.

## The frozen seed exists

`compiler.bl` and `reader.bl` are AOT-compiled to real `.beam` modules on every
build (`Elixir.BeamLisp.Ns.Compiler.beam`, `…Ns.Body.Compiler.beam`,
`…Ns.Reader.beam`). Those beams ARE the frozen seed: a fresh VM loads them and
can compile `.bl` source with no Elixir-written compiler in the loop (proven at
P0 for the nano seed; the full compiler is the same mechanism at scale).

## The cutover recipe (for the next focused session)

The swap point is ONE function: `BeamLisp.Compiler.compile/2` (compiler.ex:119).
Everything routes through it (`eval_string` → `eval_form` → `compile`).

To cut over: replace `Compiler.compile/2`'s body with a delegation to the `.bl`
compiler —
```elixir
def compile(form, env), do: apply(BeamLisp.Ns.Compiler, :compile, [form, env])
```
then delete the ~2400 lines of lowering below it.

### The one dependency to resolve first

`compiler.bl` calls back into `BeamLisp.Compiler/macroexpand_1` (compiler.bl
line ~2541) for macro expansion. So the cutover cannot delete the WHOLE
`Compiler` module — these small functions must remain as retained substrate (or
be ported to `.bl`):
- `macroexpand_1/2` — one macroexpansion step (small, ~15 lines)
- `new_env/1`, `read_all_data/1` — env constructor + data reader (small)

Recommended: keep a thin `Compiler` module with ONLY `compile/2` (delegating),
`macroexpand_1/2`, `new_env/1`, `read_all_data/1` — everything else (the ~2400
lines of lowering) deleted and moved to `bootstrap/genesis/` as the labeled
"how the seed was first grown" reference. `reader.ex` similarly reduces to a
thin `read_all/read_one` delegating to `reader.bl`.

### Bootstrap order (the frozen-seed ladder)

1. A fresh clone has no `_build`. It needs the seed beams to compile `.bl`.
2. Commit `priv/bootstrap/*.beam` (the AOT'd reader.bl + compiler.bl) OR keep
   `bootstrap/genesis/{reader,compiler}.ex` (the retained Elixir source) as the
   stage-0 that regrows the seed from scratch.
3. stage-0 compiles compiler.bl → stage-1 (.beam). stage-1 compiles itself →
   stage-2. Assert stage-1 ≡ stage-2 (the fixpoint above, now over .beam).

### Why this is a separate focused session

Modifying the load-bearing `Compiler.compile/2` and deleting 2400 lines is a
high-stakes cutover: a mistake breaks all `.bl` loading. It deserves its own
session with the full `mix test` (863) as the gate at each step, not the tail of
a marathon. The fixpoint proof here is the green light: the .bl compiler is
provably ready to BE the compiler.

## Reproduce

```
mix beam_lisp.run research/sh13_cutover/fixpoint.bl
```
