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
