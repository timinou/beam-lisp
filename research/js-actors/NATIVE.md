# Native operations inside actor namespaces

This checked compiler prototype accepts the existing native namespace annotation:

```clojure
(ns ^:js app.prepare (:require [app.kernel :as kernel]))
(defn worker []
  (receive
    [:job caller input]
      (let [output (kernel/compute input)]
        (.postMessage js/self #js {:op "result" :output output})
        (rt-send caller [:done]))))
```

`kernel/compute` links to a synchronous, already compiled BL export. The actor
calls the ES import directly, with unchanged arguments and result. There is no
`host/emit` round trip, encoding, Promise, callback dispatch or actor call frame
on that edge. Local actor messages can carry native references without copying.
Native object identity survives a send/receive in the same realm. Workers still
have their explicit cross-thread structured-clone boundary.

The build API has a fifth options argument:

```clojure
(build-one directory "prepare.bl" "prepare.mjs" []
  {:prune true
   :native-links {"app.kernel/compute"
                  {:path "../../out/app.kernel.mjs"
                   :export "d_compute" :arities #{1}}}})
```

The manifest is build configuration, not another source namespace declaration.
Use a source provider declaring the public export, as with ordinary BL requires.
Only annotated source files may use native links. The canonical reader/compiler
own annotation, privacy, aliases and native ANF. `system.js/check!` rejects known
BL collections crossing native JS operations without `#js` or `bl->js`.
`js.emit/emit-native` owns JS evaluation order in both profiles.

The host's `native.mjs` owns the actor profile's value checks and explicit
`bl->js`/`js->bl` conversions. Native objects and primitive numbers are unchanged.
The sync profile's BL collection representation is different from the actor
profile's: linked helpers must use native JS arguments/results, not silently pass
profile-specific BL collections. This is a native ABI link, not a claim that both
BL collection ABIs have been unified. A suspending actor function cannot be a
synchronous JS callback; it fails clearly. Native synchronous callbacks can be
passed directly. Ordinary actor calls still use the existing generator machine.

The regular `js/build!` sync profile still refuses `receive`. This integration
lives in the checked actor compiler; promotion to the normal package linker is a
separate step. No new scheduler or reader was introduced.

Run the focused build/refusal checks in one capped BL VM:

```
bin/bl run -p research/js-actors research/js-actors/native-test.bl
node research/js-actors/native-fixture.test.mjs
node --test research/js-actors/native-values.test.mjs
```

With `:prune true`, the emitter keeps only ANF-reachable definitions from `main`,
`bl-main` and optional `:roots`. Function values count as edges; hidden receive
support counts as an edge. The complete source is reference-audited first, so
unreachable code cannot hide a forbidden host reference. A reachable dynamic
`host/ref` disables pruning and preserves the whole bundle. Aliases are emitted
only for retained targets. Native import arities and known missing `#js` arguments
are checked by `system.js` before pruning, including lexical let-bound values.
Native argument checks are omitted only for proved raw values; unknown values
keep checks. Actor-profile result wrapping is eliminated because native values
already have the profile's representation. Neither optimization changes syntax.


The ordinary namespace build now emits `native-modules.json` from the same checked
ANF that emits its modules. Public callable export names and fixed/variadic arities
are compiler-owned; private values and unknown callable shapes are excluded.
Callable shape recognition lives in `system.ir`, shared by the emitters and linker.
The actor builder consumes it with:

```clojure
{:native-manifest "/build/out/native-modules.json"
 :native-base "../../../out"
 :prune true}
```

Only annotated namespaces are native link candidates. The actor emitter imports
only references retained in its bundle, so a manifest does not eagerly load every
exported module. A native-only call still imports the native boundary helpers even
when the app contains no explicit JS expression. `:native-links` remains a closed
foreign-function fixture/compatibility entrypoint during migration; packages should
consume the compiler manifest. This step does not yet unify collection values or
promote the actor backend to the ordinary build's sole execution model.

`native-module-test.bl` checks normal-build emission, source privacy, export
mangling, fixed/variadic contracts, and staging without application initialization.

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
