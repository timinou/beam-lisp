# z3 is not an Int solver

*A zero-context explanation of P19: how our verifier learned to speak every
theory z3 knows — Real numbers, Booleans, text — instead of only whole numbers.*

---

## Start from the very beginning

We have programs made of little **state machines**. A bank account is one: it
holds a `balance`, and messages change it — `deposit`, `withdraw`. A network
connection is another: it's `open` or `closed`, and messages flip it.

We can **prove** things about these machines. Not test — *prove*, for every
possible sequence of messages, using a tool called **z3** (a theorem prover
bundled right into the project). The promise we prove is called an **invariant**:
"the balance is never negative," "you can't send on a closed connection."

The command that does this is `verify-process`. You write the promise as an
annotation and it gets proven:

```clojure
(defserver ^{:invariant (>= balance 0)} account …)
```

## The problem: everything was a whole number

Until P19, every machine's state had to be a **whole number** (an integer).
A balance was an integer. A rate of 5% — `0.05` — could not be modelled,
because `0.05` is not a whole number. A machine whose state was a piece of
**text** ("the last log line") could not be modelled at all.

This felt like a law of nature. It was not. It was a bug in *our* code.

## Where the cage really was

Here is the surprising part. z3 — the actual prover — was **never** limited to
whole numbers. z3 has always understood:

- **Real numbers** (`0.05`, √2, anything with a decimal),
- **Booleans** (true/false),
- **Text / strings** ("evt:init", with real operations like "does this start
  with 'evt:'?"),
- and more (bit-patterns, arrays, lists, custom shapes).

Each of these is called a **theory** — a self-contained world of things z3 can
reason about. z3 speaks all of them.

The way we *talk* to z3 is dead simple: we hand it a piece of text (in a
standard language called SMT-LIB) and it answers `sat` or `unsat`. That
text-passing wire never cared what theory the text used. **Every theory was
already reachable.**

The limitation lived entirely in **our translator** — a file called `smt.bl`
that turns a machine's state into z3 text. It had exactly two hardcoded rules:

```clojure
;; the entire cage, in one function:
(if (or (= value "true") (= value "false")) "Bool" "Int")
```

Translation: *"if the field is literally the word true or false, call it a
Boolean; otherwise call it a whole number."* Two cases. Everything that wasn't
a Boolean got forced into "whole number," and anything that couldn't be a whole
number (a decimal, a string) was thrown away as "can't translate this."

We built the prison and then assumed z3 was the one locked in.

## We proved it in one sitting

Before changing anything, we asked z3 — through the **unchanged** wire — one
question per theory. All fifteen came back correct:

| we asked z3… | theory | answer |
|---|---|---|
| does √2 exist? | Real | yes (`sat`) |
| is `x & (x−1) = 0` solvable? | bit-patterns | yes — powers of two |
| does `store then read` give back the value? | arrays | yes, always |
| can a string start with "evt:" and contain "ok"? | text | yes |
| is a connection `idle` ever `open`? | custom shapes | no, never |
| what's the largest `x` with `x≤10 ∧ x≤7`? | optimization | 7 |

Not one of these needed a change to how we talk to z3. The solver was ready the
whole time.

## The fix: let the type decide the theory

Every value in the language already has a **tag** — the type system infers it.
`0.05` is tagged `:float`. `true` is `:bool`. `"evt:init"` is `:string`. `42`
is `:int`. This inference is not new; it's the whole typing phase, shipped long
ago.

So the fix is a single honest wire — a **functor** (a fancy word for "a
consistent mapping"). It reads each field's tag and picks the matching z3 theory:

```
:int    → Int        (whole numbers)
:float  → Real       (decimals)
:bool   → Bool       (true/false)
:string → String     (text)
```

That's it. The two hardcoded cases became a lookup over the types we *already
knew*. The thesis the project always stated — **"the state is the type
lattice"** — finally reaches past the integers, because now a field's inferred
type genuinely chooses how it's modelled.

## What you can write now

**A real-valued invariant** (an interest rate that must stay non-negative):

```clojure
(defserver ^{:invariant (>= rate 0.0)} rated
  (init [] (ok {:rate 0.05}))                    ; 0.05 → rate is a Real
  (handle-call [:bump amt] [_ {:keys [rate]}] :when (>= amt 0.0)
    (reply :ok {:rate (+ rate amt)})))           ; real arithmetic, proven
```

`rate` inits to `0.05`, so the functor makes it a `Real`. The proof runs over
real-number arithmetic. And `amt` — the message input — is inferred to be a
`Real` too, **by flow**: it gets added into `rate`, and z3 will not add a whole
number to a decimal, so it must share `rate`'s theory. (See demo
`examples/system/16_real_valued_state.bl`.)

**A text-content invariant** (every log line keeps its "evt:" prefix):

```clojure
(defserver ^{:invariant (str-prefix? "evt:" last)} auditlog
  (init [] (ok {:last "evt:init"}))
  (handle-cast [:append body] [_ {:keys [last]}]
    (noreply {:last (str "evt:" body)})))        ; text, proven — not a length
```

This is genuinely new ground. Before, the best we could say about a collection
was *how big* it is (its length). Now we can reason about *what's inside* — the
actual characters. `(str-prefix? …)` becomes z3's `(str.prefixof …)`, `(str a
b)` becomes `(str.++ …)`. (See `examples/system/17_string_content_state.bl`.)

**All of them at once.** One `verify-process`, four theories, each field
choosing its own — demo `examples/system/18_theory_directed.bl`:

```
Int    counter (n ≥ 0)        checked=true holds=true
Real   rate (rate ≥ 0.0)      checked=true holds=true
Bool   latch (done ⇒ done)    checked=true holds=true
String log (evt: prefix)      checked=true holds=true
```

No per-theory code path. The field's tag picks the sort; the same one checker
proves them all.

## A real bug we found on the way

Fixing the translator surfaced a second, older bug — in a function called
`delaborate` (which turns a parsed value back into source text). In this
language, unlike some others, printing a string does **not** add quotes:
`"evt:init"` prints as bare `evt:init`. So when `delaborate` handed that back
and something re-read it, `evt:init` was mistaken for a **symbol** (a variable
name), not a piece of text — and the string machine's proof silently broke.

The fix: `delaborate` now re-adds the quotes, so text round-trips as text. This
is the same family of bug as two earlier `delaborate` gaps (it didn't handle
maps or keywords either). Fixed at the root, with a regression test.

## The honest boundary

Two theories can hand back **"unknown"** on hard problems — z3 is allowed to
give up on genuinely undecidable questions (some quantified or string problems
have no algorithm that always terminates). *Reachable* is not the same as
*always-decidable*. When that happens, the guarantee is filed as
**approximate**, in the exact-vs-approximate catalog the project already keeps —
the same honest split used for bounded collection checks. We never call an
"unknown" a proof.

## Why this matters beyond the feature

This is the smallest possible change with the largest possible reach: we deleted
two hardcoded lines and gained every theory z3 has, because the type system was
already doing the hard part (knowing each value's shape) and z3 was already
willing (it always spoke every theory). The lesson is the one the project keeps
re-learning — **the right primitive answers questions you never posed.** The
type lattice was that primitive; we just hadn't connected the last wire.

---

*Code: `priv/system/smt.bl` (the functor + theory operations),
`priv/system/core.bl` (`node-sort`, input-sort-by-flow), `priv/errors.bl`
(the `delaborate` string fix). Proof it all reaches z3:
`research/p19_datalog_feed/spike_theories.bl`. Demos:
`examples/system/16`–`18`. Tests: `test/bl/system/seam_test.bl`.*
