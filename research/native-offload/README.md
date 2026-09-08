# native-offload — the whole gated pipeline, wired

The missing edge from **proof** to **speed**: `native.eligible` (the doc-05
gate) → `lower2` (defn → j1 IR) → `j1_probe` (Cranelift JIT) → a **differential
oracle** → a **measured** speedup. Each piece existed alone; this is the wire.

## Run

```sh
# 1. build the Cranelift JIT probe (writes /tmp/j1_buf_1m.bin on first run)
cargo build --release --manifest-path research/j1_probe/Cargo.toml
/home/user/.cache/cargo-target/release/j1_probe >/dev/null   # dumps the buffer

# 2. run the gated pipeline
BEAM_LISP_PATH=research/native-offload \
  mix beam_lisp.run --path priv research/native-offload/offload_run.bl
```

## What it does, per kernel

1. **GATE** — `native.eligible` must return `:eligible`; a refusal names the
   theorem (`:impure`, `:may-diverge`, `:sort`) and the pipeline stops.
2. **LOWER** — `lower2/lower-kernel` turns the defn into j1 IR text (a second,
   finer gate: it refuses shapes outside the counted-loop arithmetic fragment).
3. **BEAM** — the same kernel through the interpreter: baseline value + time.
4. **JIT** — shell to `j1_probe --run-ir`: Cranelift compiles + runs the IR.
5. **ORACLE** — the JIT value **must equal** the BEAM value. Only a value
   -identical result may claim a speedup.
6. **REPORT** — the measured BEAM-vs-JIT speedup, gated on the oracle.

## Measured (1 MiB LCG buffer, `checksum` kernel = `acc = acc*31 + byte`)

| backend | time / 1 MiB | value |
|---|---|---|
| beam-lisp interpreter | ~0.85–1.05 **s** | 8383099488808122916 |
| Cranelift JIT (lowered IR) | ~1.3–1.9 **ms** | 8383099488808122916 |
| **speedup** | **≈ 440–800×** | **byte-identical (oracle ✓)** |

The JIT and interpreter compute the **identical** 64-bit checksum — the
differential oracle is what licenses the speedup claim. `dot` (which calls
`nth`) is correctly **REFUSED** at the lowering gate.

## Status

This is the research wiring — it shells to the standalone `j1_probe`.
Productionizing it is a Rustler JIT-host cdylib exposing `compile(ir, sig)` /
`call(handle, args)` NIFs so an eligible function dispatches to native code
in-VM, with the oracle run once at compile time. The **proof that the pipeline
is sound and fast is here**; the cdylib is the remaining engineering (a PLAN
follow-up). See `docs/tools/09-native-offload-pipeline.bl.org`.
