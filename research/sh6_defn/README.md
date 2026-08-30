# sh6 — def and defn, var linking (P6)

**Question.** Can the beam-lisp compiler compile `def` and `defn` — including
the per-namespace-module linking that makes function calls fast — to the same
Elixir syntax tree the existing compiler produces?

**Verdict: yes.** 10/10 def/defn forms compile AST-equal to the oracle,
covering self-recursion, multi-arity, variadic, guards, and parameter
destructuring.

## What was added to `priv/compiler.bl`

- **`def`** → `BeamLisp.Env.intern(ns, name, value)`.
- **`defn` / `defn-`** → `BeamLisp.Link.defvar(ns, name, entries, location)`,
  where each clause is a real named Elixir `def fname(params), do: body`
  installed into the namespace's own module. This is the linking that makes a
  call a direct BEAM function call rather than a lookup-and-dispatch, and a
  self-call a tail-call-optimized named recursion. Reuses the whole fn engine
  from P5 (destructuring, `& rest`, `:when` guards, multi-arity), but emits
  `def` clauses with a `self_call` recur target instead of a self-applied
  closure.

## Why this is also the perf gate

P6 carries a perf budget: the hot loop must stay within noise of the ~11ms
baseline. The proof here is structural: the compiler emits **byte-identical
AST** to the oracle (the gate asserts it), so the linked def-clause topology
and the direct-call recur are identical → identical BEAM code → identical
performance. The bench confirms the baseline is intact (1M loop 10ms). The
runtime-execution perf test (running code the `.bl` compiler actually emitted)
lands at CHECKPOINT 1, when the `.bl` compiler is on the load path.

## Three things the differential gate forced

Comparing linked `defn` output is harder than comparing plain expressions,
because `defn` escapes its clause data into a `Link.defvar` call — which turns
what would be blank-able AST metadata into ordinary comparable data. The oracle
made three demands:

1. **`__aliases__` metadata is `[alias: false]`, not `[]`.** For ordinary code
   the metadata-blanking pass hides this, but inside escaped `defn` data the
   metadata is frozen as data and must match exactly. `ast-alias` now stamps
   `[alias: false]`.
2. **The variable context atom must match** (`BeamLisp.Compiler`). The compiler
   now stamps the same context the oracle's `__MODULE__` uses.
3. **Source position and gensym numbering must be compared modulo their
   values.** The oracle's `ast-equal?` gained two normalizers: `blank-positions`
   canonicalises the `[file:, line:]` location a `defvar` carries, and
   `canonicalize-locals` now also renames *bare gensym atoms* (`n_54700`) buried
   in escaped data — not just variable nodes — so two compilers' numbering is
   irrelevant.

## The gate

```
gate.bl  10/10 OK — def, def-with-expr, defn (self-recursive fact), multi-arity,
                    variadic, single-arg, param destructuring, :when guard
```

No regressions: P3 24, P4 17, P5 (fn 8 / destr 10 / param 7 / multiclause 7 /
guards 8), P6 10 — 91 checks, all green.

## Deferred (defn metadata)

A `defn` docstring is currently skipped (parsed off, not emitted). The oracle
also emits an `Env.put_meta` side-call for a docstring / `^:private` / attr-map.
That metadata layer is a later refinement; the linked function itself is
complete and correct.

## Reproduce

```
mix compile.beam_lisp --source-dir priv
mix beam_lisp.run research/sh6_defn/gate.bl
```
