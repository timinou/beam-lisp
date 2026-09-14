# The oracle lane — a map

Thirteen runnable programs that show how beam-lisp asks z3 a question and what it
does with the answer. Read them in order; each one is a single idea.

## What the lane is

z3 is a separate OS process, and this runtime reaches it through an Erlang
`port` — it writes SMT-LIB down a pipe and reads the answer back (`sat`,
`unsat`, or `unknown`, plus a model, a core, or a reason when asked).
A small **pool** of those processes lives behind `defserver`s — one conversation
at a time each, handed out under a lease, restarted by OTP when one dies — and
that is `priv/std/z3pool.bl`.
The language's API is **`oracle`**: a question is a *value* (`obligation`),
asking it (`ask`, or `scoped` inside a `session`) yields one *verdict value*
(`:status` / `:model` / `:why` / `:tier` / `:us`), and `priv/lib/z3.bl` is the
older, port-level surface that sits beneath it.

## The layers

| Layer | What it is | Owner |
| --- | --- | --- |
| L0 | The port driver: opens the pinned `priv/z3/bin/z3` (never the system PATH), writes SMT-LIB, reads one word back. | `lib/beam_lisp/z3_port.ex` |
| L1 | The bundle: `z3-solver` defservers under a supervisor, a lease registry with a written invariant, a VM-lifetime keeper. | `priv/std/z3pool.bl` |
| L2 | The verdict as a value: one record `{:status :model :core :why :tier :us}`, with `proven?` / `refuted?` / `undecided?`. | `priv/lib/oracle.bl` |
| L3 | Theory as data: SMT forms and the one printer (`emit` / `script` / `raw`); source→SMT translation and the sort functor (`sort-of-value`). | `priv/lib/smt.bl`, `priv/lib/system/smt.bl` |
| L4 | Conversation by default: a `with-solver` lease, then `session` (declare the prelude once) + `scoped` (push / assert / check / pop per question). | `priv/std/z3pool.bl`, `priv/lib/oracle.bl` |
| L5 | Obligations + memo: `obligation` renders and classifies once, its text is the identity (a `phash2` key) into the `:oracle-memo` ETS table. | `priv/lib/oracle.bl` |
| L6 | The oracle as an effect: `ask` performs it, `with-oracle` handles it (`pool-handler`, `table`, `deny`). | `priv/lib/oracle.bl` |
| L7 | Fan-out: `ask-all` runs N obligations over the pool's N solvers, the lease registry is the backpressure. | `priv/lib/oracle.bl`, `priv/std/z3pool.bl` |

Under all of it: `lib/beam_lisp/z3_ledger.ex` — the `:counters` rollup and the
process-dictionary trail that record *who answered, in which fragment, at what
cost* — with the language's view of it in `priv/lib/system/decide.bl`.

## The examples

| Example | The question it answers | The one thing to watch | Measured headline (this machine, `BL_DAEMON=off`) |
| --- | --- | --- | --- |
| `01-why-unknown.bl` | why "no answer" is not one thing | the two silences: a ceiling (`:timeout` / `:canceled`) says raise it; `:incomplete` says no ceiling will help | `factoring     → :unknown \| why: :canceled \| us: 302449` |
| `02-blame.bl` | a refused step is a *witness*, not a wall | the polarity: `unsat` = preserved, `sat` = the model IS the counterexample | `step :withdraw → counterexample: amt = 1, balance = 0, balance2 = -1` |
| `03-memo.bl` | does asking the same question twice cost anything | the second ask never reaches the solver — one ETS read — and `unknown` is not cached | `second → :unsat \| tier: :memo \| us: 0 \| solver calls: 0 \| memo entries: 1` |
| `04-ceiling.bl` | where the 10 s z3 ceiling came from | every decision is timed; the ratio is a single-run snapshot, so watch it move | `median ordinary: 4701 us    the ceiling is 64 × that` (a second run: `5596 us` / `54 ×`) |
| `05-sorts.bl` | a field's type decides which arithmetic z3 does | one word (`Real`→`Int`) flips `unsat`→`sat`; the `0.75` control now names the check that refused AND carries the state | `── the same invariant with 0.75 \| holds: false \| warned: 1 \| failures: 1` / `init → counterexample: x = 0.75` |
| `08-k-induction.bl` | one step is not always enough to prove a machine safe | the same machine refused at `:k 1` with the state pair `5 → 6`, PROVEN at `:k 2` — and the `:base` check that a deeper question needs | `island :k 1 → holds: false \| leap → x = 5, x2 = 6` / `:k 2 → holds: true` |
| `11-annotated.bl` | who says what SORT a field has | one declaration (`^{:sorts {:rate Real}}`) turns a vacuous `holds` into a real refusal, and `:defs` lowers an invariant's helper to a `define-fun`; `{:emit true}` prints the declarations the verdict was decided over | `half → holds: true (rate:Int)` / `+ :sorts → holds: false \| scale → rate = 0.5, rate2 = 1.0` |
| `07-sessions.bl` | why a conversation beats a question | `discover-invariant` twice, sessions off/on: the same invariant, the same 10 questions, a fraction of the µs; `(z3pool/current)` is a pid inside a session, nil outside | `ledger ~65–77k µs → ~2.4–2.7k µs per discovery (≈6.5–7.7k → ≈0.24–0.27k µs/question across two runs); discovered identical: true` |
| `09-blame.bl` | when repair cannot help, it says why | a refusal is `sat` → its hint is a MODEL; a blame is `unsat` → its hint is a CORE. Three unrepairable machines print their failure maps side by side | `drain → :next-step-breaks-it (core [g_next g_inv2]) · blocked → :guard-too-weak · impossible → :invariant-impossible (core [g_inv2])` |
| `06-no-strings.bl` | how a predicate reaches the solver | a legacy TEXT predicate used to be pasted into the script and arrived at z3 as an INERT string literal; read once at the boundary, a form, a string and a bl source body emit BYTE-IDENTICAL scripts — and malformed text throws naming the text | `the three scripts are the same text: true` / `verdicts: [:unsat :unsat :unsat]` / `predicates: 10 \| read then emitted back identically: 10 \| mismatches: 0` |
| `10-corpus.bl` | does the whole tree still check out | every `defserver` in `priv` + `examples`, verified machine by machine; the coverage line is an ASSERTION against an independent grep bound, so a cheerful zero fails | `machines 80 ≥ grep bound 62 → PASS` / `proved 27 \| refuted 19 \| undecided 0 \| declined 34` / the outcome column is byte-identical across runs |
| `12-stats.bl` | what the oracle cost, in one view | the same state read two ways — through `bl oracle stats` and directly (a `:counters` histogram, `(decide/cost)`, `(ets/info :oracle-memo :size)`) — so the CLI is visibly a view over VM state, not a source of truth | `files 401 · machines 80` / `decisions 88 \| total 155559 us \| median 8242 us \| worst 60926 us` (`examples/bundles/00-all-five.bl · worker`) |
| `13-faults.bl` | a fault has to cross a process boundary as text | the inert-literal trap caught in the act: emitted raw, `(>= v -40)` reaches z3 as the string `"(>= v -40)"`; read once it emits as `(>= v (- 40))`. Both lanes end on the same verdict | `STRING clauses == FORM clauses byte-identical: true` / `{:clause 0 :status :sat :modality :proven :implied false :value {:v -41}}` |

## Running them

```sh
# one example
BL_DAEMON=off timeout 240 mix bl run examples/oracle/01-why-unknown.bl
BL_DAEMON=off timeout 240 mix bl run examples/oracle/02-blame.bl
BL_DAEMON=off timeout 240 mix bl run examples/oracle/03-memo.bl
BL_DAEMON=off timeout 240 mix bl run examples/oracle/04-ceiling.bl
BL_DAEMON=off timeout 240 mix bl run examples/oracle/05-sorts.bl
BL_DAEMON=off timeout 240 mix bl run --path priv --path examples examples/oracle/07-sessions.bl
BL_DAEMON=off timeout 240 mix bl run --path priv --path examples examples/oracle/09-blame.bl
BL_DAEMON=off timeout 240 mix bl run --path priv --path examples examples/oracle/08-k-induction.bl
BL_DAEMON=off timeout 240 mix bl run --path priv --path examples examples/oracle/11-annotated.bl
BL_DAEMON=off timeout 240 mix bl run examples/oracle/06-no-strings.bl
BL_DAEMON=off timeout 600 mix bl run --path priv --path examples examples/oracle/10-corpus.bl
BL_DAEMON=off timeout 600 mix bl run --path priv --path examples examples/oracle/12-stats.bl
BL_DAEMON=off timeout 240 mix bl run --path priv --path examples examples/oracle/13-faults.bl

# the same rollup through the CLI (needs a repacked drop: priv/std is AOT'd into it)
./bl oracle stats            # five sections: corpus, cost, tiers, undecided, failures
./bl oracle stats --dry-run  # ledger-only; skips the ~9 s walk and says which mode ran

# every one of them, isolated and timed by ward
BL_DAEMON=off timeout 600 mix bl examples examples/oracle/*.bl

# the lane's tests
BL_DAEMON=off timeout 1500 mix bl test test/bl/system/oracle_test.bl
#   ✓ system.oracle-test  80 passed
#   1 file(s) passed, 0 failed, 0 incoherent

# per-layer measurement over 100 obligations
BL_DAEMON=off timeout 300 mix bl run --path priv --path examples bench/oracle_bench.bl
```

- `BL_DAEMON=off` runs in one cold VM — no daemon, no warm pool — so a run is
  reproducible and its timings are comparable.
- `--path priv --path examples` is only needed for programs that resolve
  `require`d namespaces from those roots (`bench/oracle_bench.bl` is one).
- **`mix bl test` exits 0 even when a file failed.** Read the summary line
  (`1 file(s) passed, 0 failed, 0 incoherent`) and the `✓` / `✗ file-name` lines;
  never the exit code.
- One `bench/oracle_bench.bl` run here: `today z3/check … 11467 us/q`,
  `oracle/ask cold … 10347 us/q`, `memo hit … 17 us/q` (`solver calls on the warm
  pass: 0`), `oracle/session + scoped … 809 us/q`, `ask-all … 7143 us/q`
  (`pool high-water during fan-out: 4`), `with-oracle table … 11 us/q`.

## Honest limits

- **The corpus rollup measures the tree, not the tool.** `bl oracle stats` walks
  `priv` + `examples` (a serial walk, ~9 s) and reports what it found: 80
  machines today. It reads the same ledger `decide/cost` reads, so its `:why`
  column is z3's own reason and nothing else. What it does NOT do: attribute
  cost to a specific `bl check` run (the ledger is per-VM and starts empty), or
  verify a machine that the engine will not model (`declined`: a live/reactive
  server — 34 of the 80).
- **`oracle/explain` has one engine caller now, and only one.**
  `repair-process`' blame branch (`09-blame.bl`). `step-obligation` names its
  three parts (`g_guard`, `g_next`, `g_inv2`) for it and every lease arms
  `:produce-unsat-cores`; the synthesis side still has no caller.
- **The native witness rung is opt-in.** `system.decide/decide` runs z3 only;
  `decide/decide-native` (the bounded BEAM guard search) is called from tests,
  not by the verifier.
- **`unknown` is not memoised.** Caching "the solver gave up" would turn a
  transient ceiling into a permanent one — `03-memo.bl` measures
  `hard → :unknown | memo entries now: 0`.
- **Session questions are never memoised.** Inside a `session`, the same
  `scoped` commands mean whatever the conversation has already asserted, so the
  script text is not an identity there; `oracle/scoped` has no memo lookup.
- **L6 and L7 are exercised by the bench and the oracle tests**, not by the
  verifier: `with-oracle`/`table`/`deny` and `ask-all` have no engine caller.
  The bench measures them (memo hit 17 µs/q, `ask-all` 4 solvers in flight),
  which is what they are for.
- **The measured numbers move.** Every microsecond figure in this file is one
  run on a shared machine; the ratios move 2-3x with load. What does not move:
  the ORDER (memo < session < one-shot), the outcome columns, and the verdicts.
- **FUP-059 is closed; the lanes below are not.** `^{:sorts {:rate Real}}`
  declares a field's sort where the init literal cannot (an unknown sort
  NAME, or one that contradicts the literal, throws rather than degrading to
  `Int`), and `:k` raises the induction depth past 1. Still undeclared: an
  INPUT's sort (inferred by flow, defaulting to `Int`), a collection field's
  ELEMENT sort (lengths only — see `verify-capacity`), a record/array
  field's component sorts, and a helper called from a GUARD or a
  next-state expression (`:defs` covers the invariant; an unmodelled
  guard drops its transition and reports `:complete false`).

## Glossary

- **obligation** — a question as a value: a label plus the commands.
  `oracle/obligation` renders it once, and that text is its identity (the memo
  key).
- **verdict** — the one record every answer arrives in: `:status`
  (`:sat` / `:unsat` / `:unknown` / `:error`), `:model`, `:core`, `:why`,
  `:tier`, `:us`.
- **tier** — who answered: `:native-witness` (the BEAM search, opt-in), `:oracle`,
  or `:memo`.
- **fragment** — what the question is made of: `:tag-lattice` (the value
  model), `:arith` (linear integer arithmetic), `:general` (anything else,
  including raw SMT text); recorded per decision, and the input to "is another
  native rung worth building?".
- **lease** — one z3 process handed to one caller for one conversation, returned
  in a `finally` or by monitor if the borrower dies; the registry's invariant is
  at most one lease per solver.
- **witness** — a refutation's counterexample: the model filtered to the
  machine's own variable names, readable as a failing test.
  `oracle/witness`.
- **blame** — an unsat core read as a diagnosis (`:guard-too-weak`,
  `:next-step-breaks-it`, `:invariant-impossible`). `oracle/explain`.
