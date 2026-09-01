# Tempo, maximalist — time as a value in `datom.time`

**Thesis under test:** `ex_tempo` is the most complete model of *human*
time in any ecosystem — one type for every temporal value, the half-open
interval `[from, to)` as the atom of meaning, Allen's algebra and set
algebra defined uniformly, EDTF uncertainty, RFC 5545 recurrence,
cross-calendar / cross-zone comparison, and a constraint solver
(ChronoLog) over partially-known dates. It is an Elixir library: a
`%Tempo{}` struct, a `~o` sigil, a pile of protocols.

The interesting question is the maximalist one:

> If tempo were designed *natively* for beam-lisp — not ported, but
> re-conceived so each hard part lands on the subsystem beam-lisp already
> ships to solve exactly that shape of problem — what would it be?

The answer names itself once you ask where it lives. beam-lisp already has
a temporal module: `datom.time` — `as-of` / `since` / `history`, the
bitemporal filters over the store (`priv/datom/time.bl`, "the database
remembers"). That module owns **one** temporal axis: *transaction time* —
when the database learned a fact. Tempo owns the **other**: *valid time* —
when a fact is true in the world. They are not two libraries that happen to
share a word. They are the two axes of one bitemporal store, and the
maximalist tempo is the second half of `datom.time`.

This is the same programme as `jank-compat.md` and `specter-compat.md`,
pointed at a *domain model*: name the mapping, and a low-fidelity cell is a
successful measurement — it says precisely what to build.

---

## 0. One representation: the interval is a datom entity

Everything rests on the representational choice, and there is exactly one.
A temporal value is **a bounded interval at some resolution**, half-open
`[from, to)`. In `datom.time` that interval is not a struct, not a record,
not an entity with a datom per component. **It is a value type** —
`:db.type/time`, a new column type that sits in the schema beside
`:db.type/string` and `:db.type/instant`, and is stored the same way they
are: one packed value in one datom's value slot.

The name is deliberate on two counts. It is `time`, not `interval`,
because the type's whole claim — tempo's claim — is that this is what a
*temporal value* **is**: a year, a month, an instant, a span are not four
types but one, and `interval` names only the mechanism while `time` names
the thesis. (The constructor keeps `interval` for the *shape* —
`(time/interval …)` reads "a time value, of interval shape" — so the word
survives where it belongs.) And it coexists with the existing
`:db.type/instant` rather than replacing it: `:instant` is the legacy
scalar point (epoch millis, a zero-width moment); `:time` is the
interval-native value that *subsumes* it — an `:instant` is just a `:time`
at the finest resolution. Note too that `:db.type/time` here means *any*
temporal value, not SQL's time-of-day — the per-resolution fragmentation
(`DATE`/`TIME`/`TIMESTAMP`) is exactly what the one type abolishes.

This is the choice `priv/datom/vector.bl` already made, and it made it
against the exact temptation to avoid. An embedding *could* be a
`:db.type/term` holding `[0.1 0.2 …]`; vector.bl refused, and gave it a
value **type** and a packed shape, "for three reasons: storage, meaning,
safety." An interval faces the identical fork. It *could* be an entity —
a `:time/from` datom, a `:time/to` datom, `:time/resolution`, … — which
reads beautifully in a query but costs ~6 datoms and a ref-hop per date,
nowhere near a native `:db.type/instant`'s one packed 8-byte value. So it
takes vector.bl's road instead: one type, one packed value.

```clojure
(ns datom.time
  (:require [datom] [datom.db] [datom.index] [minikanren] [z3] [optics]))

;; :db.type/time — a packed, fixed-width value, riding the same
;; value-codec lane a native :db.type/instant does. [from,to) at a
;; resolution, in a calendar, at a zone. there is no separate Date /
;; Time / DateTime — one value type, its resolution just sets the width.
;;
;;   from:i64(8) │ to:i64(8) │ res:u8(1) │ cal:u8(1) │ zone:u16(2)  = 20B LE
;;
;; a column of these is contiguous and NIF-scannable, exactly like an
;; :instant column — the storage argument vector.bl makes for the DVec.
(defn interval
  "coarse→fine components in any order → a packed :db.type/time value,
   validated against its calendar. the ONLY constructor; every temporal
   value in the system is one of these."
  [& {:as parts}]
  (-> parts normalize-coarse-to-fine (validate-against-calendar) pack))

;; a point in time is an interval of width one resolution-unit. `now`,
;; `~D`, `~T`, `~U` all land here — same value type, different resolution.
(def instant (interval :year 2026 :month 6 :day 15 :hour 14 :minute 30 :second 0))
```

The `from`/`to`/`resolution` "components" are still there — but as
**projections** read out of the one packed value (`(time/from iv)`,
`(time/to iv)`), never as separately stored datoms. That is what keeps
"one representation" honest: the value is the interval; the endpoints are
views of it. When a *query* wants to join on an endpoint, a computed
relation exposes it (§2) — but the storage is one value, so a date costs
what an instant costs, not six times it.

Three properties come with being a real value type, and each is the reason
vector.bl chose one — **storage**: the packed 20 bytes decode by a
fixed-width read, no per-datom `binary_to_term`, a NIF can build a
contiguous column. **Meaning**: `:db.type/time` tells the schema what
you can *do* with the column — an order-preserving key codec (the same
two's-complement bit-twiddling `:db.type/long` uses) makes "intervals
starting before 1000" an `AVET` range scan, not a filter. **Safety**: a
new type cannot reinterpret an old value, so the 322 existing datom
round-trip tests keep passing untouched, and the value-codec's ESC lane
round-trips an interval *correctly* from day one — the packed lane is a
later speed step, not a correctness one, the exact migration vector.bl
documents for the DVec. (The trap this avoids, named in `02`: an interval
stuffed into a `:db.type/term` map *looks* fine — the ESC lane round-trips
it — but silently forfeits all three: no range scan, no fixed-width
column, no validation. "Sturdy" means give time its type, not the term
lane.)

And the bitemporal payoff is immediate. The one interval value carries
valid time; the store's `t` carries transaction time — two axes, one
datom:

```clojure
;; valid time: when is the fact TRUE?          — :time/from … :time/to
;; transaction time: when did we LEARN it?     — datom.time/as-of (the store's t)
;;
;; "what did we believe last Tuesday about when the reign held?"
(-> db (datom.time/as-of last-tuesday)       ; transaction axis (existing)
       (datom.time/overlaps? reign query-window))  ; valid axis (this design)
```

That sentence is a full bitemporal query, and neither tempo alone nor
`datom.time`-as-it-stands can express it. The rewrite is what makes the
module whole.

---

## 1. The sigil — `~o` becomes a data-reader

Tempo's `~o"2026-06-15"` is a compile-time sigil that parses ISO 8601-2
into a value. beam-lisp has the same shape with more reach:
**data-readers**, the mechanism datom already uses for `#d[...]` queries. The
tag→reader-fn mapping is beam-lisp source, not a hardcoded reader default: the
built-ins live in one central registry (`priv/data-readers.bl`) that
`BeamLisp.init/0` seeds at boot, alongside `#d` — the self-hosted analogue of
Clojure's `data_readers.clj` (core has `(reader-macro! "@" (quote deref))` for
the non-tag case).

```clojure
;; read time: #time"…" runs the ISO 8601-2 / EDTF / IXDTF grammar → a
;; valid-time value literal. one repr: it reads straight into a datom.
;; registered centrally in priv/data-readers.bl, seeded at boot:
(data-reader! "time" (quote datom.time/read-iso8601))

#time"2026-06-15"                          ; a day  — [2026-06-15, 2026-06-16)
#time"156X"                                ; a masked year — the 1560s (§4)
#time"2026-06-15T09/2026-06-15T17"         ; a closed interval
#time"1984?/2004~"                         ; per-endpoint EDTF qualifications (§4)
#time"2026-06-15T14:30[Australia/Sydney]"  ; IXDTF zone suffix
```

Strictly better than the sigil on two axes. A malformed literal is a
**read error at the source position** — the story
`examples/typing/01_check_demo.bl` tells ("each at the position the user
wrote") — not a runtime parse failure. And because `#time` yields a datom
entity (§0), a literal drops directly into a transaction:

```clojure
(datom/transact! conn [{:reign/name "Aethelred" :reign/span #time"978/1016"}])
```

The one thing the Elixir sigil does that a reader does not is
**pattern-match** (`match?(~o[2026Y], today)`). The one-repr answer is
cleaner than an overloaded sigil: an interval entity is map-shaped, so it
destructures and guards with mechanisms the language already has — no new
syntax.

```clojure
(let [{:time/keys [resolution]} today]
  (case resolution :year :a-year :day :a-day :second :a-moment))
```

---

## 2. Allen's algebra — `defmulti` for the predicate, `defrelation` for the join

Tempo's comparison layer is Allen's 13 interval relations plus the derived
predicates (`overlaps?`, `contains?`, `subset?`, `disjoint?`). Two
audiences, and because the value is *already a store entity* (§0),
beam-lisp serves both with no conversion between them.

**Predicate audience — `defmulti`.** Two intervals in hand, want the
relation. Straight comparison of the `:time/from`/`:time/to` longs:

```clojure
(defn allen [a b]
  (let [[a0 a1] (bounds a) [b0 b1] (bounds b)]
    (cond
      (= a0 b0) (cond (= a1 b1) :equals (< a1 b1) :starts :else :started-by)
      (= a1 b1) (if (< a0 b0) :finished-by :finishes)
      (< a1 b0) :precedes
      (= a1 b0) :meets
      (and (< a0 b0) (< b0 a1) (< a1 b1)) :overlaps
      (and (< b0 a0) (< a1 b1)) :during
      :else (inverse (allen b a)))))

(defn overlaps? [a b]
  (contains? #{:overlaps :starts :during :finishes :equals
               :started-by :finished-by :contains} (allen a b)))
```

**Query audience — Allen relations as datom relations.** This is the part
tempo cannot reach, and the part one-repr gives for free. Because every
interval is already an entity, the Allen relations are **computed
relations** in the exact sense of `examples/relations/01-defrelation.bl`:
a `defrelation` whose tuples a provider computes, joinable with stored
facts, usable as `[?a :~overlaps ?b]` — no projection step, because the
intervals never left the store.

```clojure
(rel/defrelation :~overlaps
  {:arity 2 :modes #{:bf :bb :fb} :tags #{:temporal :allen}
   :doc "intervals a,b such that Allen(a,b) is in the overlapping family"
   :provider (datom.time/allen-family :overlapping)})

;; "external meetings that overlap a deadline" — one query, not a fold.
(datom/q '[:find ?title ?deadline
           :where [?m :meeting/span ?a] [?m :meeting/title ?title]
                  [?m :meeting/kind :external]
                  [?d :deadline/span ?b] [?d :deadline/name ?deadline]
                  [?a :~overlaps ?b]]
         db)
```

The predicate world and the query world are the *same 13 relations*,
computed once, exposed twice — the "attribute spelling / call spelling,
both the same relation" duality that file demonstrates. Allen's algebra
stops being a comparison API and becomes part of the join planner.

---

## 3. Set algebra — it is already a bitemporal interval store

Tempo's `%Tempo.IntervalSet{}` is a sorted, non-overlapping, coalesced set
with union / intersection / complement / difference / symmetric-difference
and predicates — "the same sweep-line algorithms" as PostgreSQL
multiranges. With one repr there is no separate set type: **a set of
intervals is a set of entities**, and set operations are the operations the
store already has.

**Difference is negation. Intersection is a join.** "The day minus the
meetings" from tempo's booking tutorial is `datom/q` with `not-join`; the
metadata that "travels through set operations" (iCalendar summaries riding
on surviving intervals) is *just more attributes on the interval entity*,
carried through the join because that is what joins do.

```clojure
;; free = work-hours minus busy. summary/location ride along because they
;; are attributes on the entity, not a decoration the algebra remembers.
(datom/q '[:find ?free
           :where [?w :work/span ?window]
                  (not-join [?window]
                    [?m :meeting/span ?busy]
                    [(datom.time/overlaps? ?window ?busy)])
                  [(datom.time/subtract ?window) [?free]]]
         db)
```

**Reads are optics.** For the pointwise rewrites — clip every interval to
work hours, bump every busy span — `priv/optics.bl` does the thing
`update-in` cannot spell (`examples/optics.bl`): rewrite *every* slot at
once.

```clojure
(over (*> (in :intervals) traversed) #(intersect % work-hours) schedule)
```

Tempo had to *prove* its set algebra obeys the laws (associativity of
union, `[a,b) ++ [b,c) == [a,c)`). In `datom.time` those laws are
**inherited** from the store's set semantics — you do not re-prove
distributivity of join over union; it is the query engine's invariant
already. The difference between building an algebra and borrowing one.

---

## 4. EDTF uncertainty — three-valued logic wants a solver

Where the maximalist version pulls furthest ahead. Tempo's uncertain-dates
story: masks (`156X`), one-of sets, margins (`±`), EDTF qualifications
(`?`/`~`/`%`), and a **three-valued** answer — `certain` / `possible` /
`impossible` — because when the input is a smear, "does X fall in Y?"
cannot honestly be a boolean. beam-lisp ships two engines for exactly
"reason under partial information," and each takes a half.

**Masks and one-of sets → miniKanren.** A masked year `156X` is not a
value, it is a *relation*: `exists d in 0..9. year = 1560 + d`. Enumerating
it (`Enum.take(~o"156X", 5)`) is running that relation forward.
`priv/minikanren.bl` is precisely a relational enumerator over constrained
logic variables. "The 15th of every month in 1985" (`1985-XX-15`, tempo's
12-member set) is a fresh variable over months with the day pinned.

```clojure
(run* [year]
  (fd/in year (fd/interval 1560 1569))   ; 156X: low digit unknown
  (masked year 3 :X))
;=> (1560 1561 1562 1563 1564 1565 1566 1567 1568 1569)
```

**Qualifications and the three-valued verdict → z3.** "Does the artifact,
dated `1984?/2004~`, overlap the reign dated `199X`?" is a
**satisfiability** question with two verdicts that differ:

| tempo verdict | beam-lisp derivation |
|---|---|
| `certain` (yes) | `unsat` of not-overlap — no model separates them |
| `impossible` (no) | `unsat` of overlap — no model joins them |
| `possible` (maybe) | both `sat` — a model each way |

That is `z3/prove-equiv`'s exact shape (`priv/z3.bl`: "unsat = PROVEN for
all inputs; sat = counterexample"), lifted from rewrite-soundness to
temporal overlap. The z3 header even states the division of labour:
"the tag lattice owns structure, miniKanren owns relations, z3 owns
provability." Tempo's three-valued logic is the BEAM-native reading of
that sentence.

Tempo *computes* this with interval arithmetic. The maximalist version
*proves* it — and can **explain** it, because z3 returns the
counterexample model. "Possible, and here is the specific dating on which
they'd miss" is strictly richer than "possible."

---

## 5. `explain` — the language already narrates itself

Tempo's `explain/1` returns a structured explanation with semantic part
tags (`:headline`, `:span`, `:qualification`, `:metadata`) rendering to
text / ANSI / HTML. Not a nicety bolted on — the same instinct that runs
through beam-lisp's error and typing story (`priv/errors.bl` "the SOURCE
the user wrote", the hover evidence table, the ChronoLog "plain-English
trace for every bound").

So `explain` is a `defmulti` on the value's shape → a structured
`[:part tag content]` tree, with the render targets as protocol methods.
The one-repr twist: because the value is a store entity, an uncertain
verdict (§4) carries the **actual z3 counterexample** *and* the
**provenance** the store already records — the value explains itself with
evidence, the way the type checker does.

```clojure
(explain #time"156X")
;=> {:headline "a masked year spanning the 1560s"
;    :span     [#time"1560" #time"1570")      ; half-open, real bounds
;    :iterates :month
;    :parts    [[:qualification :masked-digit 3]]}

(to-ansi (explain #time"156X"))   ; coloured terminal
(to-html (explain #time"156X"))   ; the live UI surface (§8)
```

---

## 6. Cross-calendar & cross-zone — protocols and the store's bitemporality

Tempo compares Hebrew to Gregorian with no manual conversion, and set
operations across zones "compare by UTC, preserve the first operand's
zone." Two mechanisms carry this with no new concepts.

**Calendars are a protocol.** `defprotocol Calendar` with `to-rata-die`,
`from-rata-die`, `days-in-month`, `leap-year?` — the minimal basis every
calendar computation factors through. Gregorian, Hebrew, Islamic, ISO-week
each `extend-type`. Because §0 stores intervals as rata-die longs
(`:time/from`), cross-calendar comparison is *not* a special path: both
operands are already on the common line. `examples/protocols.bl`'s "a type
extended after the fact, old calls unaffected" is the property that lets a
new calendar drop in.

**Zones ride on the store's bitemporality — the reason this is
`datom.time`.** Tempo's subtle correctness point — "future dates survive
zone-rule changes," "storing a future event as UTC is unsafe" (its
falsehoods guide) — *is the invariant `datom.time/as-of` already
enforces*. A grounded future event stored wall-clock-plus-zone, resolved
to UTC only at read time against the zone rules *as of the read*, is the
temporal-database consensus tempo cites (Jensen/Dyreson's chronon). The
zone rule set is itself a bitemporal fact in the same store. Valid time
(the event) and transaction time (which zone rules were current) meet on
one entity — which is the whole argument for putting tempo *in*
`datom.time` rather than beside it.

---

## 7. ChronoLog — the constraint network is a fixpoint over the same db

Tempo's most ambitious feature is `Tempo.Network`: a web of
partially-known intervals (reigns, strata, tasks) with constraints between
them, solving for the tightest bound each can take, with a trace per
bound. `Tempo.Schedule` aims the same solver at critical-path scheduling.

In `datom.time` this is least a port and most a **recognition** — the
intervals are *already* entities in a db, so the constraint network is a
db, and the repo already contains, three ways over, the machinery of
propagation to a fixpoint:

- **z3** owns the hard version: constraints as SMT assertions, "tightest
  date" as an optimisation query, `unsat` as "your chronology is
  inconsistent" — with the counterexample naming *which* constraints
  clash. ChronoLog is itself a constraint solver; §4's machinery scales
  straight up.
- **datom recursive rules** (`examples/datom/12-recursive-rules.bl`) own
  the transitive-closure version: "A before B, B before C ⇒ A before C" is
  a recursive Datalog rule and the bounds are a **fixpoint** — which the
  repo benchmarks in `bench/fixpoint_bench.bl`. Critical path is
  longest-path over that closure.
- **miniKanren** owns enumerate-the-feasible when you want *all* consistent
  orderings, not just the tightest bound.

Maximalist ChronoLog is therefore a `defmulti` over the question:
propagate bounds (Datalog fixpoint), prove consistency (z3), enumerate
schedules (miniKanren). And every bound's "plain-English trace" is §5's
`explain` reading the **provenance** the store already records
(`examples/relations/07-graphrag-provenance.bl` — provenance is a
first-class query result). One db, three engines, no separate network
structure — because with one repr there was never anything to separate.

```clojure
(datom.time/tighten     db :reign/aethelred)  ; datom fixpoint → [from,to)
(datom.time/consistent? db)                    ; z3 → true | {:clash [...]}
(datom.time/why         db :reign/aethelred)  ; provenance → the trace
```

---

## 8. Recurrence & the live surface — RRULE is a lazy seq, a calendar is alive

**RFC 5545 RRULE is a lazy sequence.** Tempo expands recurrences ("every
Friday the 13th this century") into interval sets. beam-lisp has real lazy
seqs (`examples/lazy.bl`) with constant-space `loop`/`recur`, so an RRULE
is a lazy generator — infinite by default, `take`/`take-while`-bounded,
never materialised until a set operation forces it. The "shared AST for
ISO 8601 and RRULE" tempo documents is, here, one reader grammar feeding
two interpreters: `#time` for a literal, a lazy unfold for a rule. And the
bound is not a hope — `priv/termination.bl` **proves** the
`take-while (before? …)` finite, because a shrinking measure toward a
`:time/to` is exactly its accepted shrink shape.

```clojure
(->> (recur-rule {:freq :monthly :by-day :friday :by-monthday 13})
     (take-while #(before? % #time"2100"))
     (into []))
```

**A schedule is a live value.** `priv/live.bl` and the datom watch layer
(`examples/datom/live/`) mean a free-busy calendar is not a snapshot you
recompute — it is a **live** datom view. Add a meeting (a transaction) and
every downstream query — free slots, critical path, the rendered
availability grid (`priv/live/hiccup.bl`) — updates by the broadcast
substrate, not a poll. Tempo *computes* availability; beam-lisp *serves*
it, live, because "the runtime is the application." That is the half of the
thesis an Elixir library sits outside of.

---

## 9. The synergies one repr unlocks — the verification tier

Because an interval is a store entity and a process lowers to transition
clauses over the store (`priv/system/model.bl`), `datom.time` does not just
*answer questions about dates* — it makes time a term the **verification
engine** can quantify over. This is the tier tempo structurally cannot
reach, and it falls out of the single representation:

| module | what it is | what a `:time/span` on it buys |
|---|---|---|
| `system.model` | a process is a set of transition clauses | attach an interval to each transition → **timed automata**; every OTP process becomes temporally analysable |
| `system.core` | `[]Inv` inductive safety, *unbounded* | `[]` **is** temporal logic — "the deadline is never missed on any path" is an inductive invariant z3 proves for all executions, not a schedule spot-check |
| `system.step` | `:~step`/`:~reachable` as a datalog fixpoint | "is a late state reachable within budget?" and "what path leads there?" become `datom/q` with a `datom.time` bound as the guard — model-checking as a join |
| `effects` | lattice `pure < atom < spawn < io` | tempo's grounded-vs-floating becomes **type-enforced**: reading the clock is `io`, a floating interval is `pure`; "this scheduler secretly reads `now`" is a build error |
| `mock` | z3 run backwards — the SAT model *is* a value | "generate a date satisfying these constraints" is §4 run backwards; the z3 model *is* a valid interval — free property-test generators for temporal data |
| `deferred` | unknown = a constraint that retries on definition | tempo's "underspecification is uncertainty too" **is** a deferred constraint — a partly-known date tightens when a later fact grounds it, verbatim `deferred` machinery |
| `promote` | deodorant × types, type-discharged smells | temporal smells (`end_of_day` helpers, midnight off-by-ones, naive-UTC-of-future) become lint rules the `:time` type discharges with a proof — the bug classes tempo kills *by construction* become *provable* |
| `auth.rls` | row-level security as datalog facts | a biscuit scoped "readable `[2026-06-01, 2026-07-01)`" is an interval as an **authz fact**; expiry becomes an Allen `contains?` in the authorizer's own datalog, not a `checked_at > exp` special case |
| `reload.upgrade` | hot code upgrade of a running system | a **live running schedule** survives a code change to the scheduler — a library computing availability never can |

---

## The scorecard — where the maximalist version stands

The honest measurement, in the `jank-compat` idiom: name each tempo
capability, the `datom.time` home, and whether the mapping is *identity*
(already the same thing), *native* (buildable directly on an existing
engine), or *new* (genuinely to-build).

| tempo capability | `datom.time` home | fidelity |
|---|---|---|
| interval-as-type | a store entity, one repr (§0) | **identity** — datom gives it free |
| valid × transaction time | `:time/from…to` × existing `as-of` (§0) | **identity** — one bitemporal entity |
| `~o` sigil / parse | `data-reader!` `#time` (§1) | **native** — reader + ISO grammar |
| pattern matching | map destructuring + guards (§1) | **identity** — an interval is a map |
| Allen's 13 relations | `defmulti` + `defrelation` (§2) | **native** — dispatch + computed rel |
| set algebra (multirange) | store negation/join + optics (§3) | **native** — join = intersect, laws inherited |
| masks / one-of sets | miniKanren `run` (§4) | **native** — mask = constrained lvar |
| 3-valued uncertainty | z3 sat/unsat (§4) | **native** — richer: proves + explains |
| `explain` | `defmulti` → part tree + render (§5) | **native** — carries z3 + provenance |
| cross-calendar | `defprotocol Calendar` (§6) | **native** — one protocol, N impls |
| cross-zone / future-safety | store bitemporality (§6) | **identity** — `as-of` is the invariant |
| ChronoLog network | fixpoint ∪ z3 ∪ miniKanren, same db (§7) | **native** — three strategies, no new structure |
| critical-path schedule | recursive rules + `fixpoint_bench` (§7) | **native** — longest-path over closure |
| RRULE recurrence | lazy unfold + `termination` proof (§8) | **native** — infinite, provably bounded |
| live free-busy | `priv/live.bl` + datom watch (§8) | **new-and-beyond** — tempo has no runtime |
| real-time model checking | `system.*` + `:time/span` (§9) | **new-and-beyond** — a theorem, not a check |
| grounded/floating safety | `effects` lattice (§9) | **native** — a build error, not a doc note |
| the ISO grammar itself | to-build: the 8601-2 / EDTF / IXDTF reader | **new** — the one real port cost |

Read the right column top to bottom and the shape is stark: **one row is
genuinely new** — the ISO 8601-2 grammar, and even that is "a hand-rolled
reader over delimited fields," the exact phrase `priv/auth/biscuit/codec.bl`
uses for work beam-lisp does routinely. Four rows are *identity* — tempo's
hard-won invariant is already `datom.time`'s. Two are *beyond* tempo
entirely. Everything else is *native*: not a reimplementation, a
**pointing** of one entity at an engine that predates this document.

That is the maximalist claim, stated precisely. Tempo is the best model of
human time because it unified `Date`/`Time`/`DateTime` into one interval
type and then had to build — from scratch, in a sequential language — an
algebra, an enumerator, a solver, and a network to make that type answer
questions. `datom.time` does not build them. Choose the one representation
— the interval is a store entity — and set algebra is join, masks are
relations, uncertainty is provability, the constraint network is a
fixpoint over the same db, grounded-vs-floating is an effect type, and
"does this schedule ever miss a deadline?" is an inductive invariant. The
second axis of `datom.time` was always missing; tempo is its name.

The move the scorecard named — build the `#time` reader (the ISO 8601-2 /
EDTF / IXDTF grammar), the single *new* thing — is now done: `read-iso8601`
in `priv/datom/time.bl`, registered as `#time` in the central
`priv/data-readers.bl` registry, exercised by the eight demos in
`examples/datom/time/` and `test/bl/datom/time_valid_test.bl`. Every other
row falls out of the value it already is, measured cell by cell, a low score
naming exactly what to build next, the way every compat document in this repo
works.
