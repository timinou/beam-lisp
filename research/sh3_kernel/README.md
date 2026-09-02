# sh3 — the compiler kernel, in beam-lisp (P3)

**Question.** Can a compiler written in beam-lisp turn forms into the same
Elixir syntax tree the existing Elixir compiler produces, for literals and the
ordinary call paths?

**Verdict: yes.** 40 of 40 checked forms compile to byte-identical Elixir AST
(after blanking line/import metadata, which does not change meaning).

## What was built

`priv/boot/compiler.bl` — forms → Elixir syntax tree, written in beam-lisp. This is
the KERNEL: the part with no special forms yet. It covers:

- **literals** — number, float, string, boolean, nil, keyword (each is its own
  Elixir value);
- **collection literals** — vector (`%BeamLisp.Vector{items: {..}}`), map
  (`%{RT.hash_key(k) => v}`), set (`BeamLisp.Set.new([..])`), nested freely;
- **symbols** — a plain name becomes a namespace fetch
  `BeamLisp.Env.fetch!(ns, name)`; a qualified `Module/fun` becomes a remote
  function value;
- **calls**, four paths:
  - a keyword head `(:a m)` → `RT.invoke(:a, [m])`;
  - a linked name `(+ 1 2)` → the direct BIF call `:erlang.+(1, 2)` (this is
    the var-linking fast path — a linked name skips lookup and dispatch);
  - a qualified head `(String/upcase s)` → `apply(String, :upcase, [args])`
    (Elixir modules get the `Elixir.` atom prefix; Erlang modules stay bare);
  - any other plain name → `RT.invoke(Env.fetch!(ns, name), [args])`.

It builds on `reader-node.bl` (P1) for reading forms and is graded by
`self/oracle.bl`'s `ast-equal?` against `BeamLisp.Compiler/compile`.

## The gate

```
gate.bl       16/16 OK  — one representative per feature
wide_gate.bl  24/24 OK  — empty collections, nesting, variadic arithmetic,
                          mixed literals, Elixir + Erlang remote calls
```

Every case asserts `ast-equal?(kernel-compile(form), oracle-compile(form))`.

## What the gate taught

Three things the oracle demanded that a naive port would miss:

1. **Linking is not optional.** `(+ 1 2)` does not compile to a generic
   `RT.invoke` — `+` is *linked* to the Erlang BIF, so it compiles to a direct
   `:erlang.+(1, 2)` call. The kernel had to look names up in
   `BeamLisp.Env/link` and emit the direct call when the arity matches. This is
   the fast path that makes hot loops fast, and it is live even in the kernel.
2. **Elixir modules carry an `Elixir.` atom prefix.** `String` on the BEAM is
   the atom `:"Elixir.String"`; `lists` is just `:lists`. The remote-call path
   had to prepend `Elixir.` for an uppercase module prefix.
3. **Plain lists, not vectors, build AST.** beam-lisp's `into []` makes a
   vector value; an Elixir syntax tree is built from plain lists. Compiling
   children with `apply list` (not `into []`) was required, or the emitted
   tuples were malformed. The differential oracle caught this immediately.

## Reproduce

```
mix compile.beam_lisp --source-dir priv
mix beam_lisp.run research/sh3_kernel/gate.bl
mix beam_lisp.run research/sh3_kernel/wide_gate.bl
```
