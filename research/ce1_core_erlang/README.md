# CE1 — beam-lisp compiles to Core Erlang, in beam-lisp

*The beautifully simple way: the compiler's output is already the IR.*

## The finding

`priv/boot/compiler.bl` resolves every symbol, expands every macro, and emits
a **closed, lisp-shaped vocabulary of Elixir quoted nodes** — literal, var,
remote call, fn application, `fn`/`->`, `if`/`cond`/`case`, `__block__`/`=`,
`try`, `receive`, `apply`, `|` cons, tuple/map/struct literals, `@` attributes.
No Elixir macro, alias, import or protocol ever appears in it. `let` is an
immediately-applied `fn`; `loop` is self-application; `cond` is the compiler's
own desugaring.

That tree is not Elixir. It is an ANF-ish term that Elixir happens to accept.
Core Erlang accepts it too — more directly, because every node has a one-line
Core counterpart. So a self-hosted Core backend is **not a compiler rewrite**;
it is a second reader of the existing output:

```
bl source ──compiler.bl──▶ quoted ──ce1/lower──▶ cerl ──compile:forms──▶ .beam
                              │
                              └────Module.create──▶ .beam     (today)
```

`ce1.bl` is that reader: ~600 lines of `.bl` (lowering + module topology +
gates), driving `cerl` (the public OTP Core AST library) through plain
interop. No Elixir module was added or changed.

## Run

```
BEAM_LISP_PATH=research/ce1_core_erlang ./bl run research/ce1_core_erlang/run.bl      # the gates
BEAM_LISP_PATH=research/ce1_core_erlang ./bl run research/ce1_core_erlang/oracle.bl   # test suites through Core
BEAM_LISP_PATH=research/ce1_core_erlang ./bl run research/ce1_core_erlang/census.bl   # what lower rejects, corpus-wide
BEAM_LISP_PATH=research/ce1_core_erlang ./bl run research/ce1_core_erlang/bench.bl    # backend latency
```

## What ran

**Gate 1 — 24/24 forms yield the identical value via Elixir and via Core**
(same quoted tree, two backends, `=`): arithmetic · `let` · closures · `if`
truthiness · `str` · `loop`/`recur` · vector/map/struct literals · linked
calls · `erlang/` interop · destructuring · variadic + multi-clause fn · `cond`
· `try`/`throw`/`catch` typed and untyped · `finally` ordering ·
`receive`/`after` · `map`/`reduce`/`range`.

**Gate 2 — a `defn` becomes a Core body module.** The `{kind arity fname
def_ast}` tuples the compiler hands to `Link.defvar` group by `{fname, arity}`
into one Core `fun` each, one `case` clause per def (guards carried), a
trailing `function_clause` error. `fact/1 10 ⇒ 3628800`.

**Gate 3 — a `defserver` becomes a Core gen_server module.** The emitted
`Module.create(Mod, block)` is read back; `@behaviour :gen_server` becomes a
module attribute; Elixir default-arg heads (`timeout \\ 5000`) expand to one
def per arity; `__MODULE__` resolves. `gen_server:start_link` → two `:inc` →
`:get ⇒ 7`.

**Gate 4 — `Link.defvar` in Core.** `core-defvar` is `Link.defvar` with the
two `Module.create` calls replaced by Core modules: the body module (real
code) and the namespace module (one forwarding shim per clause, guard kept).
Env bookkeeping, `fn_value`, link-info reused as is. `fib 30` through the
shim; a guard refuses on the shim; **a closure from v1 survives three
redefinitions** (the BEAM's two-version purge cannot reach a body module).

**Gate 5 — the wide oracle** (`oracle.bl`): `priv/std/test.bl` (the
`deftest`/`is` library itself — macros compiled by Core, run by the
expander), then six test files, every form through Core, then their tests:

| file | tests | assertions | vs Elixir backend |
|---|---|---|---|
| prelude_test | 58 | 295 | identical |
| core_additions_test | 40 | 153 | identical |
| optics_test | 14 | 54 | identical |
| sugar-test | 12 | 30 | identical |
| rewrite_test | 10 | 35 | identical |
| reader_meta_test | 8 | 16 (5 fail) | **identical — the same 5 fail on `bl test`** (pre-existing) |

142 tests, 583 assertions, zero divergence between backends. One prelude test
(`for-destructuring`) flips on both backends run to run: its expected value
assumes a map iteration order; not a Core matter.

**Census** (`census.bl`): every top-level form of `priv/boot`, `priv/std`,
`priv/lib`, `examples/**` compiled and lowered — **7582 forms, zero rejected**.

## Measured (`bench.bl`, 200 reps, one loop form)

| step | µs/form (run A / B) |
|---|---|
| `ce1/lower` quoted → cerl | 206 / 280 |
| Elixir: `Module.create` quoted → loaded `.beam` | 22416 / 24638 |
| Core: `compile:forms from_core` → loaded `.beam` | 11195 / 14328 |

Core builds a module **1.7–2.0× faster**; the lowering is ~2% of the floor.
The remaining cost is the Erlang compiler's own SSA/asm passes — what any
frontend pays. This is against an Elixir path that already disables
`infer_signatures` and bypasses `ParallelChecker`; the Core path has no such
passes to disable.

## What the spike settles

- **Core is reachable from `.bl` with zero new substrate.** `cerl`,
  `compile:forms`, `code:load_binary`, `core_pp` — all OTP, all callable today.
- **The oracle changes shape, not strength.** Tree-identity
  (`priv/self/oracle.bl`) becomes value-identity: eval both, compare — and,
  at scale, *run the test suite through the new backend*. Stronger, and
  already how `veritas.property` thinks.
- **The lowering is small because the compiler already did the work.**
  `lower` is ~30 `cond` arms. The bugs found along the way were all
  Elixir-quoted encoding quirks (`[h | t]` is a one-element list holding a
  cons node; 2-tuples are bare; `\\` defaults; `__MODULE__`) — exactly the
  class `docs/core-erlang/what-simpler-means.md` §2 describes.
- **The def-tuple contract is the seam.** `core-defvar` is a drop-in for
  `Link.defvar`; `server->module` for `compile-defserver`'s `Module.create`.
  Nothing upstream of those two calls knows which backend it is on.
- **Evaluated-form modules must not be purged.** A form's value can be a
  closure (a macro fn, a `def`'d lambda) living in the module — the same
  reason Elixir's `BeamLisp.Eval.M*` modules stay resident. `eval-core` keeps
  them.

## Next: the cutover recipe

1. `priv/self/core.bl` ← `ce1.bl` minus gates; `lower`, `defs->module`,
   `server->module`, `core-defvar`, `eval-core`.
2. `Compiler.eval_form` and `Link.defvar` gain a backend switch (an Env key);
   `core` routes to the `.bl` functions above.
3. `mix beam_lisp.test` under the Core backend = the gate. Green ⇒ default.
4. AOT: `compile:forms` already returns the binary; `aot.ex` writes it. The
   drift gate keys on module md5 — unchanged.
5. Then, optionally, the deeper move: replace `ast-node` in `compiler.bl` with
   `cerl` constructors, deleting the quoted layer. Mechanical; the same oracle
   guards it.

## Files

- `ce1.bl` — the lowering, module wrappers, `core-defvar`, the gates (`main`)
- `run.bl` — gates entry · `oracle.bl` — suites through Core · `census.bl` —
  corpus coverage · `bench.bl` — backend latency
