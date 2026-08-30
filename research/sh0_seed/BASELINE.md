# CHECKPOINT 0 — the baseline the self-hosting work measures against

Captured 2026-08-29 at branch point `63305db` (worktree
`feat/self-hosted-compiler`), before any frontend porting.

## Why this exists

Every later prototype proves itself by producing **identical output** to the
current Elixir-written compiler — the "differential oracle." For that
comparison to mean anything, we first have to know what the current state
actually is: which tests pass, which already fail, and how the suite behaves.
A gate that says "still green" is only trustworthy against a known green.

## How the suite behaves

**Per-file runs are clean; the full parallel run is not.** Each test file, run
alone in its own VM, passes — with two pre-existing exceptions noted below.
The full `mix test` (all 68 files together) is flaky: a burst of failures with
`(exit) no process` from `GenServer.call(BeamLisp.Env, …)`. The shared `Env`
process dies mid-run and is not revived, so every subsequent test that calls
`BeamLisp.init/0` fails. This reproduces on `main` too (its full run crashes,
exit 2) and matches the earlier PLAN-022 observation ("one mix test run in 38
failed"). It is tracked in **FUP-014**, is **pre-existing**, and does **not**
block the self-hosting work because the differential-oracle gates run per file
(each in its own VM), which never hits the shared-Env flake.

## The measurement decision

**The differential oracle runs per file, in its own VM.** This is immune to
the full-suite Env flake and is the correct granularity anyway: a ported
special form is checked against the exact test file that covers it.

## Known pre-existing failures (present at branch point AND on main)

1. `is_map_lint_test.exs` — a bare `is_map(` at `compiler.ex:1711` lacked the
   `# is_map-ok:` sanction. **FIXED** in this branch (commit "sanction the
   is_map(") — now 18/18.
2. `dispatch_table_test.exs` — 6/7. One of 324 cells expects a
   `FunctionClauseError` that is no longer raised (some value × collection-fn
   pair changed behavior). Pre-existing on main. Tracked separately; not
   introduced by the self-hosting work. Needs a careful per-cell diagnosis
   before a fix, so it is left recorded rather than guessed at.

## Core per-file results (own VM each), after the is_map fix

| file | result |
|---|---|
| `reader_test.exs` | pass |
| `compiler_test.exs` | pass |
| `wave22_server_test.exs` | 7/7 |
| `is_map_lint_test.exs` | 18/18 (fixed) |
| `dispatch_table_test.exs` | 6/7 (pre-existing cell) |
| `sandbox_test.exs` | pass |

## Benchmarks (to be captured before P6/P10/P11 perf gates)

The perf-gated prototypes compare against these; capture on a quiet machine
per the AGENTS.md protocol (≥3 samples, report spread):

- hot loop: `(loop [i 0] (if (< i 1000000) (recur (+ i 1)) i))` — README cites
  ~25ms linked (P6 gate).
- 100k-conj vector build — README cites 12ms (P11 gate).
- collections/dispatch throughput (P10 gate).

`examples/bench.bl` runs the first two; capture at CHECKPOINT 1 when the
frontend is in place, so the numbers reflect the same tree the gates run on.

### Captured at branch point (3 samples, this host)

| bench | s1 | s2 | s3 | budget for P6/P10/P11 |
|---|---|---|---|---|
| 1M-iteration loop | 12ms | 11ms | 11ms | stay within noise of ~11ms |
| 10M fn-recur countdown | 252ms | 239ms | 236ms | stay within noise of ~240ms |

These are the linked (post-var-linking) numbers. A ported `def`/linking path
(P6) or `.bl` runtime prims (P10) that pushes the 1M loop materially past
~12ms is a regression that must be named with cause.

## The honest summary

- The language **works**: per-file tests pass.
- The full-suite harness has a **pre-existing** Env-lifecycle flake (FUP-014),
  not caused by and not blocking the self-hosting effort.
- Two real pre-existing bugs were surfaced by establishing this baseline; one
  is fixed, one is recorded for careful handling.
