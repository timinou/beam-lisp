# Extending the JIT-lowerable fragment to pixel-class loops

**Ask:** extend the code patterns we can lower to native beyond scalar folds —
to the pixel-class loops (loom-shell's renderer hot path) — using the
`codebase` / `system` / `veritas` engines rather than hand-rolled checks.

**Result:** done, measured, value-verified. The pixel blend now lowers
bl → IR → cranelift → native store loop, **byte-identical** to the BEAM run,
at **~145×**. Two engines were extended (additively, soundly); the lowerer was
rewritten to read the same clean tree the proofs read and to delegate every
eligibility decision to the shipped engines.

---

## 1. The core realisation: the engines were INCOMPLETE, not absent

The spike (`run.bl`) hand-rolled its eligibility (`sl-refuse :impure`,
`:not-shrinking`) against the *compiler-quoted* tree. That was a **parallel
implementation** of two engines the repo already ships — `system.footprint`
(the effect algebra) and `termination` (the measure checker). Probing them
directly showed *why* the spike bypassed them: both correctly **refused** the
counted-loop idiom, but for reasons of incompleteness, not unsoundness.

| engine | verdict on checksum/blend (before) | root cause |
|---|---|---|
| `system.footprint` | `{:opaque-world :W}` → impure | `binary/at` was an **unknown callee** → conservative "touches everything" default |
| `termination` | `:rejected` | demanded **∀ vars shrink**, and knew only count-**down** measures |

Both fixes are additive completeness that **every** consumer inherits (the
capability sandbox, the effects ladder, the SMT checker).

### 1a. `footprint`: `binary/at` reads an immutable binary → pure

A bl binary is immutable; indexing it (`binary/at`, `byte-at`, `bit-*`) has the
exact value semantics of `nth` over a vector — which was already pure. Adding
these to `pure-ops` lets the numeric/binary fragment infer an **empty
footprint** instead of collapsing to `:opaque-world` on the unknown-callee
default. `println`/`swap!` etc. stay correctly impure.

### 1b. `termination`: ∃-ranking + the count-up measure

The old rule "every recur arg must shrink its own loop var" rejected **every
accumulator loop** — even a count-down one — because an accumulator never
shrinks. Termination needs only a **ranking function** (Floyd): *some* variable
that is well-founded on *every* recur.

- `measure-dir` returns `:down | :up | nil` (generalising the old boolean).
  `:down` = the original measures (`dec`, `(- v k)`, `rest`). `:up` = the
  counted-up idiom (`inc`, `(+ v k)`), the checksum/blend/pixel shape.
- A `:up` move is well-founded **only against an upper bound**. `upper-bounded-vars`
  harvests the loop's own guards (`(< v E)`, `(> E v)`) from the body; a `:up`
  ranking var is accepted iff its guard bounds it above.

Verified: accepts count-down, count-down+acc, count-up+acc, checksum, blend,
`inc`-form, `(> n i)`-form; rejects count-up-without-bound, spin `(recur i)`,
unbounded growth, and a bound on the wrong variable.

---

## 2. The lowerer, rewritten (`lower2.bl`, ~260 lines)

Two changes from the spike, both doctrinal:

1. **Reads the reader-node tree** (`typed/node-*`) — the SAME clean
   s-expression `footprint`/`termination`/`smt` consume. No `{:"{}"` wrapping,
   no dual accessors. One tree, one source of truth.
2. **Delegates eligibility to the engines.** `check-pure!` → `footprint/pure?`;
   `check-terminates!` → `termination/check-loop`. A refusal cites the engine's
   own verdict plus the doc-05 theorem number — never a bespoke message:

   ```
   dot (nth): REFUSED impure — footprint {:opaque-world :W} — not empty (doc-05 theorem 1)
   ```

It lowers **two provable kernel shapes**, chosen by the accumulator init:

| init | kind | shape | example |
|---|---|---|---|
| `0` | **fold** | scalar accumulator → `ret acc` | checksum, bdot |
| `[]` | **store** | `(conj out EXPR)` → per-element native store | blend, invert, scale, brighten |

---

## 3. The frame-rule payoff: functional accumulation → in-place store

bl binaries are immutable — there is no `byte-set!`. So the pixel idiom is
**functional**: build a fresh output with `(conj out EXPR)`, init `[]`. Naively
that allocates; natively we want an in-place store. What licenses the rewrite is
`system.footprint`'s **frame rule**:

```
(conj out …)   footprint = {}                    ; a write to a FRESH buffer
(binary/at src i) footprint = {}                 ; reads of the inputs
frame-independent?({out:W}, {src reads}) = true  ; disjoint resources
```

The output buffer is provably **disjoint from every input** (it did not exist
before the loop), so the write cannot alias a read. The functional build is
therefore **observationally pure**, and lowers safely to an in-place native
store loop with **no aliasing hazard** — the classic Separation-Logic frame
rule, decided structurally, no annotation. This is the theorem that turns a
pure-language pixel loop into a NIF-class store kernel without giving up any
BEAM guarantee.

---

## 4. Measured (this machine, cranelift 0.116)

Same kernel, same bytes, value-verified across all three implementations.

| kernel | bl-on-BEAM | JIT (lowered) | speedup | value check |
|---|---|---|---|---|
| **blend** (pixel, store) | 290 ns/byte | **2.0 ns/byte** | **~145×** | JIT out == BEAM out == Rust twin, all 1 MiB bytes |
| checksum (scalar, fold) | 135 ns/byte | ~1.1–1.7 ns/byte | ~80–120× | JIT == rustc ref, exact |
| invert (store) | — | ~0.9 ns/byte | — | JIT == BEAM ref, all 2048 bytes |

The pixel class is where the BEAM is *weakest* (boxed ints, no SIMD, a
reduction check per byte) and native is strongest — exactly the doc-05
prediction, now measured on the real compiler's output.

---

## 5. The decidability frontier (what lowers, and why the line is where it is)

Everything the lowerer accepts is decided by **total structural predicates** on
the reader-node tree — no search, no execution:

| pattern | verdict | deciding engine / check |
|---|---|---|
| `checksum`, `bdot` (fold) | ✅ accept | footprint=∅, ∃-ranking up-measure |
| `blend`, `invert`, `scale`, `brighten` (store) | ✅ accept | + frame-rule disjointness of the fresh output |
| `dot` via `nth` on a boxed vector | ⛔ `:impure` | footprint sees `nth`-on-arg as opaque (a *binary* would pass; a boxed seq is not a NIF sort) |
| count-up without a bounding guard | ⛔ `:may-diverge` | termination: no well-founded ranking |
| `ackermann` (non-counted recursion) | ⛔ `:not-a-counted-loop` | no single counted loop shape |
| general `while`/data-dependent exit | ⛔ | measure not exhibited ⇒ conservative refuse |

**Why the line sits here:** general termination is undecidable. The fragment
*buys* decidability by admitting exactly the loop shape where the measure check
is a one-line pattern test (counter + literal step + bounding guard). Anything
outside is refused **by name** — the failed theorem is reported, never silently
left unprotected. That is the doctrine: a refusal names the theorem it could not
prove.

### What would widen it further (ranked, honest)
1. **Tuples-of-scalars / multi-channel pixels** — `sort-of-tags` already maps
   the scalar theories; the lowerer needs a struct-load path. Decidable.
2. **`min`/`max` clamp** (saturating pixel ops) — `smt.bl` already lowers
   `min`/`max` to `ite`; add `Stm::Min/Max` to the IR. Decidable, small.
3. **Nested counted loops** (2-D blit) — a product measure `(rows-i)*W +
   (cols-j)`; termination's ranking generalises to lexicographic. Decidable.
4. **SIMD** — cranelift does not auto-vectorise; the measured blend gap vs a
   hand-SIMD twin is the residual. This is the ONE place the LLVM tier earns
   its keep — for pixel-class *parity*, not for correctness or the 145×.

---

## 6. Files

- `priv/lib/system/footprint.bl` — `pure-ops` += `binary/at`, byte/bit ops (committed)
- `priv/std/termination.bl` — `measure-dir`, `upper-bounded-vars`, ∃-ranking `check-loop` (working tree)
- `research/lowerers_spike/lower2.bl` — the reader-node lowerer
- `research/lowerers_spike/lower2_run.bl` — standalone demo entry
- `research/lowerers_spike/blend_harness.bl` — pixel value-equality harness
- `research/j1_probe/src/main.rs` — added `Stm::Sub` (fixed a `sub`→`add` parser
  bug), `store`/`udivimm`/`subimm`/`zext` text-IR ops, `--run-store` (3/4/5-param)

## 7. How to run (no escript rebuild needed)

The `./bl` escript embeds a **frozen** stdlib, so `priv/std` edits are invisible
to it and `mix escript.build` is ~20 min under load. Bypass: `env/eval` the
edited engine sources live.

```
BEAM_LISP_PATH=research/lowerers_spike ./bl run research/lowerers_spike/lower2_run.bl
BEAM_LISP_PATH=research/lowerers_spike ./bl run research/lowerers_spike/blend_harness.bl
# then, over the same bytes:
j1_probe --run-store /tmp/blend.ir /tmp/blend_dst.bin /tmp/blend_src.bin 170 /tmp/blend_jit.bin
cmp /tmp/blend_jit.bin /tmp/blend_ref.bin      # → identical
```
