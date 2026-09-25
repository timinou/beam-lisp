//! `j1_nif` — the in-VM, resource-safe NIF bridge for the shared verified
//! Cranelift fold.
//!
//! The host module is `Elixir.BeamLisp.Native.Fusion.Invm`: the `vm.native`
//! derivation of the bl namespace `fusion.invm`. This crate adds resource
//! lifetime, input caps and diagnostics to the *one* compiler already shared by
//! every caller (`j1_probe::fold::CompiledFold`) — it is not a second compiler
//! and it re-implements neither the verifier nor the code generator.
//!
//! # The handle contract
//!
//! `kernel_compile/1` compiles one verified kernel and returns a resource. The
//! resource state is `Mutex<Option<Arc<OwnedCode>>>`, where `OwnedCode` is the
//! counted owner of a `CompiledFold`:
//!
//! * A **call** clones the `Arc` while the handle lock is held, releases the
//!   lock, then computes on the clone. The lock is never held across a kernel
//!   run, so calls do not serialize on the handle.
//! * **`kernel_close/1`** takes the `Option` out. A call already in flight keeps
//!   the code alive through its own clone; the free is counted when the last
//!   owner drops, not when the handle was closed.
//! * The resource **destructor** drops whatever code the handle still owns, so
//!   a handle reclaimed by the BEAM without an explicit close still frees and
//!   counts. A dropped handle whose code is retained by an in-flight call is
//!   freed by that call's clone.
//!
//! # Caps and schedulers
//!
//! | entry | scheduler | admitted input |
//! |---|---|---|
//! | `kernel_compile/1` | dirty CPU | IR text ≤ 64 KiB (`j1_probe::fold::FOLD_MAX_IR`) |
//! | `kernel_call/3` | regular | ≤ 4096 bytes and ≤ 65536 body-statements × bytes |
//! | `kernel_call_dirty/3` | dirty CPU | byte buffer ≤ 1 MiB (`FOLD_MAX_BUF`) |
//! | `kernel_noop/2` | regular | byte buffer ≤ 1 MiB (validated, never read) |
//! | `kernel_noop_dirty/2` | dirty CPU | byte buffer ≤ 1 MiB (validated, never read) |
//!
//! The no-op entries do no kernel work. For the byte-aligned inputs measured
//! here decoding borrows the bytes. OTP can copy a bit-misaligned binary view,
//! so these no-ops are not a universal constant-time guarantee for every term
//! that decodes as a binary.
//!
//! Compilation itself is bounded *inside* `CompiledFold::compile` (≤ 64 KiB IR,
//! ≤ 4096 statements, ≤ 255 vars) and runs only on the dirty CPU scheduler.
//!
//! # Errors — the bl-facing contract
//!
//! Every refusal raises `:badarg`. There is no partially-applied call and no
//! error that depends on which check fired first:
//!
//! | condition | outcome |
//! |---|---|
//! | argument is not a resource / not a binary / not a u64-in-range | `:badarg` |
//! | handle already closed (or reclaimed) | `:badarg` |
//! | buffer over the entry's cap; IR over 64 KiB; IR not UTF-8 | `:badarg` |
//! | IR rejected by the shared verifier | `:badarg` |
//! | regular body-statements × input-bytes over 65536 | `:badarg` |
//! | `kernel_close/1` on an open handle | `true` |
//! | `kernel_close/1` on an already-closed handle | `false` (handle stays closed) |
//!
//! `:badarg` rather than a rich reason is deliberate: the same atom covers a
//! forged handle and a policy refusal, so a caller branches once
//! (`try/catch`) and the *reason* text stays where the diagnosis belongs — in
//! the compiler/verifier's own `Err(String)`, which this bridge checks by
//! refusing to compile a rejected kernel at all.
//!
//! # Counters (`kernel_stats/0`)
//!
//! A map `#%{live: n, created: n, freed: n, inflight: n}`:
//!
//! * `created` — kernels compiled into a resource (monotonic).
//! * `freed` — kernels whose executable code was actually freed (monotonic).
//!   This counts the *free*, never the close: it moves only in
//!   `OwnedCode::drop`, after the module's memory has been released.
//! * `live` — `created - freed`, the codes currently alive.
//! * `inflight` — validated kernel calls holding an executable-code Arc.
//!   Refusals, compilation, close and no-op entries are excluded. The count is
//!   decremented on every call exit, including unwind.
//!
//! `live`/`created`/`freed` are diagnostics, not a load-bearing synchronization
//! primitive; a reader may see one counter move before its neighbour.

use j1_probe::fold::CompiledFold;
use rustler::{Binary, Env, Error, NifMap, NifResult, ResourceArc};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

/// IR text cap for `kernel_compile/1` — 64 KiB. The library enforces the same
/// number, but the bridge states it so the contract is visible at the door.
const MAX_IR: usize = j1_probe::fold::FOLD_MAX_IR;
/// Regular-scheduler byte cap for `kernel_call/3` — 4 KiB.
const REGULAR_CAP: usize = 4096;
/// Bound straight-line IR work as well as bytes on the normal scheduler.
const REGULAR_WORK_BUDGET: usize = 65_536;
/// Dirty-CPU byte cap (the library's own 1 MiB run envelope).
const DIRTY_CAP: usize = j1_probe::fold::FOLD_MAX_BUF;
/// The no-op entries never read the buffer, so both admit the full envelope;
/// the check is the documented type/limit validation, not a work bound.
const NOOP_CAP: usize = DIRTY_CAP;

// ── counters ────────────────────────────────────────────────────────────────

static CREATED: AtomicU64 = AtomicU64::new(0);
static FREED: AtomicU64 = AtomicU64::new(0);
static INFLIGHT: AtomicU64 = AtomicU64::new(0);

fn created() -> u64 {
    CREATED.load(Ordering::Acquire)
}
fn freed() -> u64 {
    FREED.load(Ordering::Acquire)
}
fn inflight() -> u64 {
    INFLIGHT.load(Ordering::Acquire)
}

/// Diagnostic snapshot returned by `kernel_stats/0`. Field names become the
/// atom keys the shape table above documents.
#[derive(NifMap)]
struct KernelStats {
    live: u64,
    created: u64,
    freed: u64,
    inflight: u64,
}

/// Counts one entry for the whole of its body. `Drop` runs on every exit path
/// — early return, `?`, and a panic unwinding through the entry — so
/// `inflight` cannot leak on unwind.
struct Inflight;

impl Inflight {
    fn enter() -> Self {
        INFLIGHT.fetch_add(1, Ordering::AcqRel);
        Inflight
    }
}

impl Drop for Inflight {
    fn drop(&mut self) {
        INFLIGHT.fetch_sub(1, Ordering::AcqRel);
    }
}

// ── owned executable code ───────────────────────────────────────────────────

/// The one place the `freed` counter moves: an owner of a `CompiledFold` whose
/// `Drop` releases the JIT module *before* counting the release.
///
/// The inner fold is held in an `Option` so `Drop` can free it explicitly and
/// only then increment: `freed` must mean "the code is gone", not "the handle
/// was closed".
struct OwnedCode(Option<CompiledFold>);

impl OwnedCode {
    fn new(fold: CompiledFold) -> Self {
        CREATED.fetch_add(1, Ordering::AcqRel);
        OwnedCode(Some(fold))
    }

    /// Borrow the compiled kernel. Always `Some` while any `Arc<OwnedCode>` is
    /// alive; `None` only inside `Drop`, after every other owner is gone.
    fn fold(&self) -> &CompiledFold {
        self.0.as_ref().expect("owned code is present until drop")
    }
}

impl Drop for OwnedCode {
    fn drop(&mut self) {
        // Explicit: `CompiledFold::drop` calls `JITModule::free_memory`, and
        // this statement runs before the counter below.
        drop(self.0.take());
        FREED.fetch_add(1, Ordering::AcqRel);
    }
}

// ── the handle ──────────────────────────────────────────────────────────────

/// A compiled kernel's handle. `Mutex<Option<Arc<OwnedCode>>>` is morally
/// `Option<Arc<CompiledFold>>` with the free delegated to a counted wrapper —
/// Rust cannot hook the drop of the foreign `CompiledFold` type, so the wrapper
/// is what makes `freed` track the real free. No `unsafe impl Send/Sync`: the
/// auto traits hold because `CompiledFold: Send + Sync` and `Mutex<T>: Sync`
/// needs only `T: Send`.
struct KernelResource {
    code: Mutex<Option<Arc<OwnedCode>>>,
}

impl KernelResource {
    fn new(code: OwnedCode) -> Self {
        KernelResource {
            code: Mutex::new(Some(Arc::new(code))),
        }
    }

    /// Clone the code `Arc` while holding the handle lock, then release it.
    /// `None` means the handle is closed (or its code is already gone).
    fn acquire(&self) -> Option<Arc<OwnedCode>> {
        lock(&self.code).as_ref().cloned()
    }

    /// Take the code out. `true` when this call released the handle, `false`
    /// when it was already closed. Either way the handle is closed afterwards,
    /// so repeating the call changes nothing.
    fn close(&self) -> bool {
        let taken = { lock(&self.code).take() };
        taken.is_some()
    }
}

#[rustler::resource_impl]
impl rustler::Resource for KernelResource {
    /// Last owner of the handle: drop the code it still owns. If a call is in
    /// flight, that call's own `Arc` clone outlives this and frees the code
    /// instead — `freed` follows the code either way.
    fn destructor(self, _env: Env<'_>) {
        let code = self.code.into_inner().unwrap_or_else(|e| e.into_inner());
        drop(code);
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

// ── the shared, BEAM-free core (what the tests drive) ───────────────────────

/// Why an entry refused. Mapped to `:badarg` at the NIF boundary.
#[derive(Debug, PartialEq, Eq)]
enum Reject {
    Closed,
    Bounds,
    Kernel(String),
}

/// Compile one verified kernel into counted owned code.
fn compile_kernel(text: &str) -> Result<OwnedCode, Reject> {
    if text.len() > MAX_IR {
        return Err(Reject::Bounds);
    }
    CompiledFold::compile(text)
        .map(OwnedCode::new)
        .map_err(Reject::Kernel)
}

/// The regular/dirty body borrows the decoded binary; it does not clone it.
/// Rustler/OTP inspection may copy a bit-misaligned view before this function.
/// The handle lock is released before the run.
fn call_entry(resource: &KernelResource, buf: &[u8], init: u64, cap: usize) -> Result<u64, Reject> {
    if buf.len() > cap {
        return Err(Reject::Bounds);
    }
    let code = resource.acquire().ok_or(Reject::Closed)?;
    if cap == REGULAR_CAP
        && code.fold().body_statements().saturating_mul(buf.len()) > REGULAR_WORK_BUDGET
    {
        return Err(Reject::Bounds);
    }
    // A positive counter now means a validated call actually owns the code,
    // not an entry that could still fail before acquiring its Arc.
    let _inflight = Inflight::enter();
    code.fold().run(buf, init).map_err(Reject::Kernel)
}

/// The no-op body: validates length and types, touches no byte, returns `init`.
fn noop_entry(buf: &[u8], init: u64, cap: usize) -> Result<u64, Reject> {
    if buf.len() > cap {
        return Err(Reject::Bounds);
    }
    Ok(init)
}

fn bad_arg(_: Reject) -> Error {
    Error::BadArg
}

// ── NIF surface ─────────────────────────────────────────────────────────────

/// `kernel_compile/1` — compile IR text into a resource. Dirty CPU: the JIT is
/// bounded (≤ 64 KiB IR) but far too slow for a normal scheduler slot.
#[rustler::nif(name = "kernel_compile", schedule = "DirtyCpu")]
fn kernel_compile(source: Binary<'_>) -> NifResult<ResourceArc<KernelResource>> {
    let text = std::str::from_utf8(source.as_slice()).map_err(|_| Error::BadArg)?;
    let code = compile_kernel(text).map_err(bad_arg)?;
    Ok(ResourceArc::new(KernelResource::new(code)))
}

/// `kernel_call/3` — run the kernel over a borrowed binary on a normal
/// scheduler slot. ≤ 4096 bytes AND ≤ 65536 straight-line IR operations;
/// see the module docs for the error contract.
#[rustler::nif(name = "kernel_call")]
fn kernel_call(
    env: Env<'_>,
    resource: ResourceArc<KernelResource>,
    buf: Binary<'_>,
    init: u64,
) -> NifResult<u64> {
    let started = std::time::Instant::now();
    let result = call_entry(&resource, buf.as_slice(), init, REGULAR_CAP).map_err(bad_arg);
    // Account against a nominal 1 ms slice. This is a scheduling hint after
    // bounded work returns, NOT preemption of the generated machine code.
    let percent = started.elapsed().as_nanos().div_ceil(10_000).clamp(1, 100) as i32;
    rustler::schedule::consume_timeslice(env, percent);
    result
}

/// `kernel_call_dirty/3` — the same run, dirty CPU, up to the 1 MiB envelope.
#[rustler::nif(name = "kernel_call_dirty", schedule = "DirtyCpu")]
fn kernel_call_dirty(
    resource: ResourceArc<KernelResource>,
    buf: Binary<'_>,
    init: u64,
) -> NifResult<u64> {
    call_entry(&resource, buf.as_slice(), init, DIRTY_CAP).map_err(bad_arg)
}

/// `kernel_close/1` — invalidate the handle for future calls. `true` when this
/// call released live code, `false` when it was already closed. Never frees
/// code a call is still using; `freed` follows the last owner.
#[rustler::nif(name = "kernel_close")]
fn kernel_close(resource: ResourceArc<KernelResource>) -> bool {
    resource.close()
}

/// The diagnostics snapshot. A plain function so the tests drive the same
/// arithmetic the entry returns.
fn snapshot_stats() -> KernelStats {
    let created = created();
    let freed = freed();
    KernelStats {
        live: created.saturating_sub(freed),
        created,
        freed,
        inflight: inflight(),
    }
}

/// `kernel_stats/0` — the diagnostics map documented in the module header.
#[rustler::nif(name = "kernel_stats")]
fn kernel_stats() -> KernelStats {
    snapshot_stats()
}

/// `kernel_noop/2` — the regular-scheduler floor: validate a binary and a u64,
/// return `init` untouched. No kernel read or resource. Our measured inputs
/// are byte-aligned; OTP may copy a bit-misaligned view during decoding.
#[rustler::nif(name = "kernel_noop")]
fn kernel_noop(buf: Binary<'_>, init: u64) -> NifResult<u64> {
    noop_entry(buf.as_slice(), init, NOOP_CAP).map_err(bad_arg)
}

/// `kernel_noop_dirty/2` — the same floor through the dirty-CPU door.
#[rustler::nif(name = "kernel_noop_dirty", schedule = "DirtyCpu")]
fn kernel_noop_dirty(buf: Binary<'_>, init: u64) -> NifResult<u64> {
    noop_entry(buf.as_slice(), init, NOOP_CAP).map_err(bad_arg)
}

/// `__nif_loaded__/0` — the capability answer `vm.native/available?` reads.
/// The synthesized host stub raises; the loaded NIF is what returns `true`.
#[rustler::nif(name = "__nif_loaded__")]
fn nif_loaded() -> bool {
    true
}

// The host module name is the `vm.native/host-module` derivation of `fusion.invm`
// and must match it character-for-character or `load_nif` returns `{:bad_lib}`.
rustler::init!("Elixir.BeamLisp.Native.Fusion.Invm");

// ── tests: the BEAM-free core, driven directly ──────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use j1_probe::fold::FIXTURE_IR;
    use std::sync::OnceLock;

    /// Every test that reads or mutates the process-wide counters takes this
    /// lock, so `cargo test`'s parallel harness cannot interleave deltas.
    fn test_lock() -> MutexGuard<'static, ()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Independent reference for the frozen fold (not a copy of the lowering).
    fn oracle(buf: &[u8], init: u64) -> u64 {
        let mut acc = init;
        for &b in buf {
            let y = (3u64.wrapping_mul(b as u64).wrapping_add(7)) & 0xff;
            if y < 128 {
                acc = acc.wrapping_add(y);
            }
        }
        acc
    }

    fn resource() -> KernelResource {
        KernelResource::new(compile_kernel(FIXTURE_IR).expect("canonical fixture compiles"))
    }

    fn assert_send_sync<T: Send + Sync>() {}

    #[test]
    fn caps_match_the_documented_contract() {
        let _g = test_lock();
        assert_eq!(REGULAR_CAP, 4096);
        assert_eq!(DIRTY_CAP, 1024 * 1024);
        assert_eq!(NOOP_CAP, DIRTY_CAP);
        assert_eq!(MAX_IR, 64 * 1024);
    }

    #[test]
    fn regular_call_runs_the_shared_kernel() {
        let _g = test_lock();
        let resource = resource();
        // the fixture's own boundary bytes: y = 7, 127, 4 → 138
        assert_eq!(
            call_entry(&resource, &[0, 40, 255], 0, REGULAR_CAP),
            Ok(138)
        );
        // and the same answer as the independent oracle on a longer buffer
        let buf: Vec<u8> = (0..=255u8).collect();
        assert_eq!(
            call_entry(&resource, &buf, 7, REGULAR_CAP),
            Ok(oracle(&buf, 7))
        );
        assert_eq!(inflight(), 0, "a completed call leaves nothing in flight");
    }

    #[test]
    fn regular_cap_is_exact() {
        let _g = test_lock();
        let resource = resource();
        assert_eq!(
            call_entry(&resource, &vec![0u8; REGULAR_CAP], 0, REGULAR_CAP),
            Ok(oracle(&vec![0u8; REGULAR_CAP], 0))
        );
        assert_eq!(
            call_entry(&resource, &vec![0u8; REGULAR_CAP + 1], 0, REGULAR_CAP),
            Err(Reject::Bounds)
        );
    }

    #[test]
    fn regular_work_is_bounded_independently_of_input_size() {
        let _g = test_lock();
        let heavier = FIXTURE_IR.replace(
            "loop 3 1 1",
            &format!("{}loop 3 1 1", "addimm 4 4 0\n".repeat(64)),
        );
        let resource = KernelResource::new(compile_kernel(&heavier).unwrap());
        let buf = vec![0u8; REGULAR_CAP];
        assert_eq!(call_entry(&resource, &buf, 0, REGULAR_CAP), Err(Reject::Bounds));
        assert_eq!(inflight(), 0, "refused work never owns an active-call slot");
        assert_eq!(call_entry(&resource, &[0], 0, REGULAR_CAP), Ok(7));
        assert_eq!(call_entry(&resource, &buf, 0, DIRTY_CAP), Ok(oracle(&buf, 0)));
    }

    #[test]
    fn dirty_and_noop_caps_are_exact() {
        let _g = test_lock();
        let resource = resource();
        assert_eq!(
            call_entry(&resource, &vec![0u8; DIRTY_CAP], 0, DIRTY_CAP),
            Ok(oracle(&vec![0u8; DIRTY_CAP], 0))
        );
        assert_eq!(
            call_entry(&resource, &vec![0u8; DIRTY_CAP + 1], 0, DIRTY_CAP),
            Err(Reject::Bounds)
        );
        assert_eq!(noop_entry(&[], 7, NOOP_CAP), Ok(7));
        assert_eq!(noop_entry(&vec![0u8; NOOP_CAP], 9, NOOP_CAP), Ok(9));
        assert_eq!(
            noop_entry(&vec![0u8; NOOP_CAP + 1], 0, NOOP_CAP),
            Err(Reject::Bounds)
        );
        assert_eq!(inflight(), 0);
    }

    #[test]
    fn closed_handle_refuses_and_close_is_idempotent() {
        let _g = test_lock();
        let resource = resource();
        assert!(resource.close(), "first close releases the handle");
        assert_eq!(
            call_entry(&resource, &[], 0, REGULAR_CAP),
            Err(Reject::Closed)
        );
        assert_eq!(
            call_entry(&resource, &[], 0, DIRTY_CAP),
            Err(Reject::Closed)
        );
        assert!(!resource.close(), "a second close changes nothing");
    }

    #[test]
    fn freed_counts_the_free_not_the_close() {
        let _g = test_lock();
        let created_before = created();
        let freed_before = freed();

        let resource = resource();
        assert_eq!(created(), created_before + 1, "compile counts the create");

        // Hold a call-like owner of the code, then close the handle: the code
        // must NOT be counted freed while an owner is still using it.
        let held = resource.acquire().expect("handle is open");
        assert!(resource.close());
        assert_eq!(
            freed(),
            freed_before,
            "closing a handle must not count a code free while a call holds it"
        );

        // The last owner dropping is the actual free.
        drop(held);
        assert_eq!(freed(), freed_before + 1);
        assert_eq!(created() - freed(), created_before - freed_before);
    }

    #[test]
    fn dropped_handle_without_close_still_frees() {
        let _g = test_lock();
        let created_before = created();
        let freed_before = freed();
        {
            let _resource = resource();
        }
        assert_eq!(created(), created_before + 1);
        assert_eq!(freed(), freed_before + 1, "resource GC frees and counts");
    }

    #[test]
    fn inflight_decrements_on_unwind() {
        let _g = test_lock();
        let before = inflight();
        let unwound = std::panic::catch_unwind(|| {
            let _guard = Inflight::enter();
            assert_eq!(inflight(), before + 1);
            panic!("simulated unwind through an entry");
        });
        assert!(unwound.is_err(), "the panic really unwound");
        assert_eq!(inflight(), before, "the guard decremented on unwind");
    }

    #[test]
    fn parallel_callers_share_one_code_instance() {
        let _g = test_lock();
        let created_before = created();
        let resource = Arc::new(resource());
        let buf: Arc<Vec<u8>> = Arc::new((0..=255u8).collect());
        let expected = oracle(&buf, 11);

        let callers: Vec<_> = (0..8)
            .map(|_| {
                let resource = Arc::clone(&resource);
                let buf = Arc::clone(&buf);
                std::thread::spawn(move || call_entry(&resource, &buf, 11, REGULAR_CAP))
            })
            .collect();
        for caller in callers {
            assert_eq!(caller.join().expect("caller thread"), Ok(expected));
        }
        assert_eq!(created(), created_before + 1, "one compile, many calls");
        assert_eq!(inflight(), 0);
    }

    #[test]
    fn close_with_an_in_flight_owner_keeps_the_code_runnable() {
        let _g = test_lock();
        let resource = resource();
        let held = resource.acquire().expect("handle is open");
        assert!(resource.close(), "the handle is closed under the owner");
        // The acquired code is independent of the handle and still runs.
        assert_eq!(held.fold().run(&[0, 40, 255], 0), Ok(138));
    }

    #[test]
    fn handle_and_code_are_send_and_sync() {
        assert_send_sync::<KernelResource>();
        assert_send_sync::<OwnedCode>();
        assert_send_sync::<Arc<KernelResource>>();
    }

    #[test]
    fn compile_rejects_oversized_and_malformed_ir() {
        let _g = test_lock();
        let mut big = String::from(FIXTURE_IR);
        while big.len() <= MAX_IR {
            big.push_str("# padding padding padding padding padding padding\n");
        }
        assert_eq!(compile_kernel(&big).err(), Some(Reject::Bounds));
        assert!(matches!(
            compile_kernel(&format!("{FIXTURE_IR}store 0 3 12\n")),
            Err(Reject::Kernel(_))
        ));
    }

    #[test]
    fn stats_are_the_documented_shape() {
        let _g = test_lock();
        let stats = snapshot_stats();
        assert_eq!(stats.created, created());
        assert_eq!(stats.freed, freed());
        assert_eq!(stats.inflight, inflight());
        assert_eq!(stats.live, stats.created - stats.freed);
    }
}
