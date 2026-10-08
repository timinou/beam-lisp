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

The shared printer writes through the host `io/format/2` leaf's Unicode
`~ts` and `~ts~n` formats. Node writes stdout; browsers write the console.
Embeddings can bind an exact-text sink with `bindOutput` from `host-leaves.mjs`.
Other format directives report a named unsupported-format error.

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

## Native JavaScript interop

Mark a namespace with `^:js` (or `^{:interop :javascript}`):

```clojure
(ns ^:js browser.audio)

(defn create []
  (js/AudioContext. #js {:latencyHint "interactive"}))

(defn tone [ctx frequency]
  (let [osc (.createOscillator ctx)]
    (set! (.-value (.-frequency osc)) frequency)
    (.connect osc (.-destination ctx))
    (.start osc)
    osc))
```

The annotation grants native interop to this namespace's implementation.
Requiring it does not grant interop to callers. Expanded macro operations are
checked in the caller's environment. Redeclaring a live namespace without the
annotation removes its grant for subsequent compilation. Existing compiled
functions retain their behavior. This is an architectural boundary, not a
security sandbox: annotated code has the JavaScript environment's authority.

| Form | Operation |
|---|---|
| `js/document` | global value |
| `(js/Math.sin x)` | static method, preserving its receiver |
| `(js/AudioContext. options)` | constructor |
| `(.connect node destination)` | method call, preserving `this` |
| `(.-currentTime ctx)` | property read |
| `(set! (.-value param) x)` | property assignment |
| `(aget object key)` / `(aset object key value)` | computed access/assignment |
| `#js {:gain 0.5}` / `#js [1 2]` | native object/array |
| `(bl->js value)` / `(js->bl value)` | explicit data conversion |
| `(js/undefined? value)` | distinguish undefined from nil/null |

Native literals are shallow; nested native data is explicit:
`#js {:position #js [0 1 2]}`. Object keys must be literal strings or keywords;
keywords become their full spelling. Duplicate converted keys are compile
errors. Values are evaluated once, in source order; call receivers and methods
are captured before argument side effects. Ordinary BL collections keep their
persistent semantics. There is no raw-source injection form.

`system.js` checks canonical ANF through `system.ir` and tracks definite value
shapes through lexical bindings and branch unions. Known BL collections in
native argument/receiver positions produce compile errors suggesting `#js` or
`bl->js`; unknown values stay silent. Runtime native argument checks catch
unconverted collections when compile-time evidence is unavailable.
`typed/check-js-ir` exposes the same source-located diagnostics to tooling.
Native JS operations have opaque effect evidence and no termination proof.
The type lattice and summaries distinguish JS objects, JS arrays and undefined.
The pass does not invent API signatures for browser globals.

`bl->js` recursively converts finite BL vectors/lists/maps, converts keyword
keys/values to strings and unboxes floats. BigInts remain BigInts; exact decimals,
sets, symbols and ordinary tuples need an explicit application policy and are
rejected. Duplicate map keys after conversion are rejected. Foreign objects
retain identity. `js->bl` converts arrays/plain objects recursively; use
`(js->bl object :keywordize-keys true)` for keyword keys. Cycles are rejected.
Null is nil; undefined remains distinct. Native calls unbox floats and adapt
functions, without silently converting collections or keyword values.

Pass BL functions directly as callbacks. Adapters preserve identity, so the same
BL function can be passed to both addEventListener and removeEventListener.
First-class JS functions adapt numeric values when called from BL; extracting a
method does not bind its receiver. Promise chains use `.then` and `.catch`;
there is no implicit async suspension.

### JavaScript calling Beam Lisp

Generated modules register their public original BL names. Import the module,
then acquire an API through `requireNamespace` from `interop.mjs`:

```js
await import("./out/ns/music.score.mjs");
const { requireNamespace } = await import("./out/interop.mjs");
const score = requireNamespace("music.score");
score["note-frequency"](69);
```

Live embeddings use `repl.require("music.score")`. Both bridges adapt ordinary
JS data to BL arguments and BL data to JS results through the existing callable
ABI. `defn-` and name metadata `^:private` are omitted; live accessors observe
redefinitions. No knowledge of generated export-name mangling is required.

### Injected host services

Existing `--host` builds continue to support injected `js/*` host functions.
Embeddings can also use `repl.installNamespace` to install a fresh, revocable
live namespace from an explicit manifest:

```js
const clock = repl.installNamespace("browser.clock", {
  now: { arities: [0], fn: () => performance.now() },
});
clock.dispose();
```

This helper is optional for owned host services, rather than a prerequisite for
native JS syntax. It rejects collisions and revokes captured wrappers on disposal.
Adapters own resource budgets and asynchronous completion. Its values cross
unchanged. It retains the namespace declaration to preserve independent aliases
and vars; use fresh names for new lifetimes.

PELAGIC's score, state and live compiler already run on JS. Annotated namespaces
can express its browser orchestration in BL; Web Audio/WebGL remain browser APIs.
A server-free editor also needs document/save/revision service replacements.
Omega's older compiler pin and output layout require a separate verified migration.

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
./bin/bl test test/bl/js_macro_build_test.bl test/bl/js_cold_build_test.bl
BL_TEST_TIMEOUT=1200 ./bin/bl test test/bl/js_native_interop_test.bl test/bl/js_native_live_test.bl
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
