# Optimising the runtime, from the numbers

Companion to `RESULTS.md`. Everything here is either **measured** (with the row
that measured it) or marked **estimate**. Estimates are for choosing what to do
next, never for claiming a result.

## 0. How to read these numbers

`decompose.bl` and `bench.bl`: monotonic time, best-of-3, results consumed, ns
per call, harness floor 13–20 ns.

**Point estimates drift 1.6–4× between runs on this host.** In one pair of runs
the Elixir runtime's own `compare` on 1000-element vectors measured 40 391 ns and
then 66 642 ns; `kind` measured 643 ns in one file and 159 ns in the next. So:

- **shapes and orders of magnitude are reliable** — "linear", "parity", "20×" —
- **point estimates are not**, and
- a before/after claim must come from ONE run with both arms, never from two
  numbers taken in different sessions.

## 1. The cost model

For `compare` on two n-element vectors the cost decomposes as

    T(n) ≈ R(a) + R(b) + W(n)

`R` is realization — turning each side into something walkable — and `W` is the
walk. Fitting the measured curve (`decompose.bl` section A/C, before the fix
below) gives:

| n | T, differ at FIRST | T, differ at LAST |
|---:|---:|---:|
| 10 | 5 955 | 12 512 |
| 100 | — | 128 874 |
| 1000 | 399 827 | 1 392 310 |

A difference at the FIRST element should cost O(1): compare one element, stop.
It cost 400 µs for n=1000 — **70% of the full walk**. So ~70% of the cost was
spent before the first element was compared. The shape said "a full pass
precedes the walk"; the source said the same thing:

```clojure
(defn- seq-cmp [a b]
  (cond
    (erlang/== (k/kind a) :lazy) (walk-cmp a b)
    (erlang/== (k/kind b) :lazy) (walk-cmp a b)
    :else (let [la (finite-list a) lb (finite-list b)]     ; full copy of BOTH
            (cond (proper? la) (cond (proper? lb) (list-cmp la lb)   ; + 2 more passes
                                   :else (walk-cmp a b))
                  :else (walk-cmp a b)))))
```

Two realizations, two `proper?` passes, then the walk — three to four O(n)
passes to answer a question that is usually decided by the first element.

**Fixed.** `seq-cmp` now dispatches on representation: two lists take the
cons-walking path, everything else is walked in place by `walk-cmp`, which
already knew how to step a sequence without copying it.

| row (1000-element vectors) | before | after |
|---|---:|---:|
| differ at the FIRST element | 399 827 | **2 058** |
| differ at the LAST element | 1 392 310 | 1 553 078 |

The prefix case is now O(1) — 194× — and the full walk is unchanged, which is the
point: the fix removed the wasted pass and left the real per-element cost
visible.

### What a walk step costs

| primitive | BL (ns) | Elixir (ns) |
|---|---:|---:|
| `kind` (vector) | 159–643 | 14–83 |
| `family (kind x)` | 459–607 | 14–18 |
| `seq` | 211–297 | 28–48 |
| `first` | 243–299 | 45–85 |
| `rest` | 348–480 | 44–78 |
| `next` | 473 | 54 |
| `to-list` of a 1000-list, per element | ~700 | ~8 |

One `walk-cmp` step does `k-compare(first xs, first ys)` then `next xs`, and
`k-compare` itself does `unwrap-meta` + 2× `kind` + 2× `family`. That is
**~1.5–2.2 µs of classification per element**, against a measured walk of
1 400–1 550 ns per element. The model and the measurement agree.

The Elixir runtime's walk is 40–66 ns per element, i.e. **20–35× less**, and the
reason is visible in the right-hand column: its per-element work is pattern
matching and C-level term comparison, not a call into a classifier.

## 2. Where the time actually goes

Five distinct causes, in order of size:

1. **List construction costs ~700 ns per element.** `rt/raw.bl`'s `cons` is five
   BIF calls (`make_tuple`, `tuple_to_list`, `setelement`×2, `lists:append`)
   because a runtime cannot call the language it implements, and a 2-tuple is not
   a cons cell. That figure is paid by every `to-list`, `map`, `filter`,
   `sort-elems`, and sequence realization. On the BEAM a cons is one instruction.
2. **Classification is redone per element.** `k-compare` re-derives `kind` and
   `family` for both operands on every step, though for two same-kind sequences
   the answer is a property of the pair, not of the step.
3. **`family` costs 459–607 ns on its own** — more than `kind`. It is asked once
   per element, twice per `k-compare`.
4. **Wasted passes.** Fixed for `seq-cmp`; still present for sets and maps, where
   `coll-cmp` **sorts both sides** to compare them (O(n log n) plus two
   realizations) when a count check plus membership would do.
5. **One extra remote call per operation** through the public namespace
   (`rt` → `rt/…`). Small (measured `map?` 28–38 through the facade against
   22–24 direct) but universal.

## 3. Levers — algorithmic and mathematical

No native code, no code generation. These are the ones to take first, because
they are cheap, safe, and the oracle already guards them.

### A1. Stop realizing to answer a prefix question — DONE

Evidence above. 400 µs → 2 µs on the prefix case.

### A2. Classify the PAIR, not the step — the big algorithmic one

A comparison between two sequences knows, once, that both sides are the same
family and the same representation. Beyond that, the elements of a faithful
sequence are *also* of one family. So the walk can run **monomorphic loop
bodies** — one per (family × family) pair — chosen once, with no `kind`, no
`family`, and no `unwrap-meta` inside the loop.

- **Estimated payoff**: per-element 1 400 ns → 150–250 ns, i.e. 6–10×, purely by
  hoisting invariant work out of a loop. This is the classic loop-invariant
  hoisting / type-specialisation transformation, and it is what the Elixir
  runtime gets for free from pattern matching.

### A3. Compare counts before elements where the order allows it

For `coll-cmp` (sets, maps) the count already short-circuits a mismatch. When
counts are equal, comparing canonical keys is O(n) membership rather than
O(n log n) sorting. For same-family sequences, order is lexicographic-then-length,
so a length difference does NOT decide the answer — but a *longest common prefix*
followed by one element comparison does, and the common prefix is computable by
a C-level scan (see B1).

### A4. `proper?` is redundant

A walk that reaches both ends has proved both are proper. Fold the check into the
walk; drop the extra pass.

### A5. Cache nothing that needs identity

There is no cheap value identity on the BEAM, and metadata wrappers make
structural equality a semantic question. Memoising `kind`/`family` per value
requires an identity the runtime does not have; a weak table would cost more than
it saves at these sizes. **Not a lever** — recorded so it is not re-proposed.

## 4. Levers — generated BEAM

The descriptor→BEAM path is already proven (`krt/emit.bl` emits
`Elixir.Krt.Intrinsics` and `Elixir.Krt.Specialized` through `anf/module` +
`lower/descriptor->beam`, with a byte-identical fixpoint). Neither of the two
items below needs the runtime to be finished first, and both are pure beam-lisp.

### B1. Generate the constructors — the biggest single number

Replace `rt/raw.bl`'s five-BIF `cons` with a generated module: one Core Erlang
cons cell, exactly what `Krt.Intrinsics.cons/2` already is.

- **Why it is safe**: the runtime needs a constructor it can reach without
  calling the language; a *generated* module is not the language, it is BEAM.
- **Why it fits the boot floor**: the generated module ships in the seed like
  every other boot beam. It is not a native extension and needs no NIF.
- **Estimated payoff**: ~700 ns → ~10 ns per cons. Every list-producing path in
  the runtime drops by 50–100×, and `to-list`/`map`/`filter`/`sort` are the paths
  the toolchain uses most.

### B2. Generate the classifier and `family` as one tag dispatch

`kind` is a 13-test `cond` chain and `family` a table lookup that costs 459–607 ns.
Both are pure functions of the term's tag, and the representation descriptor
table already drives generated code elsewhere.

- **Estimated payoff**: `kind` 159–643 → ~20 ns, `family` ~500 → ~20 ns.
- **Consequence**: this also makes A2's per-element work cheap even when the
  fast path does not apply.

### B3. Generate the facade

`rt.bl` exists so the compiler, the link table and every caller name ONE module
with a real export surface. Its clauses are mechanical delegations; emitting them
directly, so a hot leaf is one jump instead of two, is a code-generation problem,
not a design change.

## 5. Levers — → native

Native is not an alternative to the above; it is a different regime with a
measured entry price. From `research/rt-selfhost/invm/RESULTS.md`:

| entry | cost |
|---|---:|
| BL floor (a no-op call) | 0.136 µs |
| regular NIF, 256 B payload | **0.988 µs** — cap ≤4096 B and ≤65 536 body-ops×B |
| dirty-CPU NIF | 7.085 µs — cap ≤1 MiB |
| resident native port | 22.542 µs per call |
| fused BEAM, 1 MiB kernel | 50.066 ms |
| resident native, same kernel | **5.264 ms** (9.51× over fused BEAM, 28.35× over the transducer path) |

**The rule these numbers give.** A native kernel must do ≥ ~10 µs of work before
it beats generated BEAM, and ≥ ~50 µs before it is worth the fault-containment
loss (a NIF fault takes the VM; a port keeps it). Below that, dispatch dominates
— which is exactly why the leaf optimisations above are the right first move and
native is not.

**The shape it needs.** The native backend is Cranelift: counted scalar loops
over a **contiguous** layout. BEAM terms are boxed and scattered. So a native
kernel is applicable exactly when a region descriptor can promise a contiguous
projection — which is a *mathematical* statement about the representation, and
the bridge between the two halves of this document:

> If a representation is **faithful** — the semantic order on its elements equals
> the term order on their packed form, and equality is byte equality — then
> compare, sort, hash and bulk equality are contiguous-memory kernels.

That invariant is checkable per representation, and it is what
`priv/lib/native/eligible.bl` already gates on (footprint, termination,
`NifSorts`, work bound) plus `lower2/lower-kernel`'s second, finer gate.

Where it pays, in priority order:

1. **Bulk equality and longest-common-prefix on a packed form.** Directly attacks
   the compare hotspot: compare packed bytes, fall back to semantics at the first
   difference. A 1000-element comparison becomes one `memcmp`-shaped loop.
2. **Sort over packed keys.** Fixed-width keys sort as a counted loop; radix or
   merge at ~1–2 ns/key against 40–100 ns/key interpreted.
3. **`hash_key` over a packed view.** An O(n) BL walk becomes a C hash.
4. **Fused `map`/`filter`/`reduce`.** Already measured end-to-end; crossover
   256 B–1 KiB.
5. **NOT native**: per-value dispatch on heap tags (the classifier), single leaf
   operations, and anything whose data is not contiguous. These are the cases
   where a JIT gets *nothing* — dispatch is the opposite of what scalar loops
   want.

## 6. Order of work, and how each step is verified

Ordered by measured payoff per unit of risk. The oracle (`oracle.bl`, currently
720 comparisons with 0 undeclared divergences) gates every one of them, and
`decompose.bl` measures it.

| # | lever | evidence for doing it now | verification |
|---|---|---|---|
| 1 | A1 stop realizing | 400 µs → 2 µs, done | oracle + `decompose` A/C |
| 2 | A2 classify the pair once | 1 400 ns/element ⇒ ~200 estimated | `decompose` A, oracle |
| 3 | B1 generated `cons` | ~700 ns/element paid everywhere | `decompose` D, oracle |
| 4 | B2 generated `kind`/`family` | `family` 459–607 ns, per element | `decompose` D, oracle |
| 5 | A3 sets/maps without sorting | O(n log n) + 2 passes; O(n) available | oracle (set/map rows) |
| 6 | A4 drop `proper?` | one fewer pass | oracle |
| 7 | B3 facade inlining | one call per operation | `bench` |
| 8 | native, per §5 | needs ≥10 µs of body work | `invm` harness |

**The flip stays gated on 1–4.** At 1 400 ns per compared element the toolchain
would crawl; the estimates say 2–4 bring it to roughly 50–100 ns per element,
which is within 2× of the runtime being replaced and inside the range the project
already accepts for its compiler and reader.
