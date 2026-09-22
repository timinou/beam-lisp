#import "_preamble.typ": guide, idea, recipe, exercise, decision

#let chapter = [
= 3 · Representations and values

A program's *meaning* is the answer it computes. A *representation* is how a
value is stored between the steps that compute it. Two programs with the same
meaning can hold their values as cons cells, packed machine words, or a window
into a binary — as long as every operation observes the same answer.

This chapter is about the laws that keep those choices invisible, and the
containers that make them affordable. It ends where the language boundary
begins: the same bytes read as text in one contract and as data in another,
and views that are not copies.

#idea(title: "Efficiency and modularity are one question")[
  A representation may change once the relations over a value are decided.
  Fix equality, hashing, ordering and key encoding, then preserve every other
  promised observation: type predicates, decimal scale, metadata access and
  identity where it matters. Numeric equality alone does not make `1` and
  `1.0` interchangeable for a function that asks `float?`.
]

== Laws before shapes

Four relations describe a value to the rest of the system:

- *equality* is an equivalence: reflexive, symmetric, transitive;
- *hash* agrees with equality — equal values always hash together;
- *order* is total over one comparable family, and consistent with equality;
- a *key codec* projects equal values to equal keys — one for identity (a
  canonical key), one for sorted storage (an ordinal, order-preserving
  encoding).

Each has a consumer: `=` serves patterns, `hash` serves sets and maps,
`compare` serves sorting, the key codec serves anything that must leave the
VM image. A flaw appears when two disagree: a pair `=` calls equal that a key
separates, an order that is not transitive, a hash finer than equality.

#decision(because: [
  patterns, storage keys and sorted collections all inherit these relations,
  and none can repair an inconsistency locally.
])[
  Decide the relations once, per *semantic family*, not per concrete layout.
]

== Numbers: one order, one key

Three scalar families carry numbers. *Integers* are exact and grow to
arbitrary precision on overflow. *Floats* are IEEE binary64: fast, and not
the decimals that were written. *Decimals* are an unscaled integer beside a
scale, so `1.50M` records cents where `1.5M` does not.

Two rules follow from what those families mean.

First, *no reassociation by default*. Float addition is not associative:
`(+ (+ 1e16 -1e16) 1)` is `1.0`, while `(+ 1e16 (+ -1e16 1))` is `0.0` —
the second rounds `-1e16 + 1` back to `-1e16` and absorbs the final `1`.
Even `(+ 0.1 (+ 0.2 0.3))` differs from `(+ (+ 0.1 0.2) 0.3)` (`0.6` against
`0.6000000000000001`). A compiler may reorder arithmetic only where a law
licenses it; arbitrary float reassociation needs additional proof. Integer
addition is associative. Decimal addition here is exact and takes the
maximum operand scale, so regrouping three such additions preserves both
the value and that scale. A decimal drops that only where an operation
rounds or a caller quantizes — the scale-changing steps are explicit
(`rescale`, or a division given a scale and a rounding mode), never a side
effect of regrouping a sum. An integer wraps only when the program asks, as
the byte pipeline does with its explicit `mod 2^64`.

Second, a float beside an exact number is not exact: the shipped decimal
arithmetic refuses `(+ 1M 0.1)` rather than launder an approximation into a
ledger. An approximation, when meant, is asked for by name.

The interesting law sits at the seam. This language's `=` calls `1` and
`1.0` equal, so a numeric equality spanning representations must not hide
behind a key that separates them, or a map lookup and a set membership test
will disagree about the same pair. The prototype in
`research/rt-selfhost/krt/number.bl` makes the seam concrete: every finite
number becomes one exact rational —

- integer `n` maps to `n/1`;
- float `f` maps to its IEEE value via `Float.ratio/1`;
- decimal `U/10^S` maps to `unscaled/10^scale`;

then reduced by `gcd` with a positive denominator, with zero canonicalised
to `0/1`. Both consumers read that one value: `num-cmp` compares by
cross-multiplication, and `num-key` emits `{:num, numerator, denominator}`.
So `1`, `1.0` and `1M` share a key, while `0.1` (the float) and `0.1M` do
not — the float is not one tenth.

```clojure
;; Excerpt in a session where the kernel prototype is initialized.
;; The prototype loader is research/rt-selfhost/run.bl.
;; Bind the alias in your module:
;;   (ns numeric-demo (:require [krt.number :as n]))
(n/num-cmp 1 1.0M)                 ; 0 — the same number
(erlang/== (n/num-key 1) (n/num-key 1.0M))   ; true
(n/num-cmp 0.1 0.1M)               ; not 0
```

#idea(title: "Non-finite numbers are a policy, not an accident")[
  Ordinary BEAM arithmetic raises `badarith` for cases such as overflow or
  `0.0/0.0`, rather than supplying an infinity or NaN. A boundary that admits
  those IEEE values needs an explicit equality, ordering and key policy.
  The rational projection applies to finite numbers; it cannot invent a
  rational value for a NaN or infinity. A key may map both signed zeros to
  `0/1` when numeric equality identifies them. The value still preserves its
  sign for operations that inspect its formatting or IEEE representation.
]

#decision(because: [
  one exact projection, read by both the order and the key, is what makes
  the two agree. Comparing a float by the shortest decimal that round-trips
  does not: that decimal is not the float's value, so `=` stops being
  transitive where the two halves meet.
])[
  Model rule: numbers compare and key on one exact value. Prototype policy:
  `krt` implements it as exact rationals, and the shipped decimal type
  implements its own exact arithmetic. Neither is yet a promise for the
  whole language.
]

== Equality, hashing, and key codecs

Three codecs are easy to confuse, and they answer three different questions.
Keep them apart and each is simple; merge them and the seams leak.

- A *hash digest* is fixed-width — `phash2` of the canonical key. Equal
  values hash together; unequal values may collide, so a digest never decides
  equality alone. A table keyed by one compares the original values on a hit
  it cannot otherwise rule out.
- A *canonical key* is the full structural encoding: one tag per semantic
  family, numbers on the shared rational, unordered collections sorted. As
  the *sole* key of a store it must identify exactly the equality classes it
  serves — two values land on one key if and only if the equality relation
  underlying that store calls them equal. The prototype's `semantic-key`
  encodes the whole value, not a digest of it, and it is injective over
  `krt`'s equality classes: there is nothing left to compare, because equal
  key already means equal value.
- An *ordinal codec* preserves order: term order over the encoded form
  matches `compare`. The production sorted collections use one,
  `BeamLisp.Sorted.encode_key/1`. Hashing needs only equal-implies-equal and
  a canonical key needs only equality; neither orders anything, and a lookup
  key allowed to decide order is how the two drift.

The tempting shortcut is `term_to_binary/1`, and the first thing to fix is
what it is: a *serialization*, not the BEAM's term order (that is the `<`
operator; `==` and `=:=` decide numeric and exact equality within it). It is
total and portable-looking, and it is representation-sensitive: `1` and
`1.0` are `=`-equal numbers, but they carry
different tags — a small integer against a new float — so a key built from
those bytes separates them, and their byte order is not the order `compare`
reports. It also keys pids and funs as if they were portable data.

The prototype instead refuses what has no portable meaning. Lazy sequences
are refused because a key would force them, and an infinite one would never
finish. Functions and pids are refused because their meaning is local to one
VM image. Metadata *attached* to a value is ignored, so `(with-meta [1]
{:m 1})` keys exactly as `[1]` — while a plain map that happens to carry a
`:meta` entry, `{:meta 1}`, is ordinary payload and keys with that entry
counted.

For unordered collections the key is the *sorted* list of entry keys, using
the same order `compare` uses — so a map and its sorted sibling project to
one key. It is a *multiset* sort: duplicates are preserved, never merged. In
BEAM terms `1` and `1.0` are distinct map keys, so `#{1 1.0}` keys differently
from `#{1}`; collapsing them would silently change cardinality. A record keeps
its extension fields in the key: adding a field that changes its semantic
value changes the key, while an equality-preserving update keeps it.

== Containers: one kind, one shape, one guard

Dispatch is a cost, and so is a shape you cannot predict. There is one
classifier, in `research/rt-selfhost/krt/kind.bl`, and every predicate and
protocol reads it. One definition, though, does not mean one classification
per value forever: a reduction classifies once and then walks the
representation it found, while each generic call pays for a fresh
classification. The win is that no two sites can answer differently — not a
memo. A struct is a map on the BEAM, so the ordering hazard — "map clauses
must not precede struct clauses, or `count` reads fields instead of members"
— becomes a property of the code rather than a comment a reviewer must
remember.

The shapes that follow:

- a *list* is a cons spine; emptiness is `(erlang/== xs ())`, a constant-time
  term compare, never a `length` walk;
- a *vector* is one wrapper, `BeamLisp.Vector`, with two storage strategies
  inside it: up to thirty-two elements are a direct tuple, more are a trie
  `{:bl_vec, cnt, shift, root, tail}`. One semantic family can hold several
  disjoint layouts this way — a list, a vector and a lazy seq are all
  `:sequential`, one equality and one order, while the two vector sizes share
  a wrapper but not their storage. A fold reads the layout once and walks the
  trie's leaves then its tail, never calling `to_list`;
- a *map* iterates with `maps:iterator`, so no entry list is materialised;
- *sorted* collections are an index property, not an identity: a sorted map
  compares and keys as a map;
- *metadata* is not payload: it never enters `=` or a key.

#recipe[
  *Unambiguous representation tags.* Keep a storage discriminator outside the
  user's element payload, and validate the layout facts a fast path uses.
  A familiar atom or `__struct__` field is a clue, not a complete proof of
  shape. A constructor, a checked envelope and shared discriminator logic
  establish the representation contract together.

  An Erlang reference can be sent or encoded as a term, but a boot-specific
  reference is not a stable schema tag across restarts. For persistent data,
  choose an explicit versioned encoding. One semantic family may have several
  layouts; write each discriminator once and derive its consumers from it.
]

== Strings: bytes, codepoints, graphemes

A string counts *graphemes*: `(count "héllo")` is 5, and a `seq` of it yields
one-character strings. A string is stored as a binary — there is no distinct
byte-string type — so the difference is not the storage but the *indexing
contract* over it. The language's string operations index graphemes; the byte
pipeline is explicit that it has *byte* semantics, and counts, slices and
offsets bytes. One binary holds both readings: it answers 5 under one contract
and 6 under the other (`é` is two bytes), and only the contract in hand says
which is meant.

Bytes, codepoints and graphemes are three index spaces, and naming which one
an index lives in is the only way a slice means the same thing to a reader
and a runtime. At a native boundary it decides whether an offset is a pointer
or a character.

#recipe[
  *Typed packed views.* A view is not a copy; it is a parent binary plus an
  offset, a length, an element width, a byte order, a stride and a bounds
  check. An illustrative interface, not a shipped one:

  ```clojure
  ;; Illustrative: no packed-view module ships today.
  (def v (view/u16-le buf 4 100))   ; 100 little-endian u16 from byte 4
  (view/at v 3)                     ; bounds-checked element read
  (view/sub v 10 8)                 ; aliases buf: keeps buf alive
  (view/copy (view/sub v 10 8))     ; detach: a small fresh binary
  ```

  Two obligations come with it. *Alias retention*: a sub-binary is a handle
  into its parent, so keeping eight bytes can keep a whole buffer alive until
  a copy detaches them. *Explicit layout*: byte order and stride are
  arguments, never ambient, and a bounds check precedes every read.
]

== Do not build the collection you are about to walk

A walk should cost what it observes, not what the collection contains. The
prototype fold asks the classifier once, then follows the representation it
found: the cons spine, the vector's leaves then its tail, the map's iterator,
and the generic sequence protocol otherwise. A step returning a `Reduced`
sentinel stops the fold immediately — no further callback, no lazy force.

Laziness follows the same rule. On an unchunked source, `nth` forces at most
`i + 1` cells and a negative index forces nothing, and `take n` asks for
exactly `n` cells and never for the one after — the exact counts the
traversal tests pin against a one-cell-per-force fixture. So `(take 5 (range
1 1000001))` yields five elements and never realises the other 999 995. The
counts belong to the consumer's walk, though, and a *producer* may materialise
a chunk at a time. A finite eager input longer than thirty-two elements is
copied once into native storage (`BeamLisp.SeqCursor`, over
`native/lazy_memo`) and handed back in chunks of thirty-two, so asking such a
cursor for a single head realises a whole chunk. Chunking bounds the *BEAM
heap* the walk holds — at most one chunk — not the total: the native copy
retains the whole input, and a retained lazy head, a captured parent, or an
accumulated output keeps its own memory live as long as it is reachable.
Iteration avoids building an *additional* copy of the collection; it does not
shrink the live input, the memo cache, or the result. Element size, not a
guess, chooses the cheap or the safe crossing.

#recipe[
  *Ownership-specific builders.* Accumulating into a persistent collection
  one element at a time pays a structural-sharing step per element. A builder
  is the other half of the trade: a value with exactly one owner, mutated in
  place while built, then *frozen* into the persistent value. That ownership
  is the contract — a builder is never shared and never written after the
  freeze. Each representation grows its own; do not force one abstraction
  over cons cells and trie nodes.
]

#exercise[
  A colleague proposes keying every value by `term_to_binary/1`: total,
  portable-looking, one line. Name two laws it breaks, with a value that
  exposes each.

  *Answer.* It breaks equality-consistency: `1` and `1.0` are `=` but encode
  with different tags, so a map keyed one way misses the other. It breaks
  portability: a pid or fun encodes to something that looks like data, so a
  key that should be local to one VM image is stored across images. A third,
  subtler break: attached metadata becomes visible — `(with-meta [1] {:m 1})`
  serializes with its `:meta` field, so it gains a key that `[1]` does not
  share, though `=` calls the two equal. The fix is a projection that
  *refuses* what has no portable meaning.
]

]

#guide(
  title: "Representations and values",
  subtitle: [
    First-principles efficiency and modularity across numbers, keys,
    containers, text, and views.
  ],
)[#chapter]
