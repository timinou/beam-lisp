# Native eligibility, inter-procedural

The doc-05 offload gate (`docs/memory-policy/05-proof-directed-native-offload`),
now computed over the **whole program** instead of one function at a time.

## What changed, and why it matters

The shipped spec computes eligibility per function: `footprint = ∅ ∧ terminates
∧ sorts ⊆ NIF-safe ∧ bounded-work`. But a function that *calls a helper* could
not be judged, because before whole-program analysis the helper was an opaque
callee — footprint collapsed to `:opaque-world`, and the caller was refused as
impure even when the helper was provably pure.

`system.analyze` computes each summary with every callee's summary substituted
(the footprint closure). So a caller of a pure helper is itself pure, and whole
call *trees* become offloadable — not just leaf functions.

## Measured (research/native-eligible/eligible.bl)

```clojure
(defn dist2 [dx dy] (erlang/+ (erlang/* dx dx) (erlang/* dy dy)))  ; pure leaf
(defn step  [x y]   (dist2 (erlang/- x 1) (erlang/- y 1)))         ; CALLS dist2
(defn log-it [v]    (io/format "~p~n" [v]))                        ; IO
(defn noisy  [x]    (do (log-it x) (erlang/+ x 1)))                ; calls log-it
(defn mk-kw  []     :kw)                                            ; returns keyword
(defn bad-sort [x]  (mk-kw))                                        ; inherits :kw
```

| fn | verdict | theorem |
|---|---|---|
| `step` | **eligible**, sort `Int`, "calls only-pure helpers — whole tree offloadable" | ✓ pure (via closure) ∧ terminates ∧ sort |
| `noisy` | refused `:impure {:opaque-world :W}` | `log-it`'s IO propagates up |
| `log-it` | refused `:impure` | IO footprint |
| `mk-kw` | refused `:sort` (`:kw` ∉ NIF-safe) | theorem 3 |
| `bad-sort` | refused `:sort` | inherits `mk-kw`'s `:kw` return |

`step` is the key result: it is offloadable **only because** `dist2`'s purity
flowed through the summary. Per-function analysis would refuse it.

## The relationship to the native road

This is the pressure-tested shape from `docs/from-source-to-silicon/07`:

- **MMORPG server** — hot paths are spatial-hash steps, AoE scans, pathfinding:
  scalar counted loops that call small pure helpers (distance, clamp, hash). The
  `step → dist2` tree is exactly that. Cranelift already matches hand-Rust here
  (1.29×); the missing piece was proving the *whole tree* eligible, which the
  closure now does.
- **Model swarm** — routing tokens between experts is embedding dot-products and
  softmax: a `softmax → exp` tree over wide vectors. Same closure shape; the open
  question there is SIMD width (PLAN-087), orthogonal to eligibility.

`research/lowerers_spike` already proved the *lowering* (145× pixel blend,
byte-identical) delegating eligibility to `system.footprint` + `termination`.
This module supplies the missing **inter-procedural** eligibility those lowerers
should consume: `eligible` returns the doc-05 verdict per function, closed over
callees, with the sort theorem wired in.

## Gaps (honest)

- **Work bound (theorem 4)** not computed here — the termination measure exhibits
  the decreasing quantity; counting loop-body ops gives `work ≤ k·measure₀`
  (doc-05 §"Eligibility is four theorems"). A follow-up adds it to the summary.
- **Arg sorts** — this checks the *return* sort; a full gate also checks every
  argument sort. `typed/arg-tags` + `smt/sort-of-tags` supplies it; wire into the
  summary's `:arg-sorts`.
- Recursion through an SCC is handled by analyze's fixpoint (monotone toward
  `:opaque-world`), so a recursive pure kernel converges to pure — verify on a
  recursive corpus before shipping.
