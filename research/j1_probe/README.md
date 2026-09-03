# P0 — JIT fragment probe (PLAN-075)

The first measured answer to "would an LLVM JIT let beam-lisp go seamlessly
native?" — before any bl plumbing. The IR in `src/main.rs` is deliberately the
bl-ANF node vocabulary (let/prim/load/store over I64 scalars + one counted
loop, single-assignment temps, dynamic offsets explicit); when bl-ANF lands
(PLAN-074), this lowering plugs into it directly.

## What it measures

Two claims that had never been measured in this repo and that the whole
JIT-vs-cargo decision leans on:

1. **REPL-pace** — compile-from-IR must be ~ms, not cargo-seconds.
2. **Codegen quality** — the emitted loop must be NIF-class vs what a
   hand-written crate (gen.rs) would produce.

Two kernels, one per named beneficiary:

| kernel | beneficiary | body |
|---|---|---|
| `checksum` over 64 MiB | doc 05's own dirty-cpu example | `acc = acc*31 + byte` — dependent scalar chain |
| `blend` over 2×16 MiB | loom-shell glyph composite (PLAN-002) | `dst[i] = (src*a + dst*(255-a))/255` — the op pure iodata cannot express |

Handwritten Rust twins are the gen.rs reference (rustc = LLVM backend).
Correctness is asserted value-for-value before timing. Medians of 31 fresh
module compiles / 24 exec runs.

## Results (this machine, 2026-09-02, cranelift 0.116.1)

```
compile  checksum:    0.04 ms   blend:    0.05 ms   (median of 31 fresh modules)
exec     checksum  jit:   71.86 ms (  0.9 GB/s)   ref:   55.89 ms (  1.2 GB/s)   ratio 1.29x
exec     blend     jit:   11.43 ms   ref:    1.94 ms   ratio 5.89x
```

| gate | result |
|---|---|
| compile ≤ 50 ms | **PASS by 1000×** — REPL-pace native is real; cargo AOT at def-time is ~5 orders slower |
| exec ≤ 1.5× hand-Rust | **PASS on checksum (1.29×), FAIL on blend (5.89×)** |

## The blend diagnosis (the finding that matters)

Three lowerings measured:

| blend lowering | JIT ms | ratio vs rustc |
|---|---|---|
| literal `udiv 255` | 34.5 | **18.0×** |
| strength-reduced `(x*0x8081)>>23` | 11.4 | **5.9×** |
| (rustc twin: magic-mul **+ auto-vectorization**) | 1.9 | 1× |

So the cranelift→LLVM gap decomposes exactly: ~3× is scalar-vs-SIMD, ~3× more
is the naive `div` (a dependent ~26-cycle instruction per byte that cranelift
does not strength-reduce). Neither is exotic — both are standard LLVM passes.

## Verdict

- **A JIT backend is viable** — compile-pace is not a risk, it is a landslide.
- **cranelift alone is not sufficient** as the only tier for the fragment:
  kernels in the blend class (the loom-shell renderer path) need LLVM-class
  optimization or a fragment-owned peephole (strength reduction is trivial and
  provable; vectorization is not). This *measured* input upgrades the
  "cranelift quick tier + LLVM opt tier" split from taste to requirement:
  cranelift for REPL-pace first compile, LLVM tier for kernels that earn it.
- Per-fn offload (doc 05) and engine-in-bl claims that lean on "the JIT makes
  scalar loops NIF-class" hold for checksum-class code and do NOT hold, on
  cranelift, for blend-class code.

## Run

```
cargo run --release
```
