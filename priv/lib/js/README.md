# Beam Lisp → JavaScript

JavaScript runs the same `priv/boot/core.bl` and `rt.bl` as BEAM. Every build
compiles these namespaces, the prelude, and the application through the shared
bl-ANF pipeline. Core functions have one source; JavaScript supplies host
primitives and value storage.

```sh
./bin/bl js build my.app -p src --out out/my-app --host now,measure
./bin/bl js watch my.app -p src --out out/my-app
./bin/bl js test
```

`-p` adds source roots; the current directory is the default and the portable
standard library is included. `--with NS` includes a namespace reached by
module name. `--stub NS` supplies an explicit runtime error for an excluded
namespace. `--host` declares the `js/` functions supplied by
`globalThis.BL_HOST`.

## Build layout and linking

Compiled namespaces live at `OUT/ns/<namespace>.mjs`, including
`ns/rt.mjs` and `ns/core.mjs`. The root contains:

- `rt.mjs`: persistent value storage, exact arithmetic, and pure BIF helpers;
- `lazy.mjs`: the host lazy-cell, cursor, and delay primitives;
- `abi.mjs`: calling/value adapters and owned metadata/reference/error primitives;
- `leaves.mjs`, `host-leaves.mjs`, `env.mjs`: the host ABI and live registry;
- `host.mjs`: the application's declared host functions;
- `core-links.mjs`: authoritative BEAM link and variadic-clause metadata.

Names resolve to compiled definitions, live seeded values, exact host leaves,
or declared application functions. Unresolved calls are build errors. Static
and eval-time remotes use the same compiled-module/leaf rule. A variadic clause
receives its rest arguments as one BL list.

First-class seeded values remain raw. Direct-call adapters are cached by the
captured value, not by namespace/name; rebinding changes future captures while
existing captures retain their identity. General callable and sequence rules
belong to compiled `rt.bl`, not to the host adapters.

## Values and evaluation

Integers use safe Numbers and promote to BigInt; floats are boxed so exact
map-key equality distinguishes `1` from `1.0`. Decimals preserve unscaled
integer and scale. Vectors are persistent 32-way tries; maps and sets use
HAMTs. Symbols use the reader's tuple representation. Strings use the owning
host's Unicode/grapheme operations.

The reader, compiler, macro expander, and emitter also compile to JavaScript:

```sh
./bin/bl js build js.eval -p priv/lib -p priv/boot \
  --stub lower --with reader --host run --out out/repl
```

A page can use the resulting live registry and macro boot cache:

```js
const { start } = await import("./out/repl/repl.mjs");
const repl = await start(readFile);
repl.evalWith("(->> (range 9) (map inc))", "user");
repl.evalCells([{ id, code }]);
```

`boot.mjs` loads source macros and support declarations against the compiled
base. `boot-cache.mjs` replays those definitions without reinstalling core
function implementations.

## Lazy semantics

The host lazy cell has pending, running, completed, retryable-failed, and
terminal states. Claim/complete/fail/release operations support the shared BL
fold protocol. Producers preserve 32-element chunking, exactly-once memoization,
error ordering, recursive-force and cyclic-memo guards, and bounded printing.
Metadata belongs to the value; realization belongs to the shared memo resource.

## Verification and measurements

```sh
node --test test/js/*.test.mjs test/js/perf/run.test.mjs
./bin/bl test test/bl/js_diff_test.bl test/bl/js_compiled_core_test.bl
./bin/bl run test/js/perf/build.bl
node test/js/perf/run.mjs test/js/perf/out
```

Differentials cover core expressions, reader source forms, in-page eval,
lazy nodes/producers, host leaves, comparison, metadata, and callback protocols.
The eight performance workloads validate every answer and report CPU and wall
medians for the sole target. Structural optimization work is tracked in
FUP-159 (ownership/chunk lowering), FUP-160 (constants/navigation/keyed folds),
and FUP-161 (materialization/sort/output builders).

Functions currently run to completion in an event. Actor suspension remains a
separate backend/library feature; pure core stays direct-style.
