# The z3 lane — a map

Five runnable programs that show how beam-lisp asks z3 a question and what it
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
| `05-sorts.bl` | a field's type decides which arithmetic z3 does | one word (`Real`→`Int`) flips `unsat`→`sat`; `holds: false` with `failures: 0` is an *establishment* failure | `── the same invariant with 0.75 \| holds: false \| warned: 0 \| failures: 0` |

## Running them

```sh
# one example
BL_DAEMON=off timeout 240 mix bl run examples/z3/01-why-unknown.bl
BL_DAEMON=off timeout 240 mix bl run examples/z3/02-blame.bl
BL_DAEMON=off timeout 240 mix bl run examples/z3/03-memo.bl
BL_DAEMON=off timeout 240 mix bl run examples/z3/04-ceiling.bl
BL_DAEMON=off timeout 240 mix bl run examples/z3/05-sorts.bl

# all five, isolated and timed by ward
BL_DAEMON=off timeout 600 mix bl examples examples/z3/*.bl
#   ✓ 01 … 05
#   5 passed, 0 skipped, 0 failed

# the lane's tests
BL_DAEMON=off timeout 1500 mix bl test test/bl/system/oracle_test.bl
#   ✓ system.oracle-test  37 passed
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

- **No corpus rollup yet.** `decide/cost` answers `{:count :total_us :max_us}`
  for the obligations *this process* asked since `clear-here!`. Nothing rolls it
  up over a whole `bl check` of the tree, so the 10 s default ceiling is still a
  default, not a measured decision.
- **`oracle/explain` has no engine caller yet.** `step-obligation` names its
  three parts (`g_guard`, `g_next`, `g_inv2`) and every lease arms
  `:produce-unsat-cores`, but the only references to `explain` in the engine are
  comments — the blame lane is built and unused.
- **The native witness rung is opt-in.** `system.decide/decide` runs z3 only;
  `decide/decide-native` (the bounded BEAM guard search) is called from tests,
  not by the verifier.
- **`unknown` is not memoised.** Caching "the solver gave up" would turn a
  transient ceiling into a permanent one — `03-memo.bl` measures
  `hard → :unknown | memo entries now: 0`.
- **Session questions are never memoised.** Inside a `session`, the same
  `scoped` commands mean whatever the conversation has already asserted, so the
  script text is not an identity there; `oracle/scoped` has no memo lookup.
- **L6 and L7 exist but have no consumer** outside `bench/oracle_bench.bl` and
  `test/bl/system/oracle_test.bl`.
- **05's open half (FUP-059).** The sort comes from the init *literal*; a field
  whose true sort appears only in an annotation, or that has no readable
  literal, still falls back to `Int`.

## Glossary

- **obligation** — a question as a value: a label plus the commands.
  `oracle/obligation` renders it once, and that text is its identity (the memo
  key).
- **verdict** — the one record every answer arrives in: `:status`
  (`:sat` / `:unsat` / `:unknown` / `:error`), `:model`, `:core`, `:why`,
  `:tier`, `:us`.
- **tier** — who answered: `:native-witness` (the BEAM search, opt-in), `:z3`,
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
