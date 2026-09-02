# The build is a program: source-graph, build-plan, and what "fresh" means

An executable document (`bl doc run docs/build/the-build-is-a-program.bl.md`).
It walks the three `.bl` modules in `priv/boot/` that decide what `mix compile`
does, and runs them on the tree they live in.

```beam-lisp
(ns docs.build.the-build-is-a-program
  (:require [source-graph :as sg] [ns-interface :as ni] [build-plan :as bp]))
```

## The tiers

beam-lisp's own sources live in three tiers under `priv/`, and the tier says
how a change propagates:

- `boot/` — the toolchain: reader, compiler, `core`, `sugar`, data readers, and
  the three build modules this document is about. Anything here can alter
  *every* emitted byte, so the toolchain key hashes the **whole directory** and a
  change rotates every beam. The tier is closed under `:require` — the compiler
  needs only `reader-node`; nothing in it reaches outside — which is exactly what
  makes "hash the directory" the same as "hash the closure":

```beam-lisp
(def boot-files (Enum/to_list (sort (Path/wildcard "priv/boot/*.bl"))))
(def boot-nss (set (map (fn [p] (first (sg/header (File/read! p)))) boot-files)))
(def boot-reqs (set (mapcat (fn [p] (second (sg/header (File/read! p)))) boot-files)))
(println "boot namespaces:" (count boot-nss))
(println "boot requires outside boot:" (remove (fn [r] (contains? boot-nss r)) boot-reqs))
```

- `std/` — the standard library, keyed per namespace.
- `lib/` — batteries (`datom`, `auth`, `live`, `loom`, `veritas`, `z3`, …), keyed
  per namespace, optional in a release.

## One parser

A source file's node in the graph is its `(ns …)` header: the declared name and
the namespaces it requires. There is exactly one reading of that header —
`source-graph/header`, which uses the real reader — because a second parser
(the build used to have a regex twin) is a second place for the build and the
runtime to disagree about what a `:require` is.

```beam-lisp
(println (sg/header "(ns a (:require [b :as bb] c))\n; (:require [not-an-edge])\n(def s \"(:require [nor-this])\")"))
```

## The plan: one traversal, three answers

The build asks three questions of the graph — in what order? which files can
compile in parallel? what is each file's freshness key? — and
`build-plan/plan` answers all three from **one** post-order traversal. Each node
is expanded once; its closure is the union of its requires' closures (a map
merge, never a sort); its wave is one more than its deepest require's; and the
order it is emitted in is the topological order. The cost is
O(V + E + Σ|closure|), which `test/bl/build_plan_test.bl` pins by timing a star
graph at 400 and 4000 nodes.

```beam-lisp
(def files (Enum/to_list (sort (Path/wildcard "priv/**/*.bl"))))
(def t0 (erlang/monotonic_time :millisecond))
(def nodes (Enum/to_list (map (fn [p] (bp/node-from p (File/read! p))) files)))
(def t1 (erlang/monotonic_time :millisecond))
(def plan (bp/plan nodes))
(def t2 (erlang/monotonic_time :millisecond))
(println "sources:" (count files) "  read+node:" (- t1 t0) "ms   plan:" (- t2 t1) "ms")
(println "waves:" (count (:waves plan)) " sizes:" (map count (:waves plan)))
```

The first wave is the leaves — everything that requires nothing but the ambient
prelude — and it is wide. That width is the parallelism `mix compile --jobs N`
uses: each wave compiles concurrently, each source in its own process, and the
next wave starts when the whole previous one has landed.

## What "fresh" means

A beam is fresh iff its **key** matches. The key of a namespace D is a sha256
over one line per member of D's require-closure, D included. Before the
interface work (`interface-keys.bl.md`) every line was `member:content-hash`;
now a member contributes its **interface** hash where the build can prove that is
all D observes, and its content hash otherwise. Without interface fields on the
nodes the key is byte-identical to the old closure hash:

```beam-lisp
(def plain (fn [p c] (let [[ns reqs] (sg/header c)] {:path p :ns ns :reqs reqs :hash (sha256-hex c)})))
(def plain-nodes (Enum/to_list (map (fn [p] (plain p (File/read! p))) files)))
(def by-ns (into {} (map (fn [n] [(:ns n) n]) plain-nodes)))
(def plain-key (get (:key (bp/plan plain-nodes)) "priv/std/optics.bl"))
(def closure-key (sg/closure-hash "optics"
                   (fn [n] (:hash (get by-ns n)))
                   (fn [n] (:reqs (get by-ns n) []))))
(println "plain plan key == closure-hash:" (= plain-key closure-key))
```

Three consumers hold that key and must agree:

1. the build's **manifest** (`_build/…/compile.beam_lisp`) stores it per source;
2. the emitted beam's **stamp** (`__bl_provenance__/0`) carries it;
3. the runtime **drift gate** (`BeamLisp.AOT.stale?/2`) recomputes it from live
   sources before trusting a beam.

They agree because there is one definition: the build calls `plan` over every
source; the stamp and the gate call `key-for`, which walks one namespace's
closure by name, builds the same nodes with `node-from`, and calls the same
`plan`.

```beam-lisp
(def resolve (fn [ns] (let [n (get by-ns ns)] (if n (File/read! (:path n)) nil))))
(println "key-for == plan key, every namespace:"
         (every? (fn [n] (= (bp/key-for (:ns n) resolve nil) (get (:key plan) (:path n))))
                 (take 40 (filter :ns nodes))))
```

## Reproducible by construction

None of this is worth anything if the same source can produce two different
beams — the cache would serve either, the oracle could not compare, "did this
edit change the output?" would have no answer. It could, before this work: 247
of 303 beams differed between two builds of the same tree. Four leaks of build
history into emitted bytes were found and closed, each in both compilers:

1. **template gensyms** — a macro bakes `x#` as `base__N__auto` at `defmacro`
   time and every expansion carried that N (the compiling process's counter when
   `core.bl` compiled). Each expansion now renames baked names to canonical
   `base__M__c` from the *unit's* counter.
2. **forward references** — a call to a `defn` defined later in the same file
   compiled to a dynamic invoke in a fresh VM but a direct call in a warm one.
   Every `defn` in a unit is now pre-linked before any form compiles.
3. **map literals through macros** — Erlang enumerates atom keys in atom-creation
   order, which differs serial vs. parallel. `data->form` sorts entries.
4. **worker-owned ETS** — the `defnative` declarations table died with the build
   worker that created it. It is owned by the pinned loader process now.

The property is pinned by `test/beam_lisp/aot_reproducible_test.exs`: serial,
parallel, and post-perturbation builds emit byte-identical beams.

## Where the Elixir still is

The build driver in `lib/mix/tasks/compile.beam_lisp.ex` is now a thin shell:
discover sources → `BuildPlan.plan_paths` → for each wave, `Task.async_stream`
over `AOT.compile_file` → write the manifest. What it cannot be is `.bl`:
`Mix.Task.Compiler` is an Elixir behaviour, and the toolchain key that validates
the bootstrap seed runs *before* the language exists. Everything the driver
*decides* — order, waves, keys, coverage — is already in the three modules
above, in the language.
