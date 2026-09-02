# 22 — Pattern inverses: constructor and generator

*A rigid pattern can be run backwards. Backwards from bindings, it is a
constructor. Backwards from nothing, it is a generator. Records, lenses,
and property domains all come from one declaration.*

## Invertibility

A pattern `p` is **rigid-complete** when its normal form determines the
value's shape entirely: every path either binds a name or holds a literal,
and no lenient default exists. `[a b]` (strict), `{:x x :y y}` on a fixed
key set, `[:ok payload]` — yes. `{:keys [a]}` on an open map — no (the
other keys are unconstrained). `(?some pred)` — no (a predicate is not a
shape).

For a rigid-complete `p` with binds `{id₁ … idₙ}`:

```
construct p : Bindings → Value        (construct p (bind p v)) = v
bind p      : Value → Bindings        (bind p (construct p b)) = b
```

That pair is a **lens** in the isomorphism sense (a *prism* when `p` can
fail on the way in). `optics.bl` has lenses as separate objects; this
makes every rigid pattern one.

### Walkthrough

```clojure
(def point '[x y])                                   ; strict by declaration
(construct point {x 1 y 2})   ;; => [1 2]
(bind point [1 2])            ;; => {x 1 y 2}

(def event '[:event kind {:keys [ts payload]}])      ; nested, still rigid-complete
(construct event {kind :click ts 100 payload {…}})
;; => [:event :click {:ts 100 :payload {…}}]
```

And with `transform` from capsule 21:

```clojure
(defn shift [pt dx] (transform point (fn [x y] [(+ x dx) y]) pt))
;; bind → apply → construct, one round trip, no intermediate maps
```

## Records from one declaration

Today `defrecord` (`record.ex`) creates a `defstruct` module, a `->P`
constructor, `map->P`, and keyword access; the *shape* lives in Elixir.
With inverses:

```clojure
(defrecord Point [x y])
;; ≡
(def Point (pattern/rigid '{:__struct__ Point :x x :y y}))
;; ->Point     = (construct Point …)
;; map->Point  = (construct Point (bind '{:keys [x y]} m))
;; (Point? v)  = (matches? Point v)
;; typed tag   = the pattern
;; state-shape = the pattern
```

`system.core/state-shape` today *infers* the shape by walking clauses;
when the state is a record, the shape is declared, and the inference is a
lookup. `deftype` is the same with an opaque wrapper (`{:bl_deftype …}` →
a struct, capsule 01) and no `map->`.

## Generator: backwards from nothing

Reading a rigid-complete pattern *without* bindings and filling each bind
site from a generator of its type gives a **value generator**:

```clojure
(gen '[x y])                         ;; needs types for x, y → from ^{:t} or :any
(gen '[^:int x ^:int y])             ;; => generator of 2-vectors of ints
(gen '{:keys [name] :as p})          ;; open map: name : any, plus arbitrary other keys
(gen '(?guard [^:int n] (pos? n)))   ;; ints, filtered — or SMT-solved if the guard translates
```

`veritas.property` today takes `{:q :for-all :var str :gen g :pred form}`
with a hand-written `g`. After: **the property's domain is the fn's own
head pattern.** `(for-all f)` reads `f`'s clause patterns, generates from
them, and checks the `:pred` (or, with no pred, checks that `f` does not
throw — coverage). `veritas.covers` already reads guards from the source;
this reads the *whole* head.

Shrinking becomes structural: a failing `[3 [1 2 7]]` shrinks by walking the
pattern — shrink the `:nth 0` int, then the inner vector's length, then
its elements — instead of the generic "try smaller" loop. The pattern
tells the shrinker what the value's *joints* are.

For the SMT-translatable subset, `gen` is not sampling at all: `z3` is asked
for a model of the pattern's constraints (`system.smt` sorts ↔ kinds,
capsule 23), and `:proven` replaces `:witnessed` — the escalator veritas
already implements, with the pattern as the query.

## Bidirectional codecs

A rigid pattern over binaries — once binary patterns exist in bl's
vocabulary (they exist in Core: `#<…>(size, unit, type, flags)`) — is a
parser *and* a serializer:

```clojure
(def header '(?bin [^{:size 8} version ^{:size 16 :endian :big} length & body]))
(bind header bytes)                      ;; parse
(construct header {version 1 length 5 body …})   ;; serialize
```

`datom.codec` today hand-writes both directions; a rigid binary pattern is
one declaration with both. This is what Erlang's bit syntax always
promised and bl inherits through Core.

## Sketch

- `pattern/rigid-complete?` (normal form check: every path bound or
  literal, no defaults, no `?view`/`?some`).
- `pattern/construct` : walk the normal form building the value bottom-up
  from bindings; refuse non-rigid-complete patterns with a message naming
  the lenient path.
- `pattern/gen` : same walk, each bind site → `(veritas/gen-for type)`;
  guards → filter, or SMT model when translatable.
- `defrecord` in `compiler.bl` emits the pattern value alongside the
  struct module; `record.ex` keeps the struct (interop) but the shape is
  read from the pattern.
- `veritas/for-all` gains a 1-arity form reading the fn's head patterns
  via `codebase` (`(clause-pattern ?fn ?i ?pat)` fact).
- Gate: round-trip laws `(construct p (bind p v)) = v` as `veritas`
  properties over `(gen p)` — the pattern tests its own inverse; `test/bl/`
  record tests unchanged.
