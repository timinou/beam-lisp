# The build is a program: source-graph, build-plan, and what "fresh" means

An executable document (`bl doc run docs/build/the-build-is-a-program.bl.md`).
It walks the `.bl` modules in `priv/build/` that decide what `mix compile`
does, and runs them on the tree they live in.

```beam-lisp
(ns docs.build.the-build-is-a-program
  (:require [source-graph :as sg] [ns-interface :as ni] [build-plan :as bp]))
```

```bl-result cell0
:docs.build.the-build-is-a-program
```

## The tiers

beam-lisp's own sources live in tiers under `priv/`, and the tier says
how a change propagates:

- `boot/` — the CODEGEN: reader, compiler, `core`, `sugar`, data readers, and
  the Core-Erlang backend (`anf`, `lower`). Anything here can alter *every*
  emitted byte, so the **codegen key** hashes the **whole directory** and a
  change rotates every beam. The tier is closed under `:require` — the compiler
  needs only `reader-node`; nothing in it reaches outside — which is exactly what
  makes "hash the directory" the same as "hash the closure":

```beam-lisp
(def boot-files (Enum/to_list (sort (Path/wildcard "priv/boot/*.bl"))))
(def boot-nss (set (map (fn [p] (first (sg/header (File/read! p)))) boot-files)))
(def boot-reqs (set (mapcat (fn [p] (second (sg/header (File/read! p)))) boot-files)))
(println "codegen namespaces:" (count boot-nss))
(println "codegen requires outside its tier:"
         (remove (fn [r] (contains? boot-nss r)) boot-reqs))
(def drv-files (Enum/to_list (sort (Path/wildcard "priv/build/*.bl"))))
(def drv-nss (set (map (fn [p] (first (sg/header (File/read! p)))) drv-files)))
(def drv-reqs (set (mapcat (fn [p] (second (sg/header (File/read! p)))) drv-files)))
(println "driver namespaces:" (count drv-nss))
(println "driver requires outside codegen+driver:"
         (remove (fn [r] (or (contains? drv-nss r) (contains? boot-nss r))) drv-reqs))
```

```bl-result boot-files
:ok
```

- `build/` — the BUILD DRIVER: `build`, `build-plan`, `source-graph`,
  `ns-interface` — the three modules this document is about, plus the driver that
  calls them. None of them can change an emitted byte, so they carry their **own
  key** (`AOTCache.build_key/0`, which folds the codegen key in, because the
  codegen compiles the driver). Editing a build-tool file used to rotate the
  toolchain key and rebuild every beam in the tree; now it rebuilds the driver.
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

```bl-result cell2
:ok
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

```bl-result files
:ok
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

```bl-result plain
:ok
```

Three consumers hold that key and must agree:

1. the build's **fact log** (`_build/…/build.log`; `priv/build/build-log.bl`)
   records it per source — the manifest beside it is that log's PROJECTION,
   written for Mix to read and for nothing else;
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

```bl-result resolve
:ok
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

## The driver: `build/run`

The build itself is `priv/build/build.bl`. One function, one map in, one map out:

```
(build/run {:sources [paths] :out "dir" :manifest "path" :log-path "path"
            :force? bool :jobs n :log fn})
→ {:built n :errors [msg …] :manifest {path {:hash key :key tier :modules [mod …]}}}
```

It plans the sources (`build-plan/plan` over `node-from`), walks the waves,
and inside each wave runs `build-one` for every source that is not fresh —
in parallel, `:jobs` at a time, results collected in order. A source is
**fresh** when the LOG records it under this key and this tier key, and every
module it names is on disk. `build-one` asks the shared cache first
(`AOTCache.fetch`); on a miss it compiles and publishes, and the wave APPENDS a
fact per source (`build-log/append!`) — so an interrupted build resumes from the
last complete fact, where the old single-document manifest could not be resumed
at all. At the end one compaction writes the log's current state, and the
manifest as its projection. Sources that vanished lose their beams. A source the
reader rejects is one entry in `:errors` — the rest still builds.

The log is also the build's QUERY SURFACE, which a manifest could never be:
`build-log/stale` (what a build would recompile, in plan order),
`build-log/impact` (everything an edit reaches — the reverse of the plan's
`:deps`), and `build-log/coverage` (how much of the plan the log accounts for,
and which facts are missing). `BeamLisp.BuildLog` is the Elixir call surface.

A run also carries an optional ELIXIR SUBSTRATE stage (`priv/build/substrate.bl`,
`[:build/ex path hash [modules]]` facts in the same log): `lib/**/*.ex` minus
the Mix-task shells and the dev server, compiled in ONE
`Kernel.ParallelCompiler` batch — one batch, because the parallel compiler
resolves cross-file dependencies itself, and still a FACT PER FILE, because
every compiled module reports the file it came from in its compile info.
Freshness is the content hash, and the module list is recorded so a beam that
vanished pulls its own source back into the build. This is the stage that lets
the shipped `bl` compile a project's Elixir sources with no Mix project, no
`_build` and no `MIX_ENV` — Elixir's compiler ships in the payload.

The same function has two shells, and neither decides anything:

- `mix compile.beam_lisp` — flag parsing, the project's compile and manifest
  paths, `Bootstrap.install!` + `AOT.boot` so the language is up, one call,
  the tuple Mix wants back.
- `bl build PATH… [--out DIR] [--force] [--jobs N]` — the same call from the
  escript; the manifest lives in the output dir.

A literate document (`.bl.md`, `.bl.org`) is a source like any other: the
build reads it through `Loader.read_source/1`, the same extractor the loader
uses when it is required, so a document compiles to exactly the program it
loads as.

Pinned by `test/bl/build_test.bl`: fresh tree, no-op, body edit → 1, interface
edit → closure, broken source → error, deleted source → swept, a poisoned
manifest costs nothing (the projection is repaired, never trusted), the log is
the memory, `clean` removes both files.

## Where the Elixir still is

`Mix.Task.Compiler` is an Elixir behaviour, and the codegen key that
validates the bootstrap seed runs *before* the language exists — so the two
shells above are Elixir, and so is the substrate they boot. Everything the
build *decides* — order, waves, keys, coverage, freshness, what to run and
when — is in the language.
