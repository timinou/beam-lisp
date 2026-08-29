# The greatest fixpoint: one engine, many proofs

*A zero-context explanation of the gfp spike — a tiny piece of machinery that
turns out to power invariant discovery, model checking, and state minimization,
all from the same eight lines.*

---

## What a "fixpoint" is, with no jargon

A **fixpoint** is what you get when you apply a rule over and over until nothing
changes anymore.

Picture a rumour spreading. Rule: *"if a friend of yours knows it, now you know
it too."* Start with one person. Apply the rule: their friends know it. Apply
again: friends-of-friends. Eventually a round goes by and **no new person** hears
it — the rumour has saturated. That final set of people is the fixpoint.

There are two directions you can run this:

- **Grow from nothing** (a *least* fixpoint): start with the empty set, keep
  **adding** what the rule forces, stop when nothing new gets added. "Who can
  reach the exit?" starts at {exit} and grows outward.
- **Shrink from everything** (a *greatest* fixpoint): start by assuming
  **everyone/everything qualifies**, keep **removing** whatever fails, stop when
  nothing else gets removed. "Which of my beliefs survive scrutiny?" starts at
  "all of them" and shrinks.

Same idea — repeat until stable — opposite starting points.

## What our database already had

The project has a small **datalog** database (called `datom`). Datalog's whole
trick is recursive rules — and it computes them as a **grow-from-nothing**
fixpoint. "Which pages link, directly or indirectly, to this one?" starts empty
and grows. This is genuinely powerful: shortest paths, connected components,
transitive closure — a whole family of graph questions — are all this one shape.

But it only grows. There was **no shrink-from-everything** mode.

## The problems that need the other direction

It turns out a big family of *verification* questions are the shrink shape:

- **Discovering an invariant.** Start by guessing *every* promise might be true
  ("balance ≥ 0", "balance ≥ reserved", "balance ≤ 5"…), then **remove** each one
  that some transition breaks. What survives is a proven invariant — discovered
  from nothing.
- **Model checking "nothing bad ever happens."** Start assuming *every* state is
  safe, then **remove** any state that is bad or can step to a removed one. What
  survives is the provably-safe region.
- **Minimizing a state machine.** Start assuming *every* pair of states is
  interchangeable, then **remove** any pair you can tell apart. What survives
  tells you which states are truly redundant, so you can merge them.

All three are the same move: **seed full, remove the condemned, repeat until
stable.** A greatest fixpoint. And `datom` couldn't do it.

## The whole engine is eight lines

Here is the shrink-from-everything driver. It is the exact mirror of the
grow-from-nothing one:

```clojure
(defn gfp [seed survives?]              ; seed = everything; survives? = the keep-rule
  (loop [s seed]
    (let [s2 (keep-only survives? s)]   ; drop everything that fails right now
      (if (= s2 s) s2                    ; nothing dropped → stable → done
          (recur s2)))))                 ; else shrink again
```

That's the entire idea. You hand it a starting set and a rule for "does this
still survive, given the current survivors?" It shrinks to the largest stable
set. Because the set can only get smaller and is finite, it always terminates.

## We tested it on all three problems at once

The `survives?` rule is where each capability plugs in — and crucially, *the
decision can come from whichever tool is best at it.* We ran one spike
(`research/p19_datalog_feed/spike_gfp.bl`) with three different `survives?`
rules:

**1. Invariant discovery** — `survives?` asks **z3**: "assuming all the
currently-surviving promises hold, does this one still hold after every step?"
On a two-variable machine it discovered:

```
strong result : x≥0, x≥y, y≤x, y≥0, …      (8 promises)
weak result   : y≥0, y≤0, …                (only 4)
the difference: x≥0, y≤x, x≥y, 0≤x
```

Those extra four survive **only because a sibling promise is co-assumed** —
`x≥0` isn't provable alone, but it's provable *together with* `y≥0`. That
mutual support is the entire reason the strong loop beats checking each promise
in isolation, and it fell straight out of the gfp driver.

**2. Safe-region model checking** — `survives?` is a plain relational check
(no z3): "not bad, and all my successors are still safe." It computed the safe
region correctly. Then we **edited** the machine (marked a new state bad) and
re-checked starting from the *previous* answer — **7 checks instead of 10**. An
incremental re-verification, for free, because the engine shrinks rather than
restarts.

**3. State minimization** — `survives?` asks "do these two states behave the
same and lead to same-behaving states?" It merged three equivalent states into
one class, shrinking a 4-state machine to 2.

**One driver. Three proofs. The per-step decision routed to z3, or to a plain
relation, or to a structural check — whichever owns that question.**

## Why this is a big deal (the part you can't fully predict)

The eight lines aren't the point. The point is that once "shrink to a stable
set" is a *reusable engine primitive*, capabilities you didn't specifically
build for start falling out:

- **More proof techniques become one-liners.** k-induction, predicate
  abstraction, dataflow analysis — all "shrink to stable." Build the primitive
  once; these become inputs, not new code.
- **Verification becomes incremental.** `datom` already tracks history and can
  watch for changes. A fixpoint *in the engine* means re-checking an invariant
  after an edit only recomputes the affected part — a subscription, not a
  from-scratch rerun. (With one honest caveat below.)
- **Proofs explain themselves.** `datom` records *why* each fact exists. A
  discovered invariant would carry its own derivation: which transition forced
  which promise to drop, in which round. The hand-written loop throws that away;
  the engine keeps it.
- **One optimizer speeds up everything.** All the work that makes the
  grow-fixpoint fast (delta tracking, a native fast path) would apply to the
  shrink-fixpoint too, automatically.

The deepest win is the one you can't list in advance: when a capability becomes
a **first-class relation**, it composes with every other relation. A discovered
invariant could be *joined* against the call graph, the effect footprints, the
migration history — answering questions nobody has phrased yet, because the
pieces used to live in separate tools.

## The honest caveats

- **This is a spike, not a shipped engine.** It proves the *shape* works — that
  one driver hosts all three proofs. Turning it into a real `datom` rule mode
  (with production-grade termination and soundness proofs) is a genuine follow-on
  project, not done yet.
- **Incremental re-checking has a precise safety line.** Warm-starting from the
  previous answer is sound **only when the edit makes the safe set *smaller***
  (a stricter promise, more bad states). An edit that could make it *bigger*
  must restart from full. Cross that line and the shortcut silently lies — so it
  is a first-class rule, not a footnote.
- **The hardest case still needs care.** Invariant discovery's keep-rule folds
  *all* current survivors into one z3 question per round. That "aggregate the
  whole relation mid-recursion" is the one part a standard datalog engine can't
  express directly; it has a known home in the research literature (datalog over
  lattices; the alternating-fixpoint algorithm) and is the real frontier of
  making this fully native.

## The one-sentence version

Our database could only grow a set to a stable point; a whole family of proofs
needs to *shrink* one to a stable point; that shrink is eight lines, and once
it's an engine primitive, invariant discovery, model checking, and state
minimization stop being separate hand-written loops and become the same reusable
machine — fed by whichever solver is best per step.

---

*Spike: `research/p19_datalog_feed/spike_gfp.bl` (the driver + all three demos).
The grow-fixpoint it mirrors: `priv/datom/query/rules.bl` (`derive-semi-naive`).
The per-step z3 decisions it reuses: `priv/system/core.bl`
(`preserves?`, `simulates?`).*
