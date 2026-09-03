# Proof-directed native offload

The BEAM has no way to run a function without a garbage collector. But it has a
way to run a function *outside the BEAM*: a NIF, a native function the VM calls
directly. Inside a NIF there is no heap, no collector, no reduction counting —
and no safety net. A NIF that loops forever freezes a scheduler; a NIF that
crashes takes the node with it; a NIF that runs for 2 ms starves every other
process on its scheduler.

So the question "which functions may become NIFs?" is exactly the question
"which functions can we *prove* will not do those things?" beam-lisp proves
each of them already. Offload is the conjunction.

## Eligibility is four theorems

```
offloadable(f) ⇐  footprint(f) = ∅                    pure: no resource in any mode
                ∧ terminates(f)                        every recur shrinks a measure
                ∧ ∀ arg. sort(arg) ∈ NifSorts          Int · Real · Bool · binary · tuples of those
                ∧ work(f) ≤ W(size(args))              a cost bound, derived from the measure
```

The first three are shipped engines: `system.footprint`, `termination`, and
`typed` with `system.smt/sort-of-tags`. The fourth is new but small: the
termination proof already exhibits a measure that decreases by at least one
per `recur`; counting the ops in the loop body gives `work ≤ k · measure₀`.
That number picks the scheduler:

| bound | scheduler | why |
|---|---|---|
| provably < ~1 ms on the largest sort | normal | the VM's own guideline for a NIF |
| polynomial in input size | dirty CPU | runs on a separate thread pool, never blocks a scheduler |
| unbounded or `:untranslatable` | **not eligible** | preemption is the guarantee a NIF gives up; without a bound we may not give it up |

## The pipeline

```
defn ──eligible?──▶ bl-ANF of f ──lower──▶ Rust (native/<ns>/src/gen.rs) ──cargo──▶ .so
      ──defnative──▶ the var's shim now forwards to the NIF stub      (native.ex, shipped)
      ──oracle────▶ veritas.property: ∀ x ∈ gen(sig). (f_bl x) = (f_nif x), shrunk on mismatch
```

```clojure
(ns memory.native
  (:require [system.footprint :as fp] [termination] [typed] [system.smt :as smt]
            [veritas.property :as prop] [self.anf :as anf]))

(def nif-sorts #{"Int" "Real" "Bool" "String"})       ; String = binary, after doc 03's tag split

(defn eligible
  "The offload verdict for a defn node, with the reason when refused. Every
   refusal names the theorem that failed — never a silent fallback."
  [node]
  (let [fpr (fp/footprint node)
        trm (termination/check node)
        srt (map smt/sort-of-tags (typed/arg-tags node))
        wrk (work-bound node trm)]
    (cond
      (seq fpr)                        {:no :impure     :footprint fpr}
      (not (:ok trm))                  {:no :may-diverge :recur (:failing trm)}
      (not (every? nif-sorts srt))     {:no :sort        :sorts srt}
      (nil? wrk)                       {:no :unbounded}
      :else                            {:yes (if (< (:worst-ns wrk) 1000000) :normal :dirty-cpu)
                                        :work wrk})))

(defn lower
  "bl-ANF → Rust source. The eligible fragment is tiny: scalar arithmetic,
   binary indexing (with a proven in-bounds index), tuples, let, if/case on
   scalars, and tail-recursive loops → `loop {}`. Types come from the tag
   lattice; encode/decode is rustler's."
  [anf sig] …)

(defn certify
  "The differential oracle: the bl reference impl vs the NIF over the
   generator for the signature. A mismatch is shrunk to the smallest input."
  [f-bl f-nif sig]
  (prop/for-all [x (prop/gen sig)] (= (f-bl x) (f-nif x))))
```

Two obligations beyond the four theorems, both discharged by `system.smt`:

- **No out-of-bounds index.** Every `(nth b i)` in the fragment needs
  `0 ≤ i < (count b)` as a proof obligation, or the NIF may panic. Rust panics
  are caught by rustler as `{:error …}`, but the point is to emit no panicking
  path at all.
- **No integer overflow.** BEAM ints are bignums; Rust `i64` is not. Either the
  proof bounds the values, or the lowering uses checked arithmetic and the
  overflow branch returns to the bl implementation.

## What the author sees

Opt-in at the var — `^{:native true}` — or at the namespace. The var keeps its
name; callers cannot tell, because the shim/body topology that `emit.ex` uses
for every `defn` is what `defnative` already uses for a NIF stub. Build time
needs cargo; run time needs nothing new (`drop` bundles the `.so` as it bundles
the datom crates).

A refusal is a diagnostic naming the failed theorem:

```
memory.native: dot-product refused — footprint {:io :W} (println at line 14)
memory.native: parse-header refused — recur on (f xs) is not provably shrinking
memory.native: checksum ok — dirty-cpu (work ≤ 3·len(bytes), worst 40 ms at 64 MB)
```

## Speed · quality · provability

**Speed.** Large, and only on the class where the BEAM is weakest: tight
numeric and binary loops — boxed floats, no SIMD, a reduction check per
iteration. Expect 5–50× there and nothing elsewhere. The counter-cost is the
call: ~100 ns of NIF entry plus term copy proportional to argument size, so a
proven-cheap function over a large binary can *lose*. The work bound must
include the argument size, which it does — `translate-len` already abstracts a
collection to its length, and `work` is a function of that length.

**Quality.** Better than a hand-written NIF in every dimension that matters:
there is always a bl reference implementation, the NIF is a certified
refinement of it, the certification is a shrinking property test, and the
eligibility proof names exactly what the NIF may not do. Rust's own
guarantees cover memory safety inside the NIF; the bl proofs cover the
contract with the VM.

**Provability.** Neutral for callers, by construction. The NIF is opaque to
`footprint`, but it *inherits* `footprint = ∅` from the bl source it was
derived from, so every proof about a caller is unchanged. The rule to keep:
**proofs run over the bl source; the NIF is a certified refinement.** Nothing
whose proof is `:untranslatable` is ever offloaded.

## Where it lives

- `system.footprint`, `termination`, `typed` + `system.smt/sort-of-tags` — the
  three shipped theorems.
- `veritas.property` — the differential oracle.
- `BeamLisp.Native` / `defnative` — the shipped NIF host.
- `self.anf` (see `docs/core-erlang/`) — the IR the Rust lowering reads.
- `memory.native` (to build) — eligibility, the work bound, the Rust lowering,
  certification.
