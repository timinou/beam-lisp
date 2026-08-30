# sh0 — the seed round-trips (P0)

**Question.** Can beam-lisp code turn a program into a real Elixir syntax
tree and run it, with nothing but the Erlang/Elixir standard library
underneath — no part of beam-lisp's own Elixir-written compiler in the loop?

**Verdict: yes.** Proven at three strengths, weakest to strongest.

## What was built

`priv/bootstrap/nano.bl` — a tiny compiler, written in beam-lisp, for one
shape of program: a single arithmetic call like `(+ 1 2)` or `(* 6 7)`. It
does the whole self-hosting pipeline in miniature:

1. `lower` takes the reader's data for `(+ 1 2)` — a list whose head is the
   symbol `+` and whose tail is numbers — and returns the Elixir syntax tree
   `{:+, [], [1, 2]}` (operator atom, empty metadata slot, argument list).
2. `run` hands that tree to `Code.eval_quoted` (Elixir standard library) and
   returns the answer.

The only things beneath it are `:erlang` built-ins (`list_to_tuple`,
`tuple_to_list`) and one Elixir stdlib call (`Code.eval_quoted`). That is the
entire floor the whole self-hosting effort rests on.

## The three proofs

### 1. The seam works (`seam_probe.bl`)

```
$ mix beam_lisp.run research/sh0_seed/seam_probe.bl
AST: {:+, [], [1, 2]}
eval result: 3
seam OK? true
```

beam-lisp builds a real Elixir AST tuple and evaluates it → 3.

### 2. It runs with the compiler purged (`purge_proof.exs`)

```
$ mix run research/sh0_seed/purge_proof.exs
with compiler present:  (+ 1 2) => 3
compiler/reader loaded after purge: []
with compiler PURGED:   (+ 1 2) => 3
P0 PASS
```

The AOT-compiled `nano.beam` is called, then `BeamLisp.Compiler` and
`BeamLisp.Reader` are **deleted from the running VM**, then it is called
again — still 3. beam-lisp's own compiler is provably not in the runtime
loop.

### 3. It runs in a bare Erlang VM (`bare_erl_proof.erl`)

```
$ erlc bare_erl_proof.erl
$ erl -noshell -pa <all _build ebins> -pa <elixir ebin> -run p0run go
bare-erl (+ 1 2) => 3
P0-BARE PASS
```

No `mix`, no Elixir application booted — a plain `erl` VM loads the AOT'd
`.beam` and runs it. This is the true floor: the seed is a `.beam` file that
needs only the Erlang runtime plus the Elixir/Erlang standard-library beams
on the code path.

## Why this matters

Every later prototype (a real reader, a real compiler, the runtime
primitives, the data structures) is a bigger version of `nano.bl`. P0 proves
the shape is sound before any of that is attempted: the frozen `.beam` seed
that breaks the read-the-reader circularity is real, and the retained-Elixir
floor is exactly what the plan claimed — one stdlib call plus BIFs, not a
custom Elixir compiler.

## Reproduce

```
mix beam_lisp.run research/sh0_seed/seam_probe.bl
mix run research/sh0_seed/purge_proof.exs
# bare erl: see bare_erl_proof.erl header
```
