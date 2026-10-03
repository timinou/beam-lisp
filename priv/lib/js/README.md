# The JS sync profile

Beam Lisp → ES modules for code that runs to completion in response to an
event: editors, views, parsers, validators. It is the profile bl-ed is built on
(PLAN-161). The actor profile in `research/js-actors` stays for code that needs
processes, mailboxes and preemption.

```sh
JS_ENTRY=my.app JS_OUT=out/my-app JS_ROOTS=src[:more] \
JS_HOST_FNS=now,measure bl run priv/lib/js/cli.bl
```

The command reads `my.app` and every namespace it requires under the roots. It
compiles each one with the BEAM compiler to bl-ANF, emits one ES module per
namespace, and writes `rt.mjs`, `core.mjs` and a `host.mjs` stub beside them.

## What a program becomes

| Beam Lisp | JavaScript |
|---|---|
| `(defn f [x] …)` | `export const d_f = (function f_…(a0) { … })` |
| a call of a named fn | a direct JS call, `d_f(x)` or `N_ns.d_f(x)` |
| `loop`/`recur` | a labelled `for(;;)` with parallel reassignment |
| multi-arity / `& rest` | one dispatcher on `arguments.length`; rest is a BL list |
| `try`/`catch`/`finally` | JS `try`/`catch`/`finally` |
| keyword literal | a module-level const interned once |
| `(js/name args)` | `H["name"](args)` — a host function the page provides (declared in `JS_HOST_FNS`) |
| `receive`, `spawn` | **refused** at build time (not this profile) |

**Linking happens at build time.** Every name resolves to one of four things:
a definition in the same namespace, a definition in a required namespace, a
core function (`core.mjs` `CORE`), or a declared host function. Anything else
fails the build, which lists *every* unresolved name. Runtime functions the
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
runs `priv/boot/core.bl` + `rt.bl`; this profile runs `core.mjs`. Sequence
functions are eager here, because UI code consumes finite sequences
immediately. Infinite generators (`iterate`, `cycle`, 1-arity `repeat`) are
refused.
