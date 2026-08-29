# The codebase becomes a database

*Seven things beam-lisp's type system yields that we did not expect when
we started. Written for a reader who has never seen beam-lisp or thought
about type checkers.*

---

## Zero-context primer (three paragraphs, then the good part)

**beam-lisp** is a small Lisp that runs on the BEAM — the virtual machine
under Erlang and Elixir, built for enormous numbers of lightweight,
message-passing processes. Being a Lisp, its code is written in the same
shape as its data: a program is nested lists like `(+ 1 2)`, and the
language can quote, inspect, and transform its own code as easily as it
transforms any list. This property is called *homoiconicity*, and it is
the quiet hero of everything below.

We are adding a **type system**: a compile-time analysis that figures out
the shape of every value — "this is an integer, that function takes a
string and returns a list" — so mistakes are caught before the program
runs. Ours is deliberately simple: about a dozen basic kinds of values
(integers, strings, keywords, maps, vectors, functions…), plus optional
annotations a programmer can write when they want to say more, plus a
**logic solver** (Z3, an industrial theorem prover) for questions like
"can this condition ever be true?" The checker never guesses: it only
warns when it can *prove* something is wrong.

What makes this project unusual is what beam-lisp already ships with: a
full database engine of its own (**datom**, a Datalog database — a
database you query with logic rules), a code-rewriting engine
(**rewrite**), a smell-fixer built on it (**deodorant**), and composable
data-navigation tools (**specter/optics**). We expected the type system
to be a linter bolted onto the side. Instead, these existing pieces fused
with it, and seven capabilities fell out that nobody had on the roadmap.
Here they are.

---

## 1. The codebase becomes a database

A traditional compiler reads your code, checks it, and throws the
analysis away. Ours stores what it learns — every function's name,
arguments, body, and inferred type — as **facts in a queryable database**.

That single move turns "checking" into "asking questions":

- *Where is this function called with the wrong kind of argument?* — a
  query.
- *Which functions does nothing call anymore?* (dead code) — a query.
- *If I change this function's type, what breaks?* (impact analysis) —
  a query.
- *Show me every place that builds an `{:error …}` value.* — a query.

Editors, linters, refactors, and code search all become different
questions asked of the same database, instead of four separate tools
that each re-parse your code and disagree with each other. Because the
database engine (datom) already exists in the standard library and is
built for exactly this — logic rules over facts — each of these tools is
a few lines of declarative rules rather than a new program.

## 2. The tooling checks itself

The type system's first customer is not your code — it is the *tools
that operate on your code*.

Deodorant, our smell-fixer, works as a set of rewrite **rules**:
"whenever you see `(not (= a b))`, write `(not= a b)`." These rules are
plain data, and whole rule sets are combined by simply concatenating
them. Wonderful — until two rule sets disagree about what a name means,
the same way two spreadsheets disagree when one has three columns and
the other has two.

The type system watches the toolbench: rule sets, query fragments, and
rewrites are values with checkable shapes, so composing two of them
incorrectly is a *type error*, caught before anything runs. The very
machinery we built to check user programs turns around and certifies the
tools themselves. A language whose tooling is self-certifying is a rare
thing; here it cost nothing extra.

## 3. Macros can ask the theorem prover questions — at compile time

Lisp macros are programs that write programs: they run while your code
is being compiled and reshape it. Because the logic solver is an ordinary
library function — `(smt/satisfiable? '(and (> x 3) (< x 3)))` — a macro
can *consult* it mid-expansion.

That unlocks things macros have never been able to do:

- **Refuse to expand nonsense.** A macro can prove that the code it is
  about to generate contains a contradiction, and fail with a clear
  message pointing at your source — not at generated code you never
  wrote.
- **Type-directed expansion.** A macro can ask "what type did the
  checker infer for this argument?" and expand differently for a vector
  than for a map — one macro, specialized per call site, verified.
- **Generate-then-verify.** A macro can generate ten candidate
  expansions and keep the one it can *prove* correct.

Compile-time verification stops being a fixed compiler pass and becomes
something any library author can reach for.

## 4. The streaming layer gets *proven* correct

beam-lisp's database supports **live queries**: subscribe to a question
("which orders are unshipped?") and receive updates as data changes,
without re-running the whole query. This is incremental view maintenance,
and it has a hidden correctness condition: the update math is only right
when the query grows monotonically — when new data can add answers but
never silently retract them in ways the incremental path misses.

There is a beautiful result from programming-language research (the
Datafun language) that monotonicity is a *type-level property* — you can
annotate functions as monotone and have a checker prove it. Our type
system adopts exactly this: a live query whose parts are proven monotone
is **certified** for incremental updates; one that isn't gets a clear
compile-time explanation instead of a subtle production bug where a
dashboard quietly shows yesterday's answer.

Nobody walked into this project expecting the type checker to verify the
streaming layer. It falls out of having the database, the live-query
machinery, and the checker in one language.

## 5. The code-fixer proves its own fixes

Deodorant's rewrite rules come in two tiers: **safe** rules (always
value-identical — apply blind) and **idiomatic** rules (value-identical
*under a mild assumption*, like "the argument is a number"). Today, a
human reviews each rule by eye, and the mild assumptions are taken on
trust.

With a theorem prover in the standard library, trust becomes proof:

- Every "safe" rule can be **machine-proven**: encode
  "for all inputs, before ≡ after" and let Z3 either prove it or hand
  back a concrete counterexample input that breaks the rule.
- The mild assumptions can be **synthesized** instead of hand-written:
  ask the solver "under what weakest condition is this rewrite sound?"
  and it *derives* the condition.
- The type checker then **discharges** the condition per call site:
  `(= x 0) → (zero? x)` is provably safe exactly where `x` is known to
  be a number, so idiomatic rules get promoted to safe automatically,
  site by site.

A refactoring tool that proves its own refactors — and explains the
proof obligations it couldn't discharge — is a genuinely new level of
trustworthiness for automated code change.

## 6. The type checker runs backwards, and writes code

There is a research lineage (miniKanren, and the Barliman project) that
writes type checkers not as one-directional programs but as *relations*:
"expression E has type T" is a statement that can be queried with *any*
part left unknown.

- **Forwards**: here is the expression — what is its type? (ordinary
  checking)
- **Sideways**: here is the expression and the error — what type did the
  programmer *intend*? (diagnostics that suggest the fix)
- **Backwards**: here is the type — `int → string` — and here are two
  test cases it must satisfy — *generate candidate expressions.*
  (program synthesis)

The backwards direction is the showstopper: "give me a function with
this signature that passes these tests" becomes a query, answered with
real candidate code, in the REPL, using the same artifact that checks
your types. Because beam-lisp is a Lisp, the relational engine is a few
hundred lines of library code — the syntax the relation reasons about is
the syntax the language is made of.

## 7. Nothing is ever computed twice

Every layer above — inferred types, solver answers, check results — is
a pure function of the source code that produced it. beam-lisp already
has a content-addressed build cache (the same idea as content-addressed
storage in git): artifacts are keyed by a hash of everything that went
into them, so unchanged inputs hit the cache exactly.

We hang the entire analysis stack on that one hook:

- recompiling an unchanged namespace: **zero** re-inference,
- a solver question asked before: **zero** milliseconds, its answer was
  cached under the question's hash,
- a whole-repository re-check after touching one file: only that file's
  dependents re-derive, everything else links from cache.

Type checking has a reputation for making builds slower. Here, the
incremental architecture means the checker gets *cheaper* the more you
use it.

---

## The through-line

Each yield came from the same recipe: a capability the language already
had (homoiconicity, an in-stdlib database, rules-as-data, a content-
addressed cache), combined with the type system, produced something
neither half could do alone. That is the argument for building language
tooling *natively* — not importing a linter, not shelling out to a
foreign analyzer, but growing the analysis out of the same soil as the
language, the database, and the tools.

The sections above are written to be read independently; if you arrived
here from a link, start wherever your question lives.
