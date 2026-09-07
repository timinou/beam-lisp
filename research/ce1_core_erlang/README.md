# CE1 — beam-lisp compiles to Core Erlang, in beam-lisp

*Historical record of the spike that proved Core Erlang is reachable from
beam-lisp with zero new host substrate.*

The quoted-backend path this spike exercised no longer exists.  The production
compiler (`priv/boot/compiler.bl`) now emits bl-ANF directly, and all module
construction goes through the canonical descriptor boundary
(`anf/module` → `lower/descriptor->beam`).  The sibling files in this
directory (`ce1.bl`, `bench.bl`, `oracle.bl`, `census.bl`) were written
against the old quoted-tree output and do not run against the current compiler.
They are preserved as archaeology.

The canonical test and benchmark contract is:

```clojure
; compile a form to bl-ANF
(def node (compiler/compile-node form (compiler/new-env ns)))

; package as a module descriptor and emit BEAM bytes
(def descriptor (anf/module mname [clause] [[:run 0]] [] {:file "demo.bl"}))
(def {mod bytes} (lower/descriptor->beam descriptor))

; load and call
(code/load_binary mod (str mod ".beam") bytes)
(erlang/apply mod :run [])
```

Thin client benchmarks using this API belong alongside the canonical
test suite rather than in this directory.

---

## Historical finding

`priv/boot/compiler.bl` (at the time of this spike) resolved every symbol,
expanded every macro, and emitted a **closed, lisp-shaped vocabulary of Elixir
quoted nodes** — literal, var, remote call, fn application, `fn`/`->`,
`if`/`cond`/`case`, `__block__`/`=`, `try`, `receive`, `apply`, `|` cons,
tuple/map/struct literals, `@` attributes.  No Elixir macro, alias, import or
protocol ever appeared in it.  `let` was an immediately-applied `fn`; `loop`
was self-application; `cond` was the compiler's own desugaring.

That tree was not Elixir.  It was an ANF-ish term that Elixir happened to
accept.  Core Erlang accepted it too — more directly, because every node had a
one-line Core counterpart.  So a self-hosted Core backend was **not a compiler
rewrite**; it was a second reader of the existing output:

```
bl source ──compiler.bl──▶ quoted ──ce1/lower──▶ cerl ──compile:forms──▶ .beam
                              │
                              └────Module.create──▶ .beam     (then)
```

`ce1.bl` was that reader: ~600 lines of `.bl` (lowering + module topology +
gates), driving `cerl` (the public OTP Core AST library) through plain
interop.  No Elixir module was added or changed.

## What ran

**Gate 1 — 24/24 forms yield the identical value via Elixir and via Core**
(same quoted tree, two backends, `=`): arithmetic · `let` · closures · `if`
truthiness · `str` · `loop`/`recur` · vector/map/struct literals · linked
calls · `erlang/` interop · destructuring · variadic + multi-clause fn · `cond`
· `try`/`throw`/`catch` typed and untyped · `finally` ordering ·
`receive`/`after` · `map`/`reduce`/`range`.

**Gate 2 — a `defn` becomes a Core body module.**  The `{kind arity fname
def_ast}` tuples the compiler handed to `Link.defvar` grouped by `{fname, arity}`
into one Core `fun` each, one `case` clause per def (guards carried), a
trailing `function_clause` error.  `fact/1 10 ⇒ 3628800`.

**Gate 3 — a `defserver` becomes a Core gen_server module.**  The emitted
`Module.create(Mod, block)` was read back; `@behaviour :gen_server` became a
module attribute; Elixir default-arg heads (`timeout \\ 5000`) expanded to
one def per arity; `__MODULE__` resolved.  `gen_server:start_link` → two
`:inc` → `:get ⇒ 7`.

**Gate 4 — `Link.defvar` in Core.**  `core-defvar` was `Link.defvar` with the
two `Module.create` calls replaced by Core modules: the body module (real code)
and the namespace module (one forwarding shim per clause, guard kept).  Env
bookkeeping, `fn_value`, link-info reused as is.  `fib 30` through the shim;
a guard refused on the shim; **a closure from v1 survived three redefinitions**
(the BEAM's two-version purge cannot reach a body module).

**Gate 5 — the wide oracle** (`oracle.bl`): `priv/std/test.bl` (the
`deftest`/`is` library itself — macros compiled by Core, run by the expander),
then six test files, every form through Core, then their tests:

| file | tests | assertions | vs Elixir backend |
|---|---|---|---|
| prelude_test | 58 | 295 | identical |
| core_additions_test | 40 | 153 | identical |
| optics_test | 14 | 54 | identical |
| sugar-test | 12 | 30 | identical |
| rewrite_test | 10 | 35 | identical |
| reader_meta_test | 8 | 16 (5 fail) | **identical — the same 5 fail on `bl test`** (pre-existing) |

142 tests, 583 assertions, zero divergence between backends.  One prelude test
(`for-destructuring`) flipped on both backends run to run: its expected value
assumed a map iteration order; not a Core matter.

**Census** (`census.bl`): every top-level form of `priv/boot`, `priv/std`,
`priv/lib`, `examples/**` compiled and lowered — **7582 forms, zero rejected**.

## Measured (bench.bl, 200 reps, one loop form)

| step | µs/form (run A / B) |
|---|---|
| `ce1/lower` quoted → cerl | 206 / 280 |
| Elixir: `Module.create` quoted → loaded `.beam` | 22416 / 24638 |
| Core: `compile:forms from_core` → loaded `.beam` | 11195 / 14328 |

Core built a module **1.7–2.0× faster**; the lowering was ~2% of the floor.
The remaining cost is the Erlang compiler's own SSA/asm passes — what any
frontend pays.  This was against an Elixir path that already disabled
`infer_signatures` and bypassed `ParallelChecker`; the Core path had no such
passes to disable.

## What the spike settled

- **Core is reachable from `.bl` with zero new substrate.**  `cerl`,
  `compile:forms`, `code:load_binary`, `core_pp` — all OTP, all callable.
- **The oracle changes shape, not strength.**  Tree-identity
  (`priv/self/oracle.bl`) becomes value-identity: eval both, compare — and,
  at scale, *run the test suite through the new backend*.  Stronger, and
  already how `veritas.property` thinks.
- **The lowering is small because the compiler already did the work.**
  `lower` was ~30 `cond` arms.  The bugs found along the way were all
  Elixir-quoted encoding quirks (`[h | t]` is a one-element list holding a
  cons node; 2-tuples are bare; `\\` defaults; `__MODULE__`) — exactly the
  class `docs/core-erlang/what-simpler-means.md` §2 describes.
- **The def-tuple contract is the seam.**  `core-defvar` was a drop-in for
  `Link.defvar`; `server->module` for `compile-defserver`'s `Module.create`.
  Nothing upstream of those two calls knew which backend it was on.
- **Evaluated-form modules must not be purged.**  A form's value can be a
  closure (a macro fn, a `def`'d lambda) living in the module — the same
  reason `eval_form` keeps its throwaway module loaded after calling `run/0`.

## Files

- `ce1.bl` — the lowering, module wrappers, `core-defvar`, the gates (historical)
- `run.bl` — gates entry (historical) · `oracle.bl` — suites through Core
  (historical) · `census.bl` — corpus coverage (historical) · `bench.bl` —
  backend latency (historical)
