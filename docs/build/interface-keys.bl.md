# Interface keys: rebuild what a caller can observe

Run this lesson with:

```sh
bin/bl run docs/build/interface-keys.bl.md
```

A compiled call records a name, arity and binding shape. It does not copy an
ordinary function's body into every caller. The build uses that distinction.

## Try a body edit and an interface edit

```beam-lisp
(ns docs.build.interface-keys
  (:require [ns-interface :as ni]))

(def original "(ns example.provider) (defn one [] 1)")
(def body-edit "(ns example.provider) (defn one [] 2)")
(def interface-edit "(ns example.provider) (defn one [] 1) (defn zero [] 0)")

(assert (= (ni/hash original) (ni/hash body-edit)))
(assert (not= (ni/hash original) (ni/hash interface-edit)))
(assert (contains? (set (ni/names original)) "one"))
```

The body edit changes the provider's own key. The added public name changes its
interface key too, so covered consumers must be rebuilt.

## What belongs to an interface?

| Fact | Why a caller needs it |
|---|---|
| Names and definition kinds | Resolve a function, value, macro, record or protocol |
| Fixed arities and variadic minimum | Choose the valid call shape |
| Privacy | Refuse an inaccessible name |
| Macro definitions | Expansion becomes part of caller code |
| Protocol methods | Determine dispatch names and arities |
| Native signatures | Link the correct host function |

Ordinary bodies and runtime-fetched values are not interface fields. Comments
and whitespace do not add bindings.

## Use a smaller key only with coverage

`source-graph` records which dependency names a consumer references.
`ns-interface` records the names the provider's source declares. The build uses
an interface hash only when it can account for every referenced name.

An uncovered macro-generated binding keeps content-based invalidation.
`:refer :all` also needs conservative treatment. Macro providers and the helper
bodies that affect expansion invalidate their expansion-dependent consumers.
Unknown coverage means rebuild, not guess.

## One plan serves build and runtime

`build-plan` is the shared key implementation. The build writes a key into the
emitted module; the AOT gate recomputes it from the live resolution context.
Captured search roots keep the same namespace tied to the correct project.

A validation pass shares source reads. The next pass observes an edit, including
a same-length edit. Compiler generation is checked before expensive closure
validation. A scoped runtime repair updates needed units without deleting
unrelated output; a full build owns its complete inventory, including literate
source files.

## Predict the result

- Unchanged source and interface: reuse the unit.
- Covered ordinary body edit: rebuild the provider, reuse consumers.
- Interface edit: rebuild the provider and affected consumers.
- Macro dependency or compiler generation change: apply stronger invalidation.

Tests in `test/bl/incremental_aot_test.bl`, `namespace_incremental_integration_test.bl`
and `build_scoped_ownership_test.bl` check these boundaries with real emitted
modules. The [namespace loading guide](../namespace-loading.md) connects them
to deferred initialization and strict/repair behavior.
