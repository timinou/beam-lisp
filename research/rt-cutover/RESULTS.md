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
| harness floor | 12 | 12 | 1.0 |
| `kind` (vector) | 203 | — | — |
| `vector?` | 172 | 16 | 10.8 |
| `map?` | 27 | 19 | 1.4 |
| `first` (vector) | 222 | 50 | 4.4 |
| `first` (list) | 254 | 20 | 12.7 |
| `rest` (list) | 237 | 20 | 11.9 |
| `count` (vector) | 241 | 32 | 7.5 |
| `nth 3` (vector) | 414 | 43 | 9.6 |
| `empty?` | 584 | 41 | 14.2 |
| `compare` ints | 175 | 43 | 4.1 |
| `compare` 10-vector | 19 719 | 383 | 51 |
| `compare` 1000-vector | 1 295 525 | 1 072 | 1 209 |
| `eqv` 10-vector | 17 665 | 811 | 22 |
| `compare` 1000-vector with itself | 1 515 906 | 11 | 137 810 |

One optimisation is already in: the classifier looked its struct kind up by
SCANNING the representation descriptors, which cost ~500 ns per `kind` call.
A module→kind map built once at load took `kind` from 489 ns to 203 ns,
`vector?` from 598 to 172, `count` from 979 to 241.

### What the numbers say about sequencing

The plan said: cut over, then optimise. The measurement says that order is
wrong, and says why.

The earlier prototype's 1.3–1.6× figure was for a DIRECT kernel call. The real
cutover goes through the public namespace (two remote hops) and, more
importantly, through a classifier that every operation calls — the Elixir
runtime answers the same question inside the clause head of each function, in
C-shaped pattern matching, for free.

- **leaf operations are 4–14×** — tolerable for a toolchain that already accepts
  5× for its compiler and 27× for its reader;
- **sequence comparison is 51–1209×, and identity comparison 137 810×** — not
  tolerable. Every `sort`, every map key, every `distinct`, every Sorted
  insertion goes through it, and the toolchain sorts constantly.

So the flip must be preceded by the comparison work, or the toolchain becomes
unusable for as long as it takes to do it. The ranking below is the order the
measurements justify, and P5 is no longer "follow-up": it is the gate.

## P5, ranked by measurement

1. **Identity short-circuit in `compare`/`eqv`.** 1.5 ms vs 11 ns. Comparing a
   term with itself is distance zero; that is provable, not a heuristic
   (`compare` is reflexive by construction). Trivial, and removes the worst
   ratio in the table.
2. **Delegate same-family sequence comparison to the BEAM's term order.** The
   Elixir runtime answers in 1 072 ns for 1000 elements — it is not walking
   element by element in Elixir, it is comparing the underlying tuple in C. The
   BL comparator walks in interpreted code at ~1 300 ns PER ELEMENT. A fast path
   that uses `:erlang` term comparison where the representation already encodes
   the semantic order (same family, non-numeric, non-metadata) and falls back to
   the semantic walk only where it does not (mixed families, numeric
   representation equivalences such as `1 = 1.0 = 1M`, metadata) is the single
   largest win available.
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
