# Direct native execution: what BEAM supports

Source-reviewed against OTP 29.0 / local ERTS 17.0.1 and Rustler 0.38.0. This is the API/lifetime contract, not a performance result. Measurements belong in RESULTS.md after the experiment runs.

## Yes: a NIF can call the same compiled kernel without a port

The supported shape is:

```text
BL function call
  -> OTP's NIF entry trampoline
  -> inspect binary + acquire owned kernel resource
  -> the existing Cranelift function (pointer, length, initial u64)
  -> construct scalar result
  -> return to BEAM
```

`vm.native/declare` already synthesizes the NIF host module through BL's ANF/Core backend and links it as ordinary BL functions. The experiment reuses that machinery with a private scratch OTP application's `priv/native`; it does not write an Elixir loader or modify the production native install directory.

For ordinary byte-aligned binaries, `enif_inspect_binary` exposes a pointer into the existing data. A nonzero **byte** offset alone does not require copying: the source uses `base[BYTE_OFFSET(offset)]`. It is a nonzero **bit** offset that takes the temporary-copy path. The experiment must not claim every possible binary view is unconditionally zero-copy.

The pointer is transient. Rustler's `Binary<'env>` ties it to the NIF call's environment; the compiled kernel must finish before that borrow ends. Do not store the pointer in a long-lived resource.

## Two scheduling choices, neither magically preemptible

- **Regular NIF:** executes on the ordinary scheduler thread. OTP cannot preempt the machine-code body. Documentation recommends returning in roughly a millisecond; that is guidance, not a timer the VM enforces.
- **Dirty CPU NIF:** executes on a separate bounded CPU scheduler pool. It protects ordinary scheduler availability, but pays dispatch/queue cost and can saturate its own pool.

Killing a process does **not** interrupt an executing native function. For dirty calls, links and monitors can fire while native execution continues; some process storage is retained until the call returns. Cancellation requires bounded chunks, cooperative checks, or an independently killable process boundary.

`enif_consume_timeslice` accounts for consumed time on a regular scheduler. It does not stop the function: the NIF must return or schedule a continuation. On dirty schedulers the function is a no-op.

For the research host, both byte count and static kernel work matter. A 4 KiB input limit alone is insufficient if the admitted IR can contain thousands of instructions per byte. A bounded normal-scheduler path must also restrict the admitted straight-line work; larger work belongs on the dirty path or behind the port.

## Three distinct lifetimes

1. **Input data:** the NIF environment/argument roots keep the binary alive for the current call. Killing a dirty caller does not immediately reclaim the storage the native call is still using.
2. **Generated executable memory:** the kernel resource owns the finalized JIT module. An in-flight call holds an independent strong reference; closing the public handle rejects future acquisitions but cannot free code underneath that call. Cranelift's default JITModule drop does not reclaim its code mappings, so explicit `free_memory` belongs at final destruction, not at handle-close time.
3. **NIF library:** OTP delays unloading native libraries while resource objects with destructor callbacks depend on them. This pins the bridge code, not automatically the separately generated JIT pages. Resource takeover during a real upgrade and deleting/reloading a module are different cases; observe the actual prototype behavior rather than assuming they are interchangeable.

The proposed ownership model uses Rust auto traits and a mutex around module ownership, not an unproven `unsafe impl Send/Sync`. Calls do not hold that mutex throughout computation. No raw integer executable handle is exposed to BL.

## No: arbitrary machine code is not a supported BEAM function body

OTP's JIT already turns BEAM instructions into native code, but a BEAM function has private calling conventions, process registers, heap/GC invariants, reduction accounting, tracing prologues and hot-code dispatch rules. A Cranelift C-ABI function does not have those properties.

OTP's `export.h` explicitly warns that blindly changing dispatch/code pointers can crash the emulator when tracing is enabled. There is no public API here for registering an arbitrary Cranelift entry address as a BEAM function. The supported choices are:

- emit BEAM/Core and let OTP's JIT handle it;
- expose a leaf native computation through a NIF;
- retain a port when crash containment or independent termination is more important than entry cost.

A NIF reduces boundary cost. It also removes process-level crash containment: invalid native code can take down the entire VM. Passing differential fixtures and resource tests does not erase that risk.

## Sources

- [OTP NIF API: scheduling, binaries, resources, dirty termination](https://www.erlang.org/doc/apps/erts/erl_nif.html)
- [OTP 29 NIF reference source](https://github.com/erlang/otp/blob/OTP-29.0/erts/doc/references/erl_nif.md)
- [OTP 29 binary inspection, dirty calls and library lifetime implementation](https://github.com/erlang/otp/blob/OTP-29.0/erts/emulator/beam/erl_nif.c)
- [OTP 29 export dispatch warning](https://github.com/erlang/otp/blob/OTP-29.0/erts/emulator/beam/export.h)
- [OTP 29 x86 BEAM-JIT calling conventions](https://github.com/erlang/otp/blob/OTP-29.0/erts/emulator/beam/jit/x86/beam_asm.hpp)
- [Rustler 0.38 Binary lifetime](https://docs.rs/rustler/0.38.0/rustler/types/binary/struct.Binary.html)
- [Rustler time-slice accounting](https://docs.rs/rustler/0.38.0/rustler/schedule/fn.consume_timeslice.html)
