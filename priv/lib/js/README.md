# The JS sync profile

Beam Lisp → ES modules for code that runs to completion in response to an
event: editors, views, parsers, validators. It is the profile bl-ed is built on
(PLAN-161), and the base of the one unified JS target (PLAN-163): core
compiled from priv/boot, actors as a library with selective suspension. Until
PLAN-163 lands, `research/js-actors` is the prototype for processes.

```sh
bl js build my.app -p src [-p more] [--out out/my-app] [--host now,measure]
bl js watch my.app -p src            # rebuild on every .bl change under the roots
bl js test                           # the BEAM <-> JS differential (test/js/diff)
```

`bl js build` reads `my.app` and every namespace it requires under the roots
(`-p`, repeatable; default the current directory; `priv/std` is always searched
last). It compiles each one with the BEAM compiler to bl-ANF, emits one ES
module per namespace, and writes `rt.mjs`, `core.mjs` and a `host.mjs` stub
beside them. `--host` names the `js/` functions the page provides on
`globalThis.BL_HOST`; any other `js/` name is a build error.

## What a program becomes

| Beam Lisp | JavaScript |
|---|---|
| `(defn f [x] …)` | `export const d_f = (function f_…(a0) { … })` |
| a call of a named fn | a direct JS call, `d_f(x)` or `N_ns.d_f(x)` |
| `loop`/`recur` | a labelled `for(;;)` with parallel reassignment |
| multi-arity / `& rest` | one dispatcher on `arguments.length`; rest is a BL list |
| `try`/`catch`/`finally` | JS `try`/`catch`/`finally` |
| keyword literal | a module-level const interned once |
| `(js/name args)` | `H["name"](args)` — a host function the page provides (declared with `--host name`) |
| `receive`, `spawn` | **refused** at build time (not this profile) |

**Linking happens at build time.** Every name resolves to one of five things:
a definition in the same namespace, a definition in a required namespace, a
core function (`core.mjs` `CORE`), a host LEAF (`leaves.mjs`, the BEAM
primitives Beam Lisp's own sources call — `erlang/element`, `lists/split`,
`BeamLisp.Env/fetch!` …), or a declared host function. Anything else fails the
build, which lists *every* unresolved name. `--stub NS` leaves a namespace out
deliberately (reaching it at run time is a named error); `--with NS` adds one
reached only by module name. Runtime functions the
compiler calls directly (`Ns.Rt/print_readably`, `Ns.Core/max__bl_v`) are
mapped to their BL names through the BEAM's own link table. The JS side does
not keep a copy of BEAM's naming.

## Values (`rt.mjs`)

- Integers are exact: a JS Number in the safe range, a BigInt beyond it, and
  normalized back when a result fits.
- Floats are boxed (`Flt`), so `1` and `1.0` are distinct map keys while
  `(= 1 1.0)` is true, as on BEAM.
- Vectors are persistent 32-way tries and maps/sets are HAMTs. Both share
  structure, so an update costs O(log32 n).
- `=` treats lists and vectors as one sequential family. Map keys do not (the
  `hash_key` relation).
- Strings are grapheme-indexed for `count`, `subs` and `index-of`, matching
  BEAM. Segmentation is cached per string, because strings are values.
- A symbol is the BEAM's own reader node `{:symbol "name"}` (a `Tup`), so a
  quoted symbol and one a macro builds are one kind of value.
- Exact decimals (`1.50M`) are `Dec` (BigInt unscaled + scale) with BEAM's
  arithmetic: scale-preserving `+ - *`, terminating `/` (else an error), no
  floats. `(= 1.5M 1.50M)` is false; `(= 1.5M 1.5)` is true.
- Lazy sequences (`Lazy`) realize one cell at a time, so `iterate`, `cycle`
  and `(repeat x)` are infinite here too.

## Held to BEAM by a differential

```sh
test/js/diff/run-diff.sh
```

This evaluates about 230 expressions (numbers, equality, collections, seqs,
strings, functions, destructuring, control) on BEAM and in this profile,
canonicalizes map/set entry order, and compares the two. All 8 groups are
identical. The semantics this pinned are in PLAN-161's progress log. They
include `(= 1 1.0)` being true, grapheme strings, `nth` out of range being
nil, and `(str :k)` being `"k"`.

`test/js/rt.test.mjs` checks the persistent structures against plain JS
models: 20,000–30,000 random operations and forced 32-bit hash collisions.

## Core library (`core.mjs`)

Core has one semantics and one implementation per target (PLAN-161 D5). BEAM
runs `priv/boot/core.bl` + `rt.bl`; this profile runs `core.mjs`, held to the
BEAM's answers by three differentials (below). Most sequence functions are
eager (UI code consumes finite sequences); the infinite generators are lazy.

## Beam Lisp in the page: `js.eval`

The self-hosted reader, compiler, macro expander and this emitter are Beam
Lisp too, so they compile to JS like any program:

```sh
bl js build js.eval -p priv/lib -p priv/boot --stub lower --with reader --host run --out out/
```

`priv/lib/js/eval.bl` runs read → compile → emit → `new Function` against a
live registry (`env.mjs`, the JS twin of `BeamLisp.Env`), so a `defn` is
callable by the next form and a `defmacro` expands the next compile. A page
uses `repl.mjs`:

```js
const { start } = await import("./out/repl.mjs");
const repl = await start(readFile);            // core's macros, ~10 ms
repl.evalWith("(->> (range 9) (map inc))", "user");   // {:text "(1 2 … 9)"}
repl.evalCells([{id, code}, …]);               // a livebook's cells, in order
```

`boot.mjs` loads core.bl's and sugar.bl's macros. `bl js build` compiles them
once and writes `boot-cache.mjs`, which the page replays (~10 ms instead of
~500 ms compiling them in the page). `core-links.mjs` is BEAM's core link
table, generated per build, so the in-page compiler links core calls exactly
as the BEAM compiler does.

## Held to the BEAM: three differentials

`bl test test/bl/js_diff_test.bl` (also `bl js test`) runs:

| differential | what it compares |
|---|---|
| core (`test/js/diff`) | ~230 expressions, BEAM vs a JS build |
| reader (`test/js/reader`) | the self-hosted reader in JS vs on BEAM, over 7 real sources (48 in the full run): identical forms |
| eval (`test/js/eval`) | 76 forms evaluated by Beam Lisp IN JS (defs, macros, decimals, destructuring, try …) vs on BEAM: identical printed results |

## Laziness (lazy.mjs)

`lazy.mjs` is `BeamLisp.LazySeq`, `Deferred` and `SeqCursor` for JS: the BEAM's five cell states (pending, running, completed, failed, terminal), claim/complete/fail/release for fold recipes, and the leaf ABI rt.bl calls, name for name. It does not have waiters, versions or a cache budget; a page runs on one thread, so nothing else can run while a thunk runs. What a program can *see* matches the BEAM:
- a node is realised once;
- a thrown thunk can be retried;
- a self-forcing node is `:recursive_force` (terminal);
- a node whose value contains itself is `:cyclic_memo`;
- a halted fold publishes nothing;
- printing is bounded to 20 elements.

`test/js/eval/lazy.bl` pins these answers, and `bl test test/bl/js_diff_test.bl` runs it. `test/js/eval/lazy-core.bl` pins the *producers*: chunked `map`/`filter` realise 32 at a time, and `list?`/`type` of a mapped seq. The hand-written core.mjs is eager, so this is the gate for core compiled from priv/boot (PLAN-163 U2).
