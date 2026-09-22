# The runtime as a beam-lisp namespace: cutover status

PLAN-143. Research-only: nothing here is wired into the boot floor, the seed or
the compiler yet. Production sources are untouched.

## What is proven

**The mechanism.** [P0] A BL namespace `rt` emits `Elixir.BeamLisp.Ns.Rt` with
real exports; the public namespace answers from another namespace; and a link
row authored in beam-lisp

```clojure
(BeamLisp.Env/put_link "rt.probe-client" "kind-of"
  (tuple (erlang/binary_to_atom "Elixir.BeamLisp.Ns.Rt" :utf8) {1 :kind} nil))
```

routes a BARE name to that module — and the same name is unresolvable without
the row. That is the whole cutover: `seed_links/0` is a **data table**
(`lib/beam_lisp/rt.ex:2743-2932`), so re-pointing it is an edit to the table,
never to the compiler. `priv/boot/compiler.bl` is module-agnostic for every
linked prim: it reads the link triple through `BeamLisp.Env/link` and emits a
direct remote call to whatever module the row names.

Run: `BL_NO_LOCK=1 bin/bl -p research/rt-cutover run research/rt-cutover/probe.bl`

**The identity decision.** Module identity is derived, not declared:
`Emit.module_for/1` (`emit.ex:10-13`) = `Elixir.BeamLisp.Ns.<Camel(ns)>`, and
`(ns …)` accepts only `:require`/`:import`/`:refer-clojure`. The runtime
therefore becomes the namespace `rt`, and `BeamLisp.RT` ceases to exist. Pinning
the old atom would need a naming override in `emit.ex` plus its two companion
derivations, plus the seed routing in `priv/build/seed.bl` and
`Bootstrap.seed_module_to_ns/1` — six load-bearing files to preserve a name that
is itself a lie. Zero infrastructure changes this way, and the runtime becomes
visible to the toolchain as a namespace.

**The contract.** `BeamLisp.RT` exports **123** functions
(`research/rt-cutover/surface.bl`, read from `module_info(:exports)`). The seed
tier imports exactly **57** of them; `lib/**/*.ex` uses exactly **6**
(`invoke/2`, `invocable?/2`, `get/2`, `hash_key/1`, `print_str/1`,
`seed_core/0`); BL sources reference 8 more by name (`remote_fun/2`,
`print_str/1`, `decimal?/1`, `invocable?/2`, `reduce/3`, `reduced/1`,
`map_xform/1`, `filter_xform/1`).

**The oracle.** [P1] `oracle.bl` runs every ported operation twice — through
`rt` and through `BeamLisp.RT` — over 24 values, and compares the answers as
terms.

```
oracle: 30 operations x 24 values = 720 comparisons
  agree          618
  bl-more-total  92   (the BL runtime answers where the Elixir runtime raises)
  declared       10   (behaviour changes named in `declared`)
      host-struct-leaks-as-a-collection
      rt-take-returns-an-empty-VECTOR
      rt-take-yields-raw-tuples
  FAIL           0
```

A failure is tolerated only when `declared` names a policy AND the condition on
the input: an undeclared behaviour change is indistinguishable from a bug. The
oracle immediately earned its keep by catching a mis-mapping of mine — the
Elixir `doall` FORCES its argument and returns it, while the kernel's `k-doall`
returns a realized list — so `doall` was withdrawn from the facade instead of
being shipped wrong.

## What is ported

| group | source | state |
|---|---|---|
| `rt/raw.bl` | new | BIF constructors: `empty-list`, `cons`, `tuple2/3`, `list-of` |
| `rt/kind.bl` | krt.kind | classifier + 22 predicates, one classification |
| `rt/seq.bl` | krt.seq | seq/first/rest/next/count/nth/empty?/take/drop/cons/splice/list-star |
| `rt/eq.bl` | krt.eq | one comparison; equality defined as distance zero |
| `rt/key.bl` | krt.key | canonical finite hash key |
| `rt/number.bl` | krt.number | exact rational projection (int/float/decimal) |
| `rt/reduce.bl` | krt.reduce | direct traversal of every representation |

`rt.bl` is the public namespace and holds no logic: one `defn` per public name,
each delegating to its owner.

## The cost, measured

`bench.bl`, 200 000 calls per round, best of 3, results consumed, ns per call.
"ratio" is BL ÷ Elixir.

| operation | BL | Elixir | ratio |
|---|---:|---:|---:|
| harness floor | 13–16 | 18–20 | ~0.8 |
| `kind` (vector) | 162–190 | — | — |
| `vector?` | 193–278 | 16–64 | 4–12 |
| `map?` | 28–38 | 22–24 | 1.3–1.6 |
| `first` (vector) | 201–216 | 21–32 | 6–10 |
| `first` (list) | 188–197 | 12–17 | 11–16 |
| `rest` (list) | 176–212 | 10–15 | 12–21 |
| `count` (vector) | 217–239 | 22–25 | 9.6–9.9 |
| `nth 3` (vector) | 350–384 | 34–36 | 10.3–10.7 |
| `empty?` | 372–432 | 38–41 | 9.8–10.5 |
| `compare` ints | 149–160 | 39 | 3.8–4.1 |
| `compare` 10-vector, differ at the 10th | 13 352–14 362 | 339–449 | 32–39 |
| `compare` 1000-vector, EQUAL terms | 455–690 | 462–865 | **0.80–0.98** |
| `compare` 1000-vector, differ at the last | 327 756–363 475 | 14 056–16 438 | 20–26 |
| `eqv` 10-vector, differ at the 10th | 14 069–14 663 | 759–961 | 15–19 |
| `compare` the same 1000-vector twice | 13–91 | 11–69 | 1.2–1.3 |

Two independent runs (the host is noisy — report spreads, not points). Rows name
what they exercise, because a comparison benchmark that does not is measuring
its own fast paths: `erlang/==` is STRUCTURAL equality, so two equal vectors are
answered by one C compare, while `big3` differs from `big` in the LAST element
and can only be answered by walking.

Two optimisations are already in, both from this table:

1. **The classifier scanned for its struct kind.** `kind` looked its answer up
   by looping over the representation descriptors, ~500 ns per call. A
   module→kind map built once at load: `kind` 489→162–190 ns, `vector?`
   598→193–278, `count` 979→217–239.
2. **`compare` had no equality short-circuit.** Comparing a term with itself
   cost 1.52 ms against the Elixir runtime's 11 ns. `(erlang/== a b) → 0` at the
   head of `k-compare` took it to 13–91 ns — and because that test is
   STRUCTURAL, it also answers the far more common case of two equal values:
   455–690 ns for a 1000-element vector against the Elixir runtime's 462–865,
   i.e. parity.

### What the numbers say about sequencing

**What this changes.** The plan said: cut over, then optimise. The measurements
say that order is wrong, and say why: the earlier prototype's 1.3–1.6× figure
was for a DIRECT kernel call, while the real cutover goes through the public
namespace and through a classifier every operation consults — the Elixir runtime
answers the same question inside each function's clause head, in pattern
matching, for free.

- **leaf operations are 4–21×** — tolerable for a toolchain that already accepts
  5× for its compiler and 27× for its reader;
- **comparing UNEQUAL sequences is 20–39×** — a value that differs from another
  at the last element can only be answered by walking, and the walk costs ~1 400
  ns per element against the Elixir runtime's ~14 ns per element on the same
  input, because the Elixir runtime's per-element work is a C-level term compare
  while the BL runtime's is interpreted classification plus a family dispatch.
  Every `sort`, every Sorted insertion, every `distinct` over unequal values
  goes through it. Equality-heavy work — map lookups, replacing an equal value —
  is now at parity, so the remaining cost is concentrated exactly where a
  language's collections spend their comparisons.

So the flip must be preceded by the comparison work, or the toolchain becomes
unusable for as long as it takes to do it. The ranking below is the order the
measurements justify, and P5 is no longer "follow-up": it is the gate.

## P5, ranked by measurement

1. ~~Identity short-circuit in `compare`/`eqv`.~~ DONE — `(erlang/== a b) → 0`
   at the head of `k-compare`. 1.52 ms → 13–91 ns for a term against itself, and
   because the test is structural, equal values went to parity with the Elixir
   runtime as well. This was the largest single ratio in the table and it cost
   one clause.
2. **Delegate same-family sequence comparison to the BEAM's term order.** The
   remaining hotspot, and the one that decides whether the flip is safe: two
   sequences that agree for 999 elements and differ at the last cost 328–363 µs
   in BL against 14–16 µs in the Elixir runtime. Where the representation
   already encodes the semantic order — same family, non-numeric, no metadata —
   `:erlang` term comparison on the underlying sequence answers the same
   question in C. The semantic walk stays for the cases where it must: mixed
   families, numeric representation equivalences (`1 = 1.0 = 1M`), metadata.
3. **`kind` as a generated `case`, not a `cond` chain.** 203 ns is now the floor
   for every operation; the chain evaluates up to 13 type tests before it
   answers, and the answer is a fixed function of the term's tag. Generating the
   arms from the representation descriptor table — the same table that already
   drives the classifier and the emitted modules — makes the classifier one jump.
4. **Collapse the facade hop for hot leaves.** `first`/`rest`/`next`/`count`/
   `nth`/`empty?` pay `rt.bl` → `rt/seq.bl` on every call. Either bind the
   kernel's function values directly into the namespace, or generate the facade
   from the descriptor so the hop disappears at emission time.
5. **`empty?` is 584 ns, more than `kind` itself** (203). It should be one
   classification and, for a list, one term compare — it is currently neither.

## Declared departures

Two of them are defects in the runtime being replaced, filed so the change is
tracked rather than asserted in a comment:

- **BUG-091** — map entries are a vector through `first`/`seq` but a raw tuple
  through `take` (measured). The BL runtime yields entries from both paths.
- **BUG-092** — a Decimal answers as a collection: `(coll? 1M)` true,
  `(count 1M)` 2 (its struct fields), `(empty? 1M)` false, and `(seq 1M)` raises
  `protocol Enumerable not implemented for BeamLisp.Decimal`. The BL classifier
  calls it a number.

The third, `:rt-take-returns-an-empty-VECTOR`, is the same family: the Elixir
`take` returns the empty VECTOR `[]` when the result is empty and a list
otherwise.

## Still to port

`invoke` · `apply_to`/`apply_variadic` · `multi_fn` · `remote_fun` ·
`call_shape_error` · `invocable?` · the printer (`print_str`, `print_readably`,
`println`, `println_multi`, `str`) · the lazy combinators (`map`, `filter`,
`map_xform`, `filter_xform`, `take_xform`, `range`, `repeat`, `iterate`,
`cycle`, `concat`, `take_while`, `drop_while`, `doall`, `dorun`, `reduced`,
`reduced?`) · the sorted family (`sorted_map`, `sorted_set`, `sorted_map_of`,
`sorted_set_of`, `subseq`, `rsubseq`, `last_key`, `last_entry`, `sorted_dissoc`,
`tree_seq`) · collection operations (`get`, `assoc`, `conj`, `disj`, `find`,
`contains?`, `set`, `sort`, `hash_key`, `identical?`) · the numeric predicates
(`even?`, `odd?`, `zero?`, `pos?`, `neg?`, `rem`, `bit_not`, `promoting_inc`,
`nan?`, `ratio?`) · readers and names (`gensym`, `name_of`, `namespace_of`,
`keyword_of`, `data_reader`, `data_reader!`, `reader_macro`, `reader_macro!`,
`read_data`) · the seed tables (`seed_core`, `seed_links`).

## Reproduce

```sh
BL_NO_LOCK=1 bin/bl -p research/rt-cutover run research/rt-cutover/probe.bl    # mechanism
BL_NO_LOCK=1 bin/bl -p research/rt-cutover run research/rt-cutover/oracle.bl   # differential gate
BL_NO_LOCK=1 bin/bl -p research/rt-cutover run research/rt-cutover/bench.bl    # cost
BL_NO_LOCK=1 bin/bl -p research/rt-cutover run research/rt-cutover/surface.bl  # the 123-name contract
```
