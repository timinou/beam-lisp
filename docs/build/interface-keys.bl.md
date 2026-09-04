# Interface keys: why editing a function body rebuilds one file, not thirty-five

This is an executable document. Every ```` ```beam-lisp ```` cell runs against the
tree it lives in (`bl doc run docs/build/interface-keys.bl.md`), so the numbers
below are measured, not remembered.

```beam-lisp
(ns docs.build.interface-keys
  (:require [source-graph :as sg] [ns-interface :as ni] [build-plan :as bp]))
```

```bl-result cell0
;; error: namespace not found: source-graph (searched: ["docs/build", "/home/user/code/undefine/beam-lisp--self-hosted", "/home/user/code/undefine/beam-lisp--self-hosted/../beam-lisp/bl/beam_lisp/priv"])
```

## The problem, in one number

Before this work, `mix compile` keyed each namespace's freshness on the
**content** of everything in its require-closure. Sound — nothing stale could
ever survive — and wildly conservative. Touch a comment in `datom.store` and
every namespace that transitively required it was rebuilt:

```beam-lisp
(def files (Enum/to_list (sort (Path/wildcard "priv/**/*.bl"))))

(defn content-node [p c]
  (let [[ns reqs] (sg/header c)]
    {:path p :ns ns :reqs reqs :hash (sha256-hex c)}))

(def content-nodes (Enum/to_list (map (fn [p] (content-node p (File/read! p))) files)))
(def content-plan (bp/plan content-nodes))

(defn dependents-of [plan x]
  (count (filter (fn [n] (and (:ns n) (not= (:ns n) x)
                              (contains? (set (get (:closure plan) (:ns n))) x)))
                 content-nodes)))

(println "namespaces that transitively require datom.store:" (dependents-of content-plan "datom.store"))
```

```bl-result files
;; error: function :sg.header/1 is undefined (module :sg is not available)
```

Thirty-four dependents plus itself: **35 beams** for a change that altered zero
of their bytes.

## Why their bytes cannot change

Look at what a compiled namespace actually bakes in about a namespace it
requires. The compiler (`priv/boot/compiler.bl`, `compile-call`) lowers a call
`(store/-get s k)` one of two ways:

- if `store/-get` is **linked** — a `defn` with a known arity map — it emits a
  direct BEAM call `BeamLisp.Ns.Datom.Store.-get(s, k)`. The caller's bytes hold
  the callee's *module name*, *function name* and *arity*.
- otherwise it emits `RT.invoke(Env.fetch!("datom.store", "-get"), [s, k])`. The
  caller's bytes hold the *namespace name* and *var name*.

Either way, what is **inside** `-get`'s body is invisible to the caller. Change the
body and the caller's compiled code is byte-for-byte the same. (Reproducibility
of that fact is itself pinned: `test/beam_lisp/aot_reproducible_test.exs`.)

The exception is a **macro**. A macro's expansion is inlined into the caller at
compile time, so a macro's body *is* part of what a caller observes.

## The interface: exactly what a caller can observe

So a namespace has an **interface** — the part of it a dependent's bytes can depend
on — and it is small and enumerable. Read straight off the compiler's cross-
namespace reads, it is:

| what the compiler reads | why it matters to a caller |
|---|---|
| the set of defined **names** | a missing name is a compile error |
| each name's **kind** (fn · macro · value · record · protocol …) | a macro *expands*; a fn *calls* |
| a fn's **arities** and variadic minimum | decides direct call vs. dynamic invoke |
| whether a var is **private** | calling it is a compile error |
| a **macro's whole definition** | its body is inlined at every call site |
| a **protocol's** method names and arities | dispatch is by name/arity |
| a **defnative's** crate and signatures | a host module the caller links to directly |

Not in the interface: fn bodies, `def` values (fetched at runtime), docstrings,
comments, whitespace.

`ns-interface/lines` renders it as sorted lines, one per definition:

```beam-lisp
(doseq [l (ni/lines (File/read! "priv/lib/datom/store.bl"))]
  (println " " (if (> (count l) 90) (str (subs l 0 90) "…") l)))
```

```bl-result cell2
;; error: function :ni.lines/1 is undefined (module :ni is not available)
```

and `ns-interface/hash` is the sha256 of those lines. The properties the build
relies on are pinned in `test/bl/ns_interface_test.bl`; here are the two that
matter, live:

```beam-lisp
(def store-src (File/read! "priv/lib/datom/store.bl"))
(println "body edit keeps the hash:  "
         (= (ni/hash store-src) (ni/hash (str store-src "\n;; a comment\n"))))
(println "new arity moves the hash:  "
         (not= (ni/hash store-src) (ni/hash (str store-src "\n(defn scan-datoms [a b c d] nil)\n"))))
```

```bl-result store-src
;; error: function :ni.hash/1 is undefined (module :ni is not available)
```

## Soundness: the coverage rule

There is a hole. A top-level form produced by a **macro** — `(defsmell …)`,
`(deftest …)` — defines a name the reader does not see as a definition. The
interface scan would miss it, and a dependent calling that name would not be
rebuilt when it changed.

The build does not hope this never happens; it checks. For each edge D → X it
compares the names D references in X (`source-graph/references`, a walk of D's
reader forms, so a name in a comment or string never counts) against the names
X's interface accounts for (`ns-interface/names`). Only if **every** referenced
name is covered may X's interface stand in for its content on that edge.
Otherwise the edge keeps the content hash — exactly today's behaviour. The
interface can only ever *remove* rebuilds it has proven unnecessary.

```beam-lisp
(def index-src (File/read! "priv/lib/datom/index.bl"))
(println "datom.index references into datom.store:" (get (sg/references index-src) "datom.store"))
(println "all covered by store's interface:       "
         (every? (fn [n] (contains? (set (ni/names store-src)) n))
                 (get (sg/references index-src) "datom.store")))
```

```bl-result db-src
;; error: function :sg.references/1 is undefined (module :sg is not available)
```

A `:refer :all` edge is never coverable — bare names cannot be attributed — and
the reference scan says so explicitly:

```beam-lisp
(println (sg/references "(ns q (:require [x :refer :all]))\n(defn f [] (g 1))"))
```

```bl-result cell5
;; error: function :sg.references/1 is undefined (module :sg is not available)
```

## The key

With the interface fields on each node, `build-plan/plan` computes, for each
namespace D, a key over D's **whole** require-closure — not just its direct
requires. That matters: if T requires D and D's macro expands into `(X/f …)`,
then T's bytes bake X's link shape, so T observes X's interface transitively.
For each closure member X the line is:

- X's **content** hash if X is D itself (its own edit must rebuild it), or if any
  requirer of X inside D's closure has an uncovered edge to X;
- X's **interface** hash otherwise;
- `X:?` if X does not resolve (a require that stops resolving is a change).

Without the interface fields the key is byte-identical to the old closure hash
— pinned by `plan-without-interface-fields-is-the-closure-hash`.

## The number, after

```beam-lisp
;; `build-plan/node-from` is THE node constructor — the build and the runtime
;; gate both call it, which is what makes their keys comparable.
(def iface-node bp/node-from)

(def iface-nodes (Enum/to_list (map (fn [p] (iface-node p (File/read! p))) files)))
(def k0 (:key (bp/plan iface-nodes)))

(defn rebuilds-after [path edit]
  (let [nodes2 (Enum/to_list (map (fn [n] (if (= (:path n) path) (iface-node path (edit (File/read! path))) n)) iface-nodes))
        k1 (:key (bp/plan nodes2))]
    (count (filter (fn [p] (not= (get k0 p) (get k1 p))) (keys k0)))))

(doseq [p ["priv/lib/datom/store.bl" "priv/lib/datom/vector.bl" "priv/std/typed.bl" "priv/std/interop.bl"]]
  (println p
           "  body edit →" (rebuilds-after p (fn [s] (str s "\n;; touched\n")))
           "  interface edit →" (rebuilds-after p (fn [s] (str s "\n(defn zz-new [a] a)\n")))))
```

```bl-result iface-node
;; error: function :sg.forms/1 is undefined (module :sg is not available)
```

A body edit rebuilds **one** file. An interface edit rebuilds the dependents —
the same set as before, because that is the honest answer.

## One key, two callers

The runtime has a drift gate (`BeamLisp.AOT.stale?/2`): before trusting an AOT
beam it recomputes the key from the live sources and compares it to the stamp
the build wrote into the beam's `__bl_provenance__/0`. If the gate computed the
key any differently from the build, every beam would look stale on every boot.

So there is exactly one definition. The build calls `build-plan/plan` over every
source; the gate calls `build-plan/key-for`, which resolves the one namespace's
closure by name, builds the *same* nodes, and calls the *same* `plan`:

```beam-lisp
(def by-ns (into {} (map (fn [n] [(:ns n) n]) iface-nodes)))
(def resolve (fn [ns] (let [n (get by-ns ns)] (if n (File/read! (:path n)) nil))))
(println "gate key == build key for datom.store:"
         (= (bp/key-for "datom.store" resolve nil)
            (get k0 "priv/lib/datom/store.bl")))
```

```bl-result resolve
;; error: function :bp."key-for"/3 is undefined (module :bp is not available)
```

That equality is the whole freshness contract.
