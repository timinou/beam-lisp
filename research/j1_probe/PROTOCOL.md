# `j1_probe --serve-fold` — wire protocol, verifier envelope, limits

One frozen shared pipeline is measured three ways (RT/transducer, generated
fused BEAM, fused native). This document specifies the **native** sidecar:
`research/j1_probe`, mode `--serve-fold`.

```
y    = (3*b + 7) mod 256        # per byte of one immutable buffer
keep = y < 128
acc  = (acc + y) mod 2^64       # only for kept y; acc starts at a supplied u64
```

The native sidecar owns a read-only view of the buffer, a Cranelift JIT module,
and nothing else. Reuses the crate's existing `parse_ir` / `compile` (no second
compiler). No NIF, no callbacks into BEAM, no resource-lifetime promise beyond
*this process + the JIT module it owns*.

---

## 1. Native kernel ABI

```
extern "C" fn(ptr: *const u8, len: u64, init: u64) -> u64
```

| param | var | role |
|---|---|---|
| 0 | `Var(0)` | `ptr` — base of the immutable buffer |
| 1 | `Var(1)` | `len` — loop bound and buffer length |
| 2 | `Var(2)` | `acc` — the supplied initial accumulator, **modified in place** across iterations (it is an ABI register, not a memory slot) |

Loop semantics: `for i = 0; i < len; i += 1 { body }` with an **unsigned**
`i < len` test. The buffer is never written; the only result is the returned
`u64`. `len ≤ 1 MiB` (see §4).

---

## 2. Transport — Erlang Port `{packet, 4}`

Open the port with `{packet, 4}` so Erlang frames both directions. Every frame is:

```
+----------------+---------------------------+
| u32 BE length  | payload (length bytes)    |
+----------------+---------------------------+
```

### Handshake (first frame OUT)

After the IR is parsed, verified **and compiled**, the server writes exactly one
frame whose payload is the 5 ASCII bytes `READY`:

```
00 00 00 05  52 45 41 44 59        # "READY"
```

Nothing precedes it. The driver measures *compile + JIT startup* as the wall
time from process spawn to this frame. If the IR is missing or rejected the
process exits **2** with a message on stderr and writes **no** frame (see §5).

### Request (driver → server)

```
payload = init:u64 BE  ‖  buffer bytes        # length = 8 + len(buffer)
```

* `buffer` length is inferred: `frame_length - 8`.
* One request type only. The driver multiplexes request kinds (warmup, measured,
  byte adapatters, …); the native side **requires `frame_length ≥ 8`** and
  otherwise treats `payload[8..]` as the buffer. There is no request-type byte.
* The declared `frame_length` is checked against the cap **before** any
  allocation (§4).

### Response (server → driver)

```
payload = result:u64 BE  ‖  inner_ns:u64 BE   # length = 16
```

* `result` is the kernel's return value (module 2^64).
* `inner_ns` is the wall-clock nanoseconds of the single JIT call, with the
  arguments and the result wrapped in `std::hint::black_box` so the call cannot
  be elided or hoisted. It excludes framing, decode, allocation and I/O — the
  driver adds those as boundary cost.
* Requests are served in order; one response per request.

### Termination

* **EOF at a frame boundary** → exit **0** (clean; driver closed the port).
* There is no in-band `Q`/quit frame. Closing stdin is the shutdown.

### Stream discipline

stdout carries frames and only frames. Every diagnostic (malformed frame,
rejected IR, I/O error) goes to stderr. A driver must not expect any stdout
bytes outside the framing described above.

---

## 3. Modules and the shared `CompiledFold` resource

The crate is a library (`src/lib.rs` → `j1_probe`) plus a thin CLI binary
(`src/main.rs`).

* `src/kernel.rs` — the fragment IR (`Var`, `Stm`, `Kernel`) and its Cranelift
  lowering (`module_new`, `compile`, `parse_ir`). Every path uses this one
  compiler: `--run-ir`, `--serve-store`, the benchmark default, and the fold.
  There is no parallel compiler.
* `src/fold.rs` — the verifier (`fold_ir_check` → `parse_ir` → `verify_fold`),
  the `{packet,4}` framing, and the reusable resource `CompiledFold`.

### `CompiledFold` — the one compiled instance

```rust
// compile: parse + verify + JIT, bounded before Cranelift runs
pub fn compile(text: &str) -> Result<CompiledFold, String>
// run: one invocation over an immutable buffer, after the compile-time bounds
pub fn run(&self, buf: &[u8], init: u64) -> Result<u64, String>
```

* Owns the finalized `JITModule` behind `Mutex<Option<JITModule>>` and an
  immutable, **private** typed entry (`extern "C" fn(i64,i64,i64)->i64`). `run`
  is the only way to invoke it; no executable pointer is ever handed out.
* `Send + Sync` come from Rust's auto traits: `JITModule` is `Send` but not
  `Sync` (it holds a `RefCell`), and `Mutex<T>: Sync` needs only `T: Send`.
  **No `unsafe impl Send`/`Sync` exists or is needed.**
* `Drop` calls `JITModule::free_memory` (the default `JITModule` drop *leaks*
  its mappings). It is sound because no reference is active: `run` borrows
  `&self`, the entry is private, and callers own the value (`Arc` for sharing).
* Compile-time bounds, all enforced before Cranelift: IR text ≤ `FOLD_MAX_IR`
  (64 KiB), body ≤ `FOLD_MAX_STMS` (4096 statements), every var ≤
  `FOLD_MAX_VAR` (255). `run` re-checks `buf.len() ≤ FOLD_MAX_BUF` (1 MiB).
* Both `--serve-fold` and the NIF entry call this same `CompiledFold` — the
  sidecar is not a second codepath.

`main.rs` adds the `--serve-fold IR_FILE` dispatch. Shared `Zext8` lowering is
fixed once, in `kernel.rs`: the invalid same-width `uextend(I64, I64)` becomes
`band_imm(value, 0xff)`. That fix applies to every mode using `compile`; the
legacy store / arbitrary-IR modes were not otherwise refactored. The verifier
covers **serve-fold and the shared fold resource only**, not those legacy
interfaces.

---

## 4. Frame limits and failure modes

| constant | value |
|---|---|
| `FOLD_MAX_BUF` | 1 MiB (`1 << 20` = 1 048 576) |
| `FOLD_MAX_PAYLOAD` | `8 + FOLD_MAX_BUF` = 1 048 584 |

| condition | behaviour |
|---|---|
| `frame_length < 8` | stderr `frame payload length N < 8 (init u64 required)`; exit **1** |
| `frame_length > FOLD_MAX_PAYLOAD` | stderr `… exceeds cap 1048584 (8 + 1 MiB)`; exit **1** |
| EOF mid-header (1–3 bytes) | stderr `truncated frame: k of 4 bytes`; exit **1** |
| EOF mid-payload | stderr `truncated frame: k of N bytes`; exit **1** |
| clean EOF | exit **0** |
| IR unreadable / rejected | stderr `rejected IR: …`; exit **2**; no `READY` |
| stdout write fails | exit **1** |

**Allocation discipline:** the payload buffer is allocated only *after*
`frame_len_check` accepts the declared length, and its size is bounded by the
cap. A hostile 4 GiB length is rejected with no allocation.

---

## 5. IR text syntax

`parse_ir` (unchanged) reads this line-oriented text. `--serve-fold` first runs a
strict grammar check so malformed text is rejected instead of `unwrap`-panicking
inside `parse_ir`.

```
kernel <name> <nparams>     # exactly one; nparams must be 3
init   <var> <i64>          # counter init + optional temp inits
loop   <i> <limit> <step>   # exactly one
ret    <var>                # exactly one
imm    <dst> <i64>
add    <dst> <a> <b>
sub    <dst> <a> <b>
mul    <dst> <a> <b>
addimm <dst> <a> <i64>
subimm <dst> <a> <i64>      # accepted synonym of addimm with -k
udivimm <dst> <a> <i64>     # k must be a positive power of two (see §6)
load   <dst> <base> <off>   # base must be var 0, off must be the counter
lt     <dst> <a> <b>        # SIGNED a < b → 0/1
sel    <dst> <c> <a> <b>    # c != 0 ? a : b (branchless)
mov    <dst> <a>
zext   <dst> <a>            # low byte: a & 0xff  (the mod-256 step)
```

Blank lines and `#`-prefixed comments are ignored. `le`, `eq` and `store` are
**not** in the allowlist and are rejected by name; any other opcode is rejected
as `unknown opcode`. Fields must match the arity exactly, and every field must
be an integer of the right signedness.

Instruction semantics are the existing `compile` lowering over `i64` (wrapping
`add`/`sub`/`mul`), except `zext`, which compiles to `a & 0xff` (a same-width
`uextend` is not a valid cranelift instruction; the mask is the honest
lowering). `lt` is a *signed* compare — the frozen fragment keeps all operands
in `[0, 2^63)`, so signed and unsigned agree on `y < 128`.

---

## 6. Conservative verifier — exact acceptance rules

`parse_and_verify_fold` = grammar check → `parse_ir` → `verify_fold`. It admits a
**read-only, single-loop envelope**; it is *not* a general purpose compiler
check and makes **no semantic-equivalence claim** about the shared formula. The
generator owns the arithmetic; this gate owns the envelope.

Accepted iff all hold:

1. `nparams == 3`.
2. Exactly one `kernel`, one `loop`, one `ret` line.
3. `step == 1` (progress).
4. `limit` var is `1`; `ret` var is `2`.
5. The counter var `i` is not `0`, `1`, or `2`.
6. Exactly one `init` for `i`, with value `0` (`init <i> 0`).
7. No `init` targets a parameter (`0`, `1`, `2`).
8. Every referenced var is `≤ 255` (`FOLD_MAX_VAR`) — bounds `compile`'s
   `declare_var` fan-out.
9. Dataflow order: each source var is a parameter, the counter init, or was
   assigned earlier in the body. No use of an undefined var.
10. No `store` (read-only).
11. No write targets var `0` or `1`; only `acc` (var `2`) is an assignable
    parameter. (Temps ≥ 4, and writing `acc`, are allowed; SSA is *not* required
    but is recommended.)
12. No write targets the counter var `i` (would be non-progress; the `i += step`
    increment is emitted by `compile`, so the IR must not contain it).
13. Every `load` has `base == 0` and `off == i` (one pointer, sequential bytes).
14. `udivimm` divisor is a positive **power of two**.

Rule 14 is deliberately stricter than a bare "divisor > 0": `compile`'s
non-power-of-two `udivimm` uses a magic-multiply strength reduction that is only
exact for `0 ≤ x < 2^32`, while the fold accumulator spans the whole `u64` range.
Power-of-two divisors lower to an exact `ushr` for all `u64`. The frozen
pipeline needs only `zext` (mod 256), so this costs the generator nothing.

### What the verifier does **not** check

* That the body computes `y = (3*b+7) mod 256; keep y<128; acc += y`. A kernel
  with different arithmetic in the same envelope verifies — and will be measured
  as-is. Cross-checking the pipeline is the driver/oracle's job.
* That every byte is read, or that the loop increments (it always does).
* Numeric ranges of arithmetic (no value-range analysis). Envelope safety relies
  on the op set being memory-quiet and the pointer being fixed to var 0.

---

## 7. Canonical fixture

`j1_probe/fixtures/fused_fold.ir` (also `fold::FIXTURE_IR`) is the reference
descriptor both sides must agree on:

```
kernel fused 3
init 3 0
load 4 0 3        # b   = zext8(buf[i])
imm 5 3
mul 6 4 5         # 3*b
addimm 7 6 7      # 3*b + 7
zext 8 7          # mod 256
imm 9 128
lt 10 8 9         # y < 128
imm 11 0
sel 12 10 8 11    # kept ? y : 0
add 2 2 12        # acc += retained
loop 3 1 1        # i = 3, limit = len(1), step 1; init 3 0 above
ret 2             # return acc
```

`research/rt-selfhost/native_probe.ir` is the pre-existing checksum fixture; it
is **not** in the fold envelope (2 params, no `ret`/param-2 contract) and is only
used by `--run-ir`.

---

## 8. Gate commands

```sh
# unit tests (private target dir; do not touch the BL build)
cd research/j1_probe
CARGO_TARGET_DIR=/tmp/j1_probe_target cargo test --offline

# build the binary probe
CARGO_TARGET_DIR=/tmp/j1_probe_target cargo build --offline

# Full experiment from repository root: BL owns generation, builds, wire
# checks, the independent oracle, resident port measurement and reporting.
cd ../..
BL_NO_LOCK=1 bin/bl run research/rt-selfhost/fusion/experiment.bl
```

`cargo test` runs 9 cases: canonical fixture verify, fixture-vs-independent-
oracle execution, edge/cap buffers (`0`, `1`, all 256 values, 1 MiB fixed and
patterned buffers, u64 wrap), unsafe-shape rejection (store, `le`/`eq`, arbitrary
base/offset, param/counter rewrite, non-progress, bad `ret`, counter init,
undefined vars, out-of-range vars, bad divisors), malformed/extra-loop
rejection, and frame-length / framing / EOF semantics.

---

## 9. Notes for the IR generator

* Emit exactly the §7 shape (or a semantically equivalent one inside §6).
* Do **not** emit an increment for the counter and do **not** emit a `store`.
* Use `zext` for `mod 256`. Use `lt` for `y < 128`. Use `sel dst, cond, y, zero`
  and `add 2, 2, retained` for the filter+reduce.
* Keep temps in `[4, 255]`; init only the counter.
* The accumulator is var `2`; there is no separate "init temp" — the driver's
  `init` arrives as parameter 2.
* The response `inner_ns` is the inner call only. Boundary cost (port send/recv,
  binary allocation, BEAM↔native byte adaptation) is measured by the driver
  around it.
