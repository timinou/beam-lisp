# 30 — Make it a value, lower by proof

*Patterns were the first instance. The move generalizes: take something the
compiler consumes as syntax, make it a value the language can inspect,
then let a proof about that value choose its lowering — with an
obligation that the choice preserves the value's meaning. This capsule
applies the move to everything else in beam-lisp that fits, and finds the
ones that don't.*

## The move, as a checklist

For a construct X:

1. **Value.** What is X as data? Give it a normal form and an interpreter
   (the spec `D⟦X⟧`).
2. **Facts.** Which questions become `codebase` queries once X is data?
3. **Proof.** What property of X's value, provable by an existing engine
   (`typed`, `footprint`, `termination`, `system.core`, `smt`, `veritas`),
   licenses a better lowering `L⟦X⟧`?
4. **Obligation.** `∀ inputs. L = D` over a finite abstract domain, or the
   step lowering is kept.
5. **What it deletes.** The parallel implementation that X-as-syntax
   needed.

Each section below runs the checklist on one construct.

---

## Guards → guard-safe predicates by proof

**Value**: a guard is already a form; its normal form is the `:test`
constraint (capsule 02). **Proof**: a user fn is *guard-safe* iff after
inlining it is pure (`footprint` = ∅), total (`termination`, no recursion
in a guard anyway), and composed of BIFs on the VM's guard list with no
allocation. Syntactic check plus two existing engines. **Lowering**: inline
into the clause head. **Obligation**: the inlined body, evaluated on the
abstract domain, equals the call — trivially, since inlining is
β-reduction; the *guard* semantics (failure → false, not throw) must equal
the *body* semantics (failure → throw), so the obligation is: the fn cannot
throw on the domain. `termination`+`typed` cover it. **Deletes**: the
Elixir `Kernel` guard whitelist as the definition of "guard".

## Loop measures → termination → cost → scheduler class → native

**Value**: `^{:decreasing expr}` is already data on the loop's binding
vector; `termination.bl` infers `(dec x)`/`(rest xs)` shrinkage without
it. Make the *measure* a first-class value: `{:measure expr :order :nat |
:seq-len :init form}`. **Facts**: `(loop-measure ?loop ?m)`. **Proof**:
measure decreases (exists) ⇒ bound on iterations ⇒ with per-iteration op
count (a walk over bl-ANF), a **work bound** `W(size(args))`. **Lowering**
by bound: `< 1ms` proven ⇒ eligible for `defnative` on the normal
scheduler; polynomial ⇒ dirty CPU scheduler; unbounded ⇒ stays BEAM (the
preemption guarantee is what makes it safe). **Obligation**: the NIF
equals the bl fn on the domain — `veritas.property` differential, with
the domain from the head pattern (capsule 22). **Deletes**: hand-written
NIF stubs and the judgement call "is this safe as a NIF".

## Multi-arity fn values → static arity resolution

**Value**: `{:"$blfn", fixed-map, variadic}` is a *runtime* value for a
dispatch table. Make the table a compile-time value on the var:
`(arities f) → {1 f/1, 2 f/2, :variadic {2 f__bl_v}}`. **Facts**:
`(arity ?fn ?n ?impl)`. **Proof**: a call site's argument count is a
literal (always). **Lowering**: direct `c_call` to the arity's fn — which
`linked-call` does today for *linked* names; extend to fn *values* whose
provenance is known (`(let [g f] (g 1))` where `f` is a var). **Obligation**:
same fn reached. **Deletes**: `RT.invoke`'s `$blfn` clause on every
resolved site; with capsule 01's one-shape fn, `$blfn` itself.

## Effects → footprint as a pattern over ops

**Value**: `footprint.bl` computes `{:R #{…} :W #{…} :A #{…}}` per fn — a
value already. Make the *footprint spec* a pattern: `^{:footprint {:W
#{:count} :R #{:log}}}` is a pattern over the op stream, and `check-purity-
claims` (`effects.bl`) is `subsumes?` between declared and inferred.
**Facts**: exist. **Proof**: monotone `:A` with no shrinking `:W` on a
state field = unbounded growth (Q2.2). **Lowering**: proven-pure fn ⇒
memoizable / parallelizable / guard-safe (above); proven-`:R`-only shared
value ⇒ `persistent_term` (Q2.4). **Obligation**: for `persistent_term`,
*no write after init* — a lifetime proof over the process graph, not a
local one; `system.core` `gfp` over `system.facts`. **Deletes**: the
`^:pure` claim as an unchecked annotation.

## Namespaces → the require graph as a value

**Value**: `(ns …)` is data; `source-graph.bl` (on `feat/fully-self-hosted`)
and `build-plan.bl` already treat the require graph as a value with
`closure-hash` and waves. **Facts**: `(requires ?ns ?dep)`, `(closure-key
?ns ?hash)`, `(wave ?ns ?n)` — all on the branch. **Proof**: a namespace's
*interface* (names, arities, variadic min, privacy, macro expansions —
PLAN-072's finding) is what callers depend on, not bodies. **Lowering**: an
interface hash as the freshness key ⇒ a body-only edit rebuilds one
namespace, not its dependents; `build-plan` waves run those in parallel.
**Obligation**: the interface hash changes iff any fact a caller's
emitted bytes depend on changes — testable by emitting the caller under
both and comparing (the deterministic-emit work on the branch is exactly
this). **Deletes**: closure-hash-as-freshness (over-invalidation). *This
is the branch's W3–W4; the move is already being made there.*

## Errors → structured, pattern-shaped

**Value**: `errors.bl` delaborates a compile diagnostic to a source line +
caret. An error is a map `{:kind :pos :form :expected :got}` — `explain`'s
output (capsule 20) *is* this shape for pattern failures. Make every
runtime error that shape: `ex-info` data = `{:path :expected :got}`.
**Facts**: `(raises ?fn ?kind)` from `footprint`'s throw tracking.
**Proof**: an error kind never raised on the domain (typed + tree
exhaustiveness) ⇒ its handler is dead. **Lowering**: `try` with a proven-
unreachable typed catch drops the clause; a fn proven not to raise is
called without the `try` wrapper a caller added defensively (warn, don't
delete — the caller's intent). **Obligation**: the raise-set of `L` ⊆ that
of `D`. **Deletes**: five error shapes across multi/protocol/match/catch
(capsule 24).

## Metadata → typed, pattern-constrained

**Value**: `^{…}` is a map; `var-meta-map` stores it. Give metadata a
*pattern* per key: `^{:t <shape>}`, `^{:decreasing <form>}`, `^{:footprint
<fp-pattern>}`, `^{:doc <string>}`, `^{:arglists <patterns>}`. **Facts**:
`(meta ?var ?key ?value)`. **Proof**: metadata that is *derivable* (arglists
from head patterns, footprint from analysis, doc from — nothing) is
checked against the derivation; a mismatch is a warning. **Lowering**:
derivable metadata is *not stored* — it is a query. **Deletes**: stale
`:arglists`; the drift between what a var says and what it is.

## Time → temporal patterns over the log

**Value**: the datom tx log and `tempo` are ordered event streams. A
temporal pattern `(?seq p₁ (?within 100 p₂))` (capsule 25) is a value.
**Facts**: `(tx ?t ?e ?a ?v ?op)` exist. **Proof**: `system.core`'s `gfp`
over the transition graph decides whether a temporal pattern is
*satisfiable* by any run — model checking. **Lowering**: satisfiable ⇒
compile the pattern to a state machine subscribed to `datom.broadcast`;
unsatisfiable ⇒ compile-time "this can never fire". **Obligation**: the
machine accepts exactly the runs `D` accepts (standard automaton
equivalence, finite). **Deletes**: hand-written CEP loops over the log.

## Processes → `defprocess` bundles as values

**Value**: the docs (`the-process-pattern-language`, `the-five-bundles`)
already describe `defprocess` as a composition of *patterns* (server, bus,
registry, supervisor, fence) — a process is a value built from pattern
values. **Facts**: `system.knowledge` projects it. **Proof**: capsule 25
(protocols, completeness, code_change totality); Q2.1 (heap bound from
`state-shape`); Q2.2 (leak). **Lowering**: proven-bounded ⇒ `min_heap_size`
+ tripwire `max_heap_size`; proven-idle ⇒ `hibernate`; proven high-fanin
⇒ `off_heap` mailbox. **Obligation**: process flags do not change
semantics — trivially — but a *wrong* bound crashes a healthy process, so
the obligation is on the *proof's* soundness: the bound must be derived
from an invariant `system.core` marked `:proven`, never `:witnessed`.
**Deletes**: operator-tuned `Env.max_heap_words`.

## The build → a value already

`build-plan.bl` on the branch: sources → `{:order :keys :waves}` in one
traversal, with a contract test that every hash is asked once. That *is*
the move applied to the build, and it is the model for the rest: the
plan is data, the O(V+E) property is a test, waves are a proof of
independence that licenses parallel lowering.

## The reader → binary patterns

**Value**: reader nodes are values; the *reader itself* is Elixir-shaped
`.bl` over binaries. Once bl has binary patterns (`?bin`, capsule 22 —
Core has them natively), a reader written as `(match bytes (?bin [\( &
rest]) … (?bin [\" & rest]) …)` is a decision tree over bytes — what
Erlang's own scanner is. **Proof**: exhaustiveness over the byte domain
(256 cases — finite) proves the reader handles every input. **Deletes**:
nothing yet; the current reader works. This is where "the last piece of
the toolchain in the language's own vocabulary" would land.

---

## Where the move does not apply

Honesty about the boundary of the idea:

- **Macros.** A macro is already a value (a fn). Its *expansion* is not
  data the compiler can inspect before running it — that is the point of
  a macro. "Prove the expansion" = run it. No lowering choice to make.
- **Interop calls.** `(String/split s ",")` — the callee is outside the
  language; no normal form, no proof, `c_call` is already the best
  lowering. Boundary patterns (capsule 26) handle what *comes back*.
- **The substrate floor (`rt.ex`, `vector.ex`).** These are the `D` for
  much of the above. Making them values would make the spec depend on
  itself. They migrate to `.bl` by the FUP-016 rule (benchmark-earned),
  not by this move.
- **`Bootstrap.install!` / `compiler_key`.** Run before `BeamLisp.init` —
  no Env, no reader (PLAN-072's hard floor). Cannot be a bl value because
  nothing can read it yet.

## The pattern of the whole capsule set

Every instance above is the same sentence: **the program says what it
means once, as a value; the proof reads that value; the lowering is
whatever the proof licenses; an obligation guards the equivalence.** The
proof does not describe the program. It selects it. beam-lisp's
maximalist thesis — the language, the harness, the runtime and the
application are one thing — is this sentence applied until nothing is
left that is only syntax.
