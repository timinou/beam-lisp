# Native operations and compiled BL links inside actor namespaces

The library `js.actor` accepts the existing namespace shorthand:

```clojure
(ns ^:js app.prepare (:require [app.kernel :as kernel]))
(defn worker []
  (receive
    [:job caller input]
      (let [output (kernel/compute input)]
        (.postMessage js/self #js {:op "result" :output (bl->js output)})
        (rt-send caller [:done]))))
```

Two different edges have different value contracts:

- A compiled BL import such as `kernel/compute` takes canonical BL values and
  returns them unchanged. Its checked module manifest declares the BL ABI.
  Collections, exact decimals, float identity and native references can cross
  that call without conversion, copying, encoding, promises or actor frames.
- An actual JavaScript operation such as `.postMessage` uses the shared native
  boundary. Known BL collections require `#js` or `bl->js`, and exact decimal
  conversion requires an explicit policy. `system.js/check!` reports known
  mistakes during compilation; `js.emit/emit-native` owns evaluation order.

Local actor messages retain references in the same realm. Workers have their
explicit structured-clone boundary. An actor callback can enter JavaScript only
when its checked body is non-suspending; it still runs through the same frame
machine. Calling a compiled BL helper directly has no callback entry overhead.

## Build contracts

Use the manifest emitted by the ordinary frontend build:

```clojure
(ns build.prepare (:require [js.actor :as actors]))
(actors/build-one directory "prepare.bl" "prepare.mjs" []
  {:prune true :native-manifest (str frontend "/native-modules.json")
               :native-base "../../../../out"})
(actors/link-runtime! package-actor-dir "../../../out/actor")
```

The canonical compiler owns namespace declarations, aliases, privacy, callable
shapes and native ANF. `js.build/native-module-metadata` derives public mangled
exports, fixed arities and variadic minimums from that checked compilation.
Application initialization is not evaluated to discover exports. Native-enabled
providers are bounded by the manifest; imports are emitted only for retained
references. Arity checks run before pruning, including dead definitions.

`:native-links` remains a fixture/legacy adapter. Such explicit links default to
the JavaScript ABI; `:abi :bl` explicitly declares canonical BL values. They
cannot override manifest-owned exports. Production packages should consume the
compiler manifest instead of maintaining export tables.

`native-module-test.bl` checks manifest emission, privacy, mangling, fixed and
variadic arities, warm/cold linking, parent isolation and value-module packaging.
`linked-values.bl` exercises canonical collection, decimal and float identity
through direct and indirect imported calls. JavaScript-only import checks retain
missing-`#js` diagnostics.

The ordinary editor lowering still refuses `receive`. Promoting actor execution
to every ordinary module, sharing the compiled core and migrating the live
evaluator remain explicit consolidation work; the shared native-expression
emitter, values, contracts and runtime ownership are the verified foundations.

### Canonical values and artifact identity

Actor frames now reuse `priv/lib/js/rt.mjs` keywords, lists, tuples,
vector tries, persistent HAMT maps and sets. Map updates share tree nodes;
they no longer clone the whole table. Mutable actor tables remain distinct,
runtime-bound host handles with explicit destruction and capacity limits.
Record adapters use canonical maps tagged with `:__struct__`.

When packaging the host, call `write-runtime! source-dir output-dir value-url`.
The URL must name the **same module** imported by the frontend's compiled
modules. Copying `rt.mjs` into an actor-specific directory creates separate
keyword caches and classes and breaks identity. For Pelagic's existing layout,
the host at `pkg/pelagic/actor/host.mjs` binds `../../../out/rt.mjs`.
The source-tree host uses the source-tree canonical runtime; the research HTTP
server explicitly serves the canonical runtime dependencies.

Canonical arithmetic and literal lowering now also preserve float identity and
exact decimals. Checked actor callables can now enter the canonical callable ABI; compiled
core/prelude ownership and the two lowering entrypoints remain tracked
consolidation work. Native JS objects retain identity and native JS
numbers remain native at the explicit interop boundary.


The actor compiler delegates literals to `js.emit/lit-js`, arithmetic to the
canonical runtime, and reference traversal/namespace rewriting to `system.ir`.
Literal data and annotations are opaque: a quoted map containing `:op :global`
is data, not a dependency. `system.suspension` provides a conservative,
annotation-independent fixed point for checked callback integration;
synchronous is separate from pure, and creating a closure is separate from
executing its body. Unknown callees fail closed.

### Checked callbacks enter the same machine

`system.suspension` inspects checked ANF, every arity arm and reachable calls.
Creating a closure is synchronous; executing a `receive` is not. Unknown dynamic
calls fail closed, and an authored annotation cannot establish a proof. The actor
emitter attaches the resulting evidence to its callable, not to a second compiled
body. A JavaScript callback enters `runTurn` with that same generator factory.
Captured values, arity dispatch, nested calls and thrown values retain their BL
semantics. Actor-state operations also require an actor event entrypoint: an
external host callback has no actor identity to borrow. An unproved callback
needs that entrypoint instead.

The synchronous entry has a hard 100,000-machine-step limit, including inside a
critical section. This bounds machine execution, not wall time inside an opaque
native function. Cancellation is thrown at the suspension point with a separate bounded cleanup
reserve for finalizers. Failure restores critical depth and never schedules an
abandoned continuation. Synchronous proof is neither a purity nor a termination proof.

`priv/lib/js/native-values.mjs` now owns conversion for both entrypoints. Its only
execution hooks are callable dispatch, collection realization and callback proof
validation. Decimal conversion, float boxing, cyclic values, prototype-safe object
construction, lazy/set/tuple refusal and native function round trips therefore
have one implementation. `write-runtime!` includes this shared source in packaged
actor artifacts. The ordinary build includes it beside `interop.mjs`.

Compilation runs in an isolated registry scope and masks ambient BEAM links for
manifest-owned native exports. A warm compiler VM must generate the same native
import as a cold one, without initializing or changing the provider in its parent
scope. This is necessary for reproducible builds, not a new user-facing API.

`native-test.bl` builds the numeric and callback fixtures; their Node tests then
exercise emitted code, alongside the lower-level callback and conversion tests.

### Library ownership and package builds

`js.actor` is now the library compiler. Its shipped runtime lives under
`priv/lib/js/actor/`: `runtime.bl` owns scheduling policy; `host.mjs` owns the
frame engine and host leaves; `native.mjs` binds the shared value boundary.
Research `compiler.bl` contains fixtures and placement experiments and requires
this library. Research host modules are compatibility re-exports, and the
research scheduler source is a symlink to the canonical BL source.

A package build requires the library directly:

```clojure
(ns my.build (:require [js.actor :as actors]))
(actors/build-one scratch "prepare.bl" "prepare.mjs" []
  {:prune true :native-manifest (str frontend "/native-modules.json")
               :native-base "../../../../out"})
(actors/link-runtime! package-actor-dir "../../../out/actor")
```

The ordinary frontend build publishes its single engine at `out/actor/`.
`link-runtime!` writes re-exports to that engine, preserving module identity
and the shared canonical `out/rt.mjs`. It does not create another runtime.
`write-runtime!` remains available for standalone deployments that explicitly
supply a canonical value-module URL. The old three-argument form delegates to
the shipped implementation, so a research compatibility file cannot accidentally
be packaged as an engine.

This ownership change does not finish ordinary lowering migration. The legacy
actor collection prelude and direct emitter still require consolidation against
the common compiled core and actor control. They remain explicit roadmap items;
removing them before their consumers migrate would break existing semantics.
