# 06 — The deferred agenda: what split-by-default does not do (yet)

Decided with the user on 2026-10-02: the production goal is **split by default**
(PLAN-157). Every live.app becomes a split app. The BEAM stays the only
authority. The browser runs only the screens and intent predictions that
placement proves portable.

**"The browser is another BEAM node" is not given up. It is parked here.** Each
idea below has a durable follow-up in `!tasks/follow-ups/`. Each also names the
evidence this research already produced and the PLAN-157 wave it depends on, so
it can resume from facts, not memory.

## Why it waits

Split-by-default needs a reactive view-and-prediction tier, not a peer node.
Treating the browser as a node adds things production split does not need:
- distributed signal semantics over a lossy link;
- pid identity across trust boundaries;
- runtime parity.

The node agenda becomes cheap after PLAN-157 lands four things:
- the host-op registry (W1.1);
- deterministic compilation (W1.2);
- the emitter living in the toolchain (W2);
- one wire (W4).

## The agenda

| Follow-up | Idea | Evidence already here | Waits on |
|---|---|---|---|
| FUP-133 | Browser as a BEAM node: links, monitors, supervision across the wire | `runtime.bl` signal rules (1195-1260); 11 exit / 4 name / 25 table / 10 supervisor rules diffed against OTP; typed pids `[:pid runtime serial]`; `03-boundaries-ets-ports-distribution.md` | W2, W4 |
| FUP-134 | Self-hosted compiler running in a Worker (REPL, notebooks, live edit) | reader/compiler are BL (`priv/boot`); the emitter already compiles BL→JS | W1.1, W1.2, an eval story |
| FUP-135 | Ship bl-ANF over the wire, hot-load in the browser | ANF is data; versioned `:module` descriptor (`priv/boot/anf.bl:252`) | W2, W4 |
| FUP-136 | Full JS actor runtime parity: ports, ETS, nested supervisors, dynamic children | README "Supported surface and limits"; `verify-tables.mjs:360-393` deviation list | FUP-133 |
| ~~FUP-137~~ | Exact numerics on JS: **pulled into PLAN-157 W2 as FEAT-056** (user decision D3, 2026-10-02). Lean exact: Number for safe ints, BigInt beyond, boxed floats, BigInt-backed decimals. | `04-exact-numeric-spike.md` (34 cases, timings) | — |
| FUP-143 | Refined client replica: per-screen read-sets, partial replicas, lazy fetch (v1 = whole guarded worlds, decision D2) | `:listen :attrs` commit filter in `priv/lib/live/socket.bl` | W3, W1.4 |
| FUP-138 | datom in the browser: recursive rules, IndexedDB, offline queue survives close | BL nested-loop engine is portable; rules fixpoint is a Rust NIF | W3 |
| FUP-139 | One placement lattice: browser / BEAM / native NIF / edge | `system.prove/native-eligible?` and split portability are the same question | W1.4 |
| FUP-140 | JS artifacts in the self-build fixpoint gate | bundles already deterministic (PLAN-147/149) | W1.2, W2 |
| FUP-141 | Core semantics spec + G-diff harness for every backend | the differentials and parity findings below | — |
| FUP-142 | JS emitter bug: a multi-arity fn calling its own other arity | `runtime.bl:453` workaround; works on BEAM (checked 2026-10-02) | W2 |

## What this research taught the core compiler

These findings are bigger than JS. PLAN-157 W0/W1 and FUP-141 act on them.

1. **bl-ANF is structurally neutral, not host-neutral.**
   - `:global` relies on the `Env.fetch!` fallback from namespace to core.
   - `:remote` names BEAM modules (`Elixir.BeamLisp.Ns.Rt`).
   - `defn` is a `Link:defvar` remote call.

   The emitter needed hand-maintained tables (`remote-map`, `core-map`) to cope.
   The fix is one declared host-op registry.
2. **Compilation was not a pure function of source.** Fresh names come from a
   process-global counter, so emitter bytes depended on build order. This was
   fixed per unit in the emitter, but not in the core compiler.
3. **Loops and named fns are scaffolds.** Every consumer pattern-matches the
   self-application `(let [fnself (fn [fnself] …)] …)` and the `$blfn` tuple.
   They should be facts on ANF.
4. **Effects of function values and of lazy forcing were unmodelled.**
   - `:latent` landed on this branch.
   - Main independently made lazy forcing an effect by narrowing purity to
     exact ops.
   - The two collided at the 2026-10-02 merge. The right model is: forcing
     charges the producer's latent effect.
5. **Numeric domain is IR information.** The `:lit` int/float tag and
   `:arith`'s arbitrary-precision contract are implicit until a backend
   destroys them.
6. **Unwritten semantics surfaced by differential testing.**
   - Equality is looser than hash-key equality.
   - Small-map key order depends on the atom table.
   - String count is graphemes.
   - Sort comparator call order is observable.
   - The exception shape is normalized.
7. **Runtime policy in BL is portable.** Receive, atomic death, the two exit
   deliveries, names and the call protocol were re-derived in BL with stated
   invariants. The same spec can back `proc.*` on BEAM.
8. **Vectors are maps on BEAM.** A `get`-based walker silently skips vector
   contents (security fix 61760c8f). Walk ANF only via `ir/child-nodes`.

Two README claims were re-checked on the merged tree (2026-10-02):
- The multi-arity self-call works on BEAM: `(f 1)` → `11`. It is a JS-only bug
  (FUP-142).
- "Empty lazy seq is `=` nil yet truthy" no longer reproduces:
  `(= (keep identity []) nil)` → `false`.
