#import "_preamble.typ": *

#show: typing-doc.with(
  title: "Richer State Models",
  subtitle: "The state model is the type lattice — and it was built two phases ago",
  kicker: "beam-lisp · system-model tier · P18",
  dateline: "2026-08-29",
)

= The one-sentence thesis

The system-model tier proves behavioural properties of a process by modelling
its state as #term[one integer]. Everything you'd want next — multiple
variables, records, collections, sum-typed protocols, and invariants #term[discovered
rather than annotated] — is not a second research programme. It is a
#term[wiring] job between two things that already exist and were built to fit:
the #term[tag lattice] from the typing phase (which already infers the shape of
every value) and the #term[guarantee engine] from the system phase (which already
proves over SMT). This document shows the seam, proves the two load-bearing
claims with runnable spikes, and lists what to build.

#idea(title: "The through-line")[
  The typing phase inferred #term[shapes]. The system phase proves #term[behaviour
  over shapes]. "Richer state models" is the missing wire between them —
  #term[type-directed SMT translation]. The information is not missing; it is
  inferred and sitting one namespace away.
]

= What "state" is today, exactly

Read `priv/lib/system/core.bl`. `verify-process` collects the state variables an
invariant mentions, and then:

```clojure
svars (state-vars inv-node clauses)
svar  (if (empty? svars) nil (first (into [] svars)))   ; ← takes the FIRST
```

And `priv/lib/system/smt.bl` states its own ceiling honestly:

#verified[
  "State vars are modelled as SMT integers — the common case for process state
  (balances, counters, phases-as-ints). Non-integer state (maps, strings) is out
  of this translator's scope and surfaces as `:untranslatable`."
]

So the model of a process's state is: #term[one integer that moves]. `balance =
5`, guarded by integer arithmetic, discharged by z3. When state is anything
else, the translator returns `:untranslatable` and the checker stays silent
rather than lie. That is a real and sound floor — and it is a floor, not a
ceiling, only because the richer information is being thrown away, not because it
is unavailable.

= Claim 1 — most of the work is already done

The lift to richer state has two halves: #term[infer the structure] and #term[prove
over it]. The first half is the entire typing phase, already shipped. The second
half is the guarantee engine, already shipped. What is missing is the adaptor
between them. Here is the inventory.

#table(
  columns: (auto, 1fr, auto),
  inset: 7pt,
  align: (left, left, left),
  table.header([*capability*], [*already built, where*], [*status*]),
  [value shapes], [`typed/all-tags` lattice: `:int :float :map :vec :set :string
    :bool :fn :nil :sym :seq :list` — every value's tag inferred by `typed/walk`], [✓ shipped],
  [flow narrowing], [`walk-if` / `guard-narrow`: `(if (int? x) …)` refines `x` to
    `:int` in the then-branch, `:diff` in the else — path-sensitive], [✓ shipped],
  [record fields], [`bind-pattern` destructures `{:keys [...]}` and map patterns,
    binding each field], [✓ shipped],
  [signatures from source], [`sigs-from-env` reads `^{:args :ret}` off name meta
    through the real compile pipe — no re-declaration], [✓ shipped],
  [multi-var SMT], [`preserves?` already declares `svar` + `svar2` + inputs and
    primes; N was a loop where there was a `first` — now generalized], [✓ shipped],
  [candidate predicates], [`system.core/candidates` — miniKanren enumerates
    `(op a b)` over a domain, deduped], [✓ shipped],
  [z3 preservation], [`preserves?` / `sufficient?` / `establishes?` — the Hoare
    triple discharge], [✓ shipped],
  [effect / footprint], [`system.footprint/fp-walk` reads resource modes from a
    body — never annotated], [✓ shipped],
)

Every row is now #term[shipped]. The last to land, Rung 1, was genuinely a
truncation bug: `state-vars` #term[collected the set] of state variables, and
`verify-process` #term[kept one]. The z3 layer beneath it (`preserves?`) already
handled a current var, a primed var, and declared inputs — it was always N-ary;
only the seam narrowed it to one. Fixing that opened the whole ladder.

== Proof: multi-variable relational invariants (Rung 1)

To show the machinery generalizes, `research/p18_state_models/spike_multivar.bl`
models a two-variable state with a #term[relational] invariant — one that a
single-integer model #term[cannot express]:

```clojure
state      {:balance b, :reserved r}
invariant  (and (>= reserved 0) (>= balance reserved))
           ;; reserved funds are non-negative AND never exceed the balance
```

The check declares the whole tuple, primes it jointly (`balance2`, `reserved2`),
and asks z3 whether any transition can break the coupled predicate.

#ran("elixir … research/p18_state_models/spike_multivar.bl")[
  ```
  reserve  preserves invariant: true
  release  preserves invariant: true
  withdraw preserves invariant: true   (guards against FREE funds)
  buggy withdraw preserves invariant: false   (guards whole balance)
  PASS: three good transitions proven, the reservation-ignoring bug caught
  ```
]

#verified[
  The relational invariant `balance ≥ reserved` is proven for three transitions,
  and a buggy `withdraw` that guards the whole balance (ignoring the reservation)
  is caught with the exact reasoning a single-variable model is blind to: it can
  drive `balance < reserved`. The z3 mechanism needed #term[no change] — only the
  seam that today writes `(first svars)` needs to declare and prime the whole
  set.
]

= Claim 2 — the way it was built leads to crazier things

Here is the part worth slowing down for. The typing phase did not build a type
#term[checker]. It built a #term[relation] and a set of #term[engines], and a
relation runs in every direction. That design choice — visible in `typeo` and in
the strict engine division — means the richer-state ladder does not just climb to
"more types". It climbs to capabilities that were never on the original list.

== The relation runs backwards: synthesis, not just checking

`examples/typing/04_holes_demo.bl` defines `typeo`, a bidirectional typing
relation in miniKanren. The demo's own words:

#verified[
  "The relation is the same artifact that checks (forwards), refutes (sideways),
  and synthesizes (backwards): `typeo`."
]

A checker answers "does this term have this type?". A #term[relation] also
answers "#term[what terms have this type?]" — run `typeo` with the term as the
unknown and it #term[enumerates inhabitants]. The holes demo fills a typed hole
with real expressions from the local context; the ill-typed hole gets no answer.

Now apply that to #term[state]. Once state has a type richer than `Int`, "what
transition preserves this invariant?" is the #term[same backward run]. The tier
stops being "prove the invariant the human wrote" and becomes "#term[synthesize
the guard that makes the invariant hold]" — program repair, from the same
relation, for free.

== The engines were kept strictly non-overlapping — so they compose

The system phase inherited a discipline from the typing phase: #term[four engines,
no fallbacks, strict ownership].

#decision(because: "each engine answers a different KIND of question, so a
richer state model recruits all four without any one leaking into another's
territory")[
  #term[tag lattice] owns structure · #term[z3] owns arithmetic decisions ·
  #term[miniKanren] owns relations and synthesis · #term[datalog] owns the
  codebase-as-facts. Effects are a fifth, folded in as a footprint lattice.
]

That non-overlap is why the ladder is composable rather than a rewrite. A
sum-typed protocol state, at the summit, uses #term[all four at once]: the
lattice gives the variant tags, z3 proves the per-variant arithmetic, miniKanren
synthesizes the missing transition, datalog checks every #term[caller] speaks the
protocol. None of them has to learn another's job.

== The crazier thing, proven: invariants discovered from nothing

The boldest consequence. Today you must #term[write] `^{:invariant (>= balance
0)}`. But the machinery to #term[discover] it is already present: `candidates`
enumerates predicates, `preserves?` decides them, and the state vars come from
the lattice. Assemble those into a #term[Houdini fixpoint] (Flanagan–Leino) —
start from every candidate that holds at the initial state, drop any conjunct a
transition can break, iterate — and the invariant #term[falls out of the code].

`research/p18_state_models/spike_discover.bl` runs exactly this on an
#term[unannotated] account machine:

#ran("elixir … research/p18_state_models/spike_discover.bl")[
  ```
  candidate vocabulary (6): (<= balance 0) (<= balance 1) (<= balance 5)
                            (>= balance 0) (>= balance 1) (>= balance 5)
  hold at init (balance=0): (<= balance 0) (<= balance 1) (<= balance 5) (>= balance 0)
  ∧ survive induction:      (>= balance 0)
  DISCOVERED INVARIANT:  (and (>= balance 0))
  PASS: discovered (>= balance 0) from nothing; refuted the bogus candidates
  ```
]

#verified[
  From an account with #term[no annotation], the loop discovers `(>= balance 0)`
  and refutes every bogus candidate (`<= balance 0`, `>= balance 5`, …). The one
  subtlety, pinned in the spike: Houdini must be seeded with a #term[consistent]
  set, so the establishment filter (what holds at `init`) runs #term[before]
  induction — otherwise the contradictory candidates make the antecedent
  unsatisfiable and induction is vacuous. Order matters; the result is real.
]

This is `abduce`'s existing search aimed at the #term[whole] invariant instead of
a missing conjunct, seeded by the inferred state vars. "Implied invariants" was
never a missing engine — it was a loop we had not yet written around engines we
already had.

= The ladder

Each rung is a concrete capability, and each names the existing machinery it
recruits. The difficulty is honest: the top two rungs cross z3's decidability
line and pay for it in the #term[approximate-guarantee catalog] the system tier
already ships (`exact-guarantees` vs `approximate-guarantees`).

#table(
  columns: (auto, 1fr, auto),
  inset: 7pt,
  align: (left, left, center),
  table.header([*rung*], [*state model → what it buys*], [*warm*]),
  [1 · multi-var], [tuple of ints; relational invariants (`balance ≥ reserved`).
    Rate limiters, pools, coupled counters. #term[Shipped] — demo 10.], [21 ms],
  [2 · records], [product of typed fields (int × bool); mode/flag machines
    (`frozen ⇒ balance = 0`). Each field its own z3 sort, read from init.
    #term[Shipped] — demo 11.], [23 ms],
  [3 · collections], [capacity via length abstraction (`count ≤ 10`), EXACT;
    content (no-duplicate) is the bounded companion. The catalog keeps them
    apart. #term[Shipped] — demo 12.], [19 ms],
  [4 · sum types], [tagged variant as a phase (`:idle | :open | :closed`);
    session-type conformance (`send ⇒ open`), use-after-close caught. #term[Shipped]
    — demo 13.], [17 ms],
  [★ · discovery], [invariant synthesis via Houdini over the state vars. No
    annotation. #term[Shipped] — demo 14.], [99 ms],
)

#idea(title: "Type-directed translation is the whole mechanism")[
  Today `smt.bl` hardcodes `Int`. The lift is: for each state var, ask the tag
  lattice its type and emit the matching z3 sort — `Int`, `Bool`, `(Seq …)`,
  `(Array …)`, a declared datatype. `state ≜ ⟦type-lattice⟧`. The translator
  stops assuming and starts #term[consulting]. That single indirection is Rungs
  2–4.
]

= What is already inferred (the "implied everything" audit)

The user asked specifically what is #term[implied] rather than annotated. The
answer is: nearly everything except the top-level invariant, and even that is now
in reach.

#table(
  columns: (auto, auto, 1fr),
  inset: 7pt,
  align: (left, center, left),
  table.header([*property*], [*inferred?*], [*where*]),
  [types], [✓], [the entire tag-lattice phase — no annotation needed],
  [effects / footprints], [✓], [`fp-walk` reads resource modes from the body],
  [process name (when unnamed)], [✓], [`model/content-hash` — `↻⟨labels⟩·hash` over the transition graph],
  [handled message protocol], [✓], [`handled-labels` reads the accepted set from the clauses],
  [unhandled messages], [✓], [join of `:call/*` senders against handled — the check TLA#super[+] cannot make],
  [missing preconditions], [✓], [`abduce` — miniKanren enumerates, z3 decides, shortest-first],
  [return types], [✓], [`codebase/infer-clause-ret` — `typed/walk` over the body when unannotated],
  [termination measures], [◐], [`termination` proves `dec`/`rest` shrinking; `^{:decreasing}` is the escape hatch],
  [the top-level invariant], [★], [#term[was] annotate-only; the discovery spike above closes it],
)

#decision(because: "the two auto-strengthening pieces already ship, and
discovery is the same search with a wider target")[
  `abduce` #term[strengthens] a given invariant with a missing conjunct;
  `all-senders-guarantee?` #term[infers a whole-program obligation] from the call
  graph. Discovery is those same engines run as a fixpoint over the lattice's
  state vars — the last "annotate-only" property becomes inferred.
]

= The demos it produced

The work was filed as `PLAN-050` — six pieces, dependency-ordered, each shipping
as #term[tests and a demo] (the tier's graduation contract) — and all six are
done. The demos are the proof surface; every one runs clean:

#table(
  columns: (auto, 1fr),
  inset: 7pt,
  align: (left, left),
  table.header([*demo*], [*the story it tells*]),
  [`examples/system/10_multivar_invariant.bl`], [a reservation account:
    `balance ≥ reserved ≥ 0` proven; the reservation-ignoring withdraw caught —
    a bug invisible to single-variable models],
  [`examples/system/11_record_state.bl`], [a mode machine: `frozen ⇒ balance = 0`
    over a `{:balance int :frozen bool}` record; a transition that pays out while
    frozen caught — mixed-sort state],
  [`examples/system/12_collection_state.bl`], [a bounded work queue: "the pending
    queue never exceeds capacity" as a #term[bounded] guarantee, registered
    honestly in the approximate catalog],
  [`examples/system/13_protocol_state.bl`], [a connection with `:idle | :open |
    :closed`; an illegal `:send`-while-`:closed` transition caught — sum-typed
    protocol conformance],
  [`examples/system/14_discover_invariant.bl`], [point the checker at an
    #term[un-annotated] server; it #term[prints the invariant it discovered] and
    then proves it — the headline],
  [`examples/system/15_type_directed.bl`], [the same server, three state shapes
    (int, record, sum); the #term[one] translator adapts by consulting the
    lattice — showing the mechanism, not just the results],
)

= Where it stands

The whole ladder is #term[shipped], not spiked. One `verify-process` proves an
invariant over five state shapes — a scalar int, a tuple of ints with a
relational invariant, a mixed-sort record (int × bool), a phase-coded variant
(protocol conformance), and a collection abstracted to its length — each by
reading the field sorts from the init state, each with its bug caught and
rendered like an ordinary compiler warning. And the invariant itself is
#term[discovered from nothing] by a Houdini fixpoint when there is no annotation.
`examples/system/10`–`15` demonstrate every rung; the seam tests grew from 9 to
21 cases; the non-auth suite is green at #term[647 tests / 1760 assertions / 0
failures].

Two bugs were fixed at the root along the way, both found by a rung disagreeing
with an obviously-correct case: `errors/delaborate` had no map case (record
state rendered as a raw tuple), and `free-syms` declared the boolean literals
`true`/`false` as integer inputs, shadowing SMT's booleans and silently breaking
any transition that assigned a bool literal. Neither was worked around.

Nothing here is a new engine. All of it is the wire between two phases that
were, in retrospect, built to be connected: the type lattice infers the shape,
the guarantee engine proves over it, and “richer state models” was the
type-directed translation between them. That is the sense in which most of the
work was already done — and the sense in which the way it was done reached
further than the original proposal: a relation that synthesizes, four engines
that compose, and an invariant that no longer needs a human to state it. The
remaining depth is genuine (z3-sequence CONTENT invariants beyond length; a
richer candidate vocabulary for discovery) but it is depth on a shipped
foundation, not a missing floor.
