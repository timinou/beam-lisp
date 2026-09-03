# lowerers_spike — bl → native IR through the REAL compiler

Run: `BEAM_LISP_PATH=research/lowerers_spike ./bl run research/lowerers_spike/run.bl`
(needs `/tmp/j1_buf_1m.bin`, produced by `j1_probe`; cross-checks against
`/tmp/j1_rust_checksum.txt` values printed by the probe)

## What it proves

**The compiler's quoted output lowers to native IR — in beam-lisp, at REPL
pace.** The lowerer (`run.bl`, ~250 lines) walks the actual emitted tree of
`priv/boot/compiler.bl` (verified shapes: `Link.defvar` call → `{:fixed 2 name
def-ast}` → `:def` → self-apply loop scaffold → `:if` → recur), fuses the ANF
pass into the walk (every argument position becomes a fresh single-assignment
temp in evaluation order), and emits the j1_probe counted-loop IR as text.

Measured (1 MiB LCG buffer, value-verified across all three implementations):

| stage | result |
|---|---|
| lowering pace (bl, on the BEAM) | ~1.1–2.1 ms per kernel |
| JIT exec of lowered IR (cranelift) | 1.07–1.77 ms / 1 MiB ≈ 1.1–1.7 ns/byte |
| bl-on-BEAM same kernel, same bytes | ~135 ns/byte |
| **speedup, same kernel same bytes** | **≈ 76–120×** (spike band was 61–160×) |
| value oracle | bl == rustc-ref (mod-2^59 kernel); JIT == rustc-ref (wrapping kernel); both exact |

## Eligibility = decidable checks, demonstrated

| defn | verdict | the check that fired |
|---|---|---|
| checksum | ACCEPTED | counted loop, literal +k measure, fragment primops only |
| dot-product | REFUSED :impure | `nth` is not a fragment primop |
| parse-header | REFUSED :not-shrinking | recur re-binds the loop var without a literal +k |
| ackermann | REFUSED :not-a-counted-loop | no fn/if/self-re-applying-recur shape |

Each check is a total structural predicate on the quoted tree — decidable by
construction, no search, no heuristics.

## The one encoding surprise (recorded for PLAN-074)

`compiler/compile` returns bl-DATA: EVERY Elixir tuple — call nodes, fn nodes,
var nodes, the def-tuple itself — is wrapped as `{:"{}" [] [k m args]}`, and
the OUTERMOST node is a real 3-tuple. Accessors must normalize per node
(`sl-parts` in run.bl). Also: `binary/at`-style module calls arrive as
`:apply` nodes (not `:. M F`), recur's loop var is threaded through the CALLEE
position (`(. (. loop) [loop]) [i' acc']`), and var nodes' context is an atom
(not a list) — `sl-var-node?` documents the exact shape.

## Follow-ups

- `(sl-args* hd)` params extraction needed a both-encodings guard — the same
  normalization should land in bl-ANF's reader (PLAN-074).
- The `(defn f [x] ...)` interning of a runtime-compiled defn is callable via
  `Env/fetch` returning the fn value directly.
