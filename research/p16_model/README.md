# P16a — the transition-relation extractor: findings

**Claim (load-bearing for PLAN-048):** verification is a property of the
*evaluator*, not of any macro. So a process extractor reads down to the
primitives and lowers every surface form to ONE normalized transition set;
verification is written once over that set and inherited by all forms.

**Verdict: PASS.** `mix`-free run:

```sh
elixir -pa _build/dev/lib/*/ebin -e '
  BeamLisp.init()
  BeamLisp.Env.push_load_path("priv")
  BeamLisp.Env.push_load_path("research/p16_model")
  BeamLisp.run_file("research/p16_model/run.bl")'
```

## What it demonstrates

The **same counter machine** (`inc → n+1`, `dec when n>0 → n-1`, `reset → 0`)
written three ways lowers to the identical transition graph:

```
raw receive-loop  ([:dec "(- n 1)"] [:inc "(+ n 1)"] [:reset "0"])
defserver (OTP)   ([:dec "(- n 1)"] [:inc "(+ n 1)"] [:reset "0"])   ← inherits, unchanged
defmulti dispatch ([:dec "(- n 1)"] [:inc "(+ n 1)"] [:reset "0"])
all three identical: true
```

The `defserver ≡ loop` case is the one that matters: an OTP server, written with
no verification in mind, produces the *same* machine as a raw `receive` loop —
so it inherits the whole guarantee battery with **zero edits**. This is the
"defserver gets far more, unchanged" pressure test from PLAN-048, now measured.

Then, over the extracted graph (finite instance n ∈ 0..3):

- **claim 2** — with the extracted guard `(> n 0)` on `:dec`, the bad state
  `n<0` is **unreachable** (BFS returns no path). The guard IS the invariant.
- **claim 3** — drop the guard and the *same* backward search returns the
  **counterexample path** `[1 0 -1]` — "1 →dec 0 →dec -1". Counterexample =
  a backward reachability query, no new engine.

## Findings (these shape the MVP)

1. **The extractor reuses typed's plumbing verbatim.** `parse-clause`
   (typed.bl:515), `defn-clauses` (typed.bl:527), and the node accessors do all
   the shape work. The extractor is ~200 lines of *dispatch*, not parsing. The
   clause/guard/dispatch machinery the type checker already built IS the model
   extractor.

2. **Reader shapes (confirmed empirically, /tmp/probe.exs):**
   - `(receive P1 B1 P2 :when G2 B2 …)` → items `[sym"receive", vecP, bodyL,
     vecP, kw":when", guardL, bodyL, …]` — a flat alternating stream.
   - `(defserver name (init …) (handle-call PAT [args state] body) …)` → each
     clause a list headed by `init`/`handle-call`/`handle-cast`/`handle-info`.
   - reader nodes: `{:meta, {:list, items}, pos}`; literals inside are bare.

3. **Next-state must be NORMALIZED to compare dispatch forms.** A loop's
   `(recur S)`, a server's `(reply val S)`, and a defmethod's bare returned `S`
   all name the same next-state — the extractor strips the wrapper so they
   coincide. Without this, value-dispatch (defmulti) and message-dispatch
   (receive) never match. (`next-state` in extract.bl.)

4. **The guard is a per-form property, faithfully reported — not fabricated.**
   A bare `defmulti` with three unguarded methods has NO guard on `:dec`; the
   loop/server write `:dec :when (> n 0)`. The extractor reports exactly what
   the source encodes. A defmulti that encodes the same machine puts the guard
   in the body (`(if (> n 0) (- n 1) n)`) — extract it and the guard reappears.
   This is the sound-warnings discipline at the model layer: report what's
   there, invent nothing.

5. **The comparison metric is the (label, next-state) GRAPH**, not raw clause
   equality — patterns differ by surface syntax (a defn param vector vs a
   receive message vector) but the abstract transition (what it's called, where
   it goes) is invariant. Guards are compared where both forms carry them.

## What graduates / next

- `extract/transitions` and `extract/extract-defmethods` are the seed of
  `priv/model.bl`'s extraction layer.
- `next-state` normalization is a keeper.
- The concrete BFS stepper in run.bl is a STAND-IN for the `:~step` defrelation
  — P16b registers the real computed relation (provider expands states through
  these clauses, z3 at the guard leaf) so reachability runs on the shipped
  `datom.query.fixpoint` engine instead of a bespoke BFS.
- Content-hash namer (for anonymous spawns) not yet built — P16b, when a spawn
  without a binding name needs an identity.

## Files
- `extract.bl` — the extractor (5 surface forms → normalized clauses).
- `run.bl` — the three-claim driver (PASS).

---

# P16c — inductive invariant: □Inv, unbounded (PASS)

The leap from P16a's finite BFS to PROOF. z3 discharges the Hoare triple
`Inv(s) ∧ guard ∧ s'=next(s) ⊢ Inv(s')` for EVERY state and EVERY input —
unbounded. Bank account, invariant `balance ≥ 0`:

- **□(balance ≥ 0) proven** — init establishes it; deposit and (guarded)
  withdraw each preserve it for every amount. No bound on state or input.
- **Bug B1** (unguarded withdraw) → z3 returns the concrete witness
  `balance=0, amt=1 → balance2=-1`. Not "unsound" — the exact overdrawing state.
- **Bug B2** (withdraw allows amt<0) → honestly reported as NOT breaking
  `balance≥0` (a negative withdraw raises the balance). The amt≥0 bug needs a
  different invariant — P16d's abduction target. The checker invents no failure.

Encoding: assert the triple's NEGATION, check-sat. unsat ⟹ preserved. beam-lisp
prefix source is already valid SMT-LIB integer arithmetic, so extracted
transition → proof obligation is near-identity. Direct extension of MVP-C
(z3.bl): rewrite-equivalence there, state-invariant preservation here, same port.

Files: `inductive.bl` (preserves?/establishes?/prove-box), `run_inductive.bl`.
