# rt in beam-lisp: a prototype

> Interop correction: BUG-090 is closed as an invalid reproduction. Computed, bound and inline `erlang/apply` argument lists all pass `interop_test.bl`; the rejected input was a list of lists where `maps:from_list` requires a list of tuples.

Current implementation and verified measurements: [EXECUTION.md](EXECUTION.md). The numbers below describe the earlier exploratory version.

> Review correction (2026-09-21): read [NATIVE-PLAN.md](NATIVE-PLAN.md), especially §5, before relying on these conclusions. Source review found ordering and predicate-coherence defects, unbounded traversal costs, and insufficient benchmark/test controls. The reported sample results do not establish semantic parity, totality, transitive RT independence, or a faster comparator. The four compiler seams are not a complete cutover estimate. The interop correction above supplies the subsequently executed BUG-090 regression.

The claim under test: the runtime protocol layer of beam-lisp (`BeamLisp.RT`)
does not have to be Elixir. It can be `.bl`, and when it is, whole classes of
bug stop being possible — not because the code is more careful, but because
the shape that produced them is gone.

Prototype lives in `research/rt-selfhost/`. Nothing here is wired into the
live runtime, the seed, or the compiler; it is a parallel kernel that runs
beside them and is measured against them.

```
krt/kind.bl    one classifier: what kind of value is this
krt/seq.bl     seq/first/rest/next/count/nth/empty?/take/drop/... on that classifier
krt/eq.bl      ONE comparison; `=` is defined as (compare == 0)
krt_test.bl    parity vs BeamLisp.RT, the bug class, totality
krt_bench.bl   what the single-classifier dispatch costs
```

---

## 1. The floor, measured

Before arguing about ports, the size of the thing to be replaced:

`priv/bootstrap/seed/*.beam` import tables (`beam_lib:chunks(F,[imports])`)
say the boot tier — compiler, reader, lowerer, prelude — depends on exactly:

| module | functions the seed tier actually imports |
|---|---|
| `BeamLisp.RT` | **57** (`first rest next seq count nth get assoc conj cons empty? eqv compare hash_key invoke splice take drop map filter sort …`) |
| `BeamLisp.Vector` | 3 — `__struct__/1`, `new/1`, `to_list/1` |
| `BeamLisp.Set` | 2 — `new/1`, `to_list/1` |
| `BeamLisp.LazySeq` | 2 — `from_fun/1`, `lazy?/1` |
| `BeamLisp.Record` | 4 · `BeamLisp.Num` 8 |
| `BeamLisp.Env` | 21 (the evaluation substrate, a separate question) |

So "rt is load-bearing" is quantifiable: **57 functions**, not 2746 lines. Most
of those 57 are derivable from a handful (`even?`/`odd?`/`zero?`/`pos?`/`neg?`
from one comparison; `empty?` from `count`; `contains?` from `get`;
`sorted?`/`sorted-map?`/`sorted-set?` from one predicate table).

Why they are so load-bearing is mostly *not* the protocol. Reading
`compiler.bl` + `lower.bl`:

- a **vector literal** `[1 2 3]` lowers to
  `call 'Elixir.BeamLisp.Vector':'__struct__'([{'items', {1,2,3}}])`
  (`compiler.bl:561-570`, `lower.bl:272-283`)
- a **set literal** `#{1 2}` lowers to `Elixir.BeamLisp.Set:new/1`
- a **map literal** `{:a 1}` wraps its keys in `Elixir.BeamLisp.RT:hash_key/1`

∴ every compiled namespace carries host imports *because of how literals are
emitted*, before any protocol call. That is 3 identifiers in a `.bl` file, not
a property of the language.

## 2. The kernel

`krt.kind/kind` classifies every value once. Everything else dispatches on it:

```clojure
(cond
  (erlang/is_map x)  (cond (erlang/is_map_key :__struct__ x)
                           (struct-kind (erlang/map_get :__struct__ x))
                           :else :map)
  (erlang/is_list x) :list
  ...)
```

The current runtime answers the same question in the clause heads of ~90
functions, again in `rank/1`+`cmp_same/2` behind `compare`, again in
`call_shape/1` behind `invoke`, and again in the compiler's BIF tables. Each is
hand-ordered, and the ordering rule is a *comment*:

> "Both of these are structs, and a struct is a map — they MUST precede the
> is_bl_map clause or count returns the number of struct fields."

> "The set clauses in `BeamLisp.RT` MUST precede the `is_bl_map` clauses (same
> rule as vectors and lazy seqs), or `count`/`seq`/`first` read the struct's
> fields instead of the members." (`lib/beam_lisp/set.ex` moduledoc)

One classifier makes that structural: a struct is classified before a map
because the classifier says so once.

### Independence, verified

Compiled with the project's own AOT builder (`bin/bl -p research/rt-selfhost
build research/rt-selfhost/krt/ --out DIR`), then the beams' import tables read
with `beam_lib`:

```
Body.Krt.Kind   RT(0)  Core(0)  Vector(0)  Set(0)
Body.Krt.Eq     RT(0)  Core(0)  Vector(0)  Set(0)
Body.Krt.Seq    RT(0)  Core(0)  Vector(3: count/nth/to_list)  Set(2: count/to_list)
```

`krt.seq`'s import table carries one unused entry, `RT.invoke/2`; a
`beam_disasm` walk of every function in the module finds **no** call site to
any `BeamLisp.*` module. (Vestigial entry, noted rather than explained.)

Getting there required discovering that BL has **no primitive** for a cons cell
or for tuple construction. `(tuple a b)` is a prelude function
(`priv/boot/core.bl:1575`), and `cons` is a runtime function — so a runtime
written in BL cannot use either. The BEAM's own constructors are enough:

```clojure
(defn- mk2 [a b] (erlang/setelement 2 (erlang/setelement 1 (erlang/make_tuple 2 nil) a) b))
(defn k-cons [x xs] (app1 (l2 (l1 x) xs)))   ; lists:append/1 copies only its first sublist
```

That is the whole boundary. Two BIFs and a stdlib function, and the protocol
layer needs nothing from the runtime it replaces.

## 3. Parity

`bin/bl -p research/rt-selfhost run research/rt-selfhost/krt_test.bl`

```
== 1. parity with BeamLisp.RT (seq/first/rest/count) ==
  values agreeing with the Elixir runtime: 18/18
  operations where BeamLisp.RT raises (krt is total): 10
```

18 values — scalars, strings, symbols, keywords, lists, vectors of several
lengths, lazy seqs, maps, sets, empty collections — across four operations,
all agreeing. The 10 raises are `BeamLisp.RT` refusing non-collections
(`(count true)`, `(first :kw)`) where krt answers `0`/`nil`; the current
runtime's own `=` docstring promises totality ("`=` must be total"), and these
are primitives that are not.

## 4. The bug class, counted

`=` and `compare` are the two primitives every collection is built on, and the
runtime implements them twice: `RT.eqv/2` is a `cond` over type predicates;
`RT.compare/2` is `rank/1` + `cmp_same/2` + Erlang term order. BUG-018 was the
two disagreeing about tuples. BUG-019 is the same defect one type family up and
is still open. Same matrix, both implementations:

```
== 2. '=' and 'compare' must agree ==
  current runtime (BeamLisp.RT/eqv + compare): 6 ordered pairs disagree  (3 unordered)
      (lazy[]) vs (())         = true   compare 1
      (lazy[]) vs (nil)        = true   compare 1
      (()) vs (lazy[])         = true   compare -1
      (lazy[1 2]) vs ((1 2))   = true   compare 1
      ((1 2)) vs (lazy[1 2])   = true   compare -1
  krt.kernel (one comparison):                   0 ordered pairs disagree

== 3. totality: every primitive, every kind ==
  primitive applications that raised: 0  (total over every value tested)
```

Three unordered pairs in the live runtime where one authority says "these are
the same value" and the other says "the first is less than the second".
`sort` consults one, `distinct` and `frequencies` the other, and the datom
codec — which must project ONE order into bytes — has no single authority to
project. In krt there is one comparison, so `=` *is* `(compare == 0)` and the
count is structurally zero. What remains is policy — is a vector a list? — and
that is one line of `rank/1`, in one place, instead of a clause list, a rank
table, and a compiler BIF table that have to be kept in step by hand.

## 5. Cost

`bin/bl -p research/rt-selfhost run research/rt-selfhost/krt_bench.bl`,
N=200 000, best of 3, ~ns/op:

| operation | krt | BeamLisp.RT | ratio |
|---|---|---|---|
| `first` (list) | 262 | 204 | 1.28× |
| `first` (vector) | 340 | 244 | 1.39× |
| `first` (lazy) | 712 | 474 | 1.50× |
| `count` (vector) | 346 | 218 | 1.59× |
| `nth 0` (vector) | 339 | 247 | 1.38× |
| compare/eqv (int) | 111 | 130 | **0.86×** |
| `kind` (vector) | 307 | — | the dispatch cost itself |

Reading the table: the classifier costs ~300ns and that is the whole gap. The
comparison the current runtime splits across two tables is *faster* in one.

Context for the magnitude: the self-hosted **reader** ran 27× slower than its
Elixir genesis and was flipped default-on anyway when the user asked for it;
the self-hosted **compiler** ships at ~5×. At **1.3–1.6×**, the floor rule
("substrate migrates only if a `.bl` version is as fast") is not a wall — and
the gap has an obvious closure (have the compiler emit a `case` on the kind
atom rather than a `cond` chain, or generate the per-prim arm tables from the
classifier's own table at macroexpansion).

## 6. What removing rt from the boot floor would take

Measured, not guessed:

1. krt in `priv/boot/` — the seed pipeline is glob-driven over `priv/boot/**/*.bl`
   (`bl build` already compiled `research/rt-selfhost/krt/` this way), so it is
   picked up; loading order before the prelude is the one manual line.
2. `mod-rt` in `priv/boot/compiler.bl:167` — the single place the compiler
   hard-codes `BeamLisp.RT` as the target of every dynamic call. One identifier.
3. Literal lowering — `Vector.__struct__/1`, `Set.new/1`, `hash_key/1` in
   `compiler.bl:561-593`. Three identifiers, in the file that is already BL.
4. The storage modules' normalisation seam — `set.ex` and `map` membership call
   `BeamLisp.RT.hash_key/1`; krt provides `hash-key`, so this is a one-call
   re-point, not a rewrite.

Nothing on that list requires an Elixir change beyond leaving a function
reference intact.

## 7. What was not done, and what it would prove

- **No seed rebuild.** Baking krt into `priv/bootstrap/seed/` means writing into
  a committed artifact; the honest place to do that is a scratch checkout. The
  prototype therefore measures the kernel beside the runtime rather than under
  it. Everything needed to attempt the swap is enumerated above.
- **krt is a subset.** Covered: classification, the seq protocol, equality and
  ordering. Delegated to the storage engines (named, not hidden): the vector
  trie, hashed sets, `:gb_trees` ordering, the lazy memo cell, the numeric
  tower. Not yet written: `invoke` (the interpreter's apply — itself pure
  kind-dispatch, a natural next file), the printer, lazy `map`/`filter`/`range`
  built on `lazy-seq`, refs/transients/OTP verbs, and `hash-key`'s
  metadata normalisation.
- **The compiler will need to know.** `krt` calls `erlang/apply`, never `list`,
  `cons`, `first` or `tuple`, and this is not a style preference: a bare name
  resolves through the defining namespace, so a runtime that calls `first`
  depends on the runtime that defines `first`. A cutover needs either that
  discipline or a compiler that treats the kernel's names as special.

## 8. Findings that stand on their own

1. **A compiler defect.** `(erlang/apply :maps :from_list <computed list>)`
   returns a value that is not a map. Isolated in `/tmp/krtprobe/probe8.bl`:
   four function variants and both inline forms fail, while the same call with a
   *variable* argument succeeds (`probe6.bl`). Worked around in krt by building
   the value with `maps/put` chains. Filed as a follow-up.
2. **Erlang stdlib modules are not statically resolved.** `(lists/append ll)`
   emits a dynamic `BeamLisp.RT.invoke/2` call; `(erlang/apply :lists :append args)`
   does not. Writing a kernel in BL requires knowing this.
3. **BL cannot build a cons cell or a tuple without the prelude or the runtime.**
   Both are constructible from BIFs, but the language should own them: a `cons`
   special form lowering to Core Erlang's cons is a smaller change than it looks
   and would let a BL runtime read like BL.
4. **The one-table design pays a real and bounded cost.** ~1.3–1.6× on leaf ops,
   ~0× on comparison, against the 5–27× the language already accepts elsewhere.

## 9. Why this is worth finishing

The pipeline argument, stated plainly: today the toolchain's floor includes 57
functions whose *only* job is to answer "what kind of value is this", written in
a language the toolchain's own rules forbid it to reason about. Those 57
functions are also where the language's semantics quietly live — sequential
equality, string seqability, sorted-vs-hashed equality, per-env exclusion of
structs from maps — and the bug board is the record of maintaining those
semantics in two places at once.

Move them, and:

- a type gets one classification, so BUG-018's family (equality/ordering drift)
  and `set.ex`'s documented clause-ordering hazard stop being reachable;
- the nine literals/identifiers listed in §6 are the whole remaining floor,
  which makes "bootstrapped" a statement with a number in it;
- the self-hosted half of the language can finally *look* at the runtime half:
  `codebase` could index the runtime, the optimizer could query it, docs could
  come from it — the same payoff that made the reader and compiler worth
  self-hosting, applied to the part every program actually calls.
