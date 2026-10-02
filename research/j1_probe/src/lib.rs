//! Reusable library for the j1 native-offload probe.
//!
//! * [`kernel`] — the bl-ANF-shaped fragment IR and its Cranelift lowering
//!   (`Var`, `Stm`, `Kernel`, `module_new`, `compile`, `parse_ir`). One compiler,
//!   shared by every caller.
//! * [`fold`] — the verified read-only fold pipeline (grammar + dataflow
//!   verifier) and [`fold::CompiledFold`], the owned JIT resource with the
//!   string/bytes/`u64` API.
//!
//! The `j1_probe` binary is a thin CLI over this library; there is no parallel
//! compiler in either.

pub mod fold;
pub mod kernel;
