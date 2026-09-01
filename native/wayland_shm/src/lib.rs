//! `wayland_shm` — the one seam the VM cannot say for a native Wayland client.
//!
//! # What this is
//!
//! A wl_shm pool is an fd the compositor can mmap. The BEAM can PASS an fd
//! over the Wayland socket (`:socket.sendmsg` + SCM_RIGHTS, verified on OTP 29)
//! and can WRITE bytes through a raw file handle — but it can neither CREATE an
//! anonymous memfd nor pwrite at an offset into an integer fd. Those two
//! syscalls are this entire crate: `memfd_create` + `ftruncate`, and `pwrite`.
//!
//! # Why memfd, not a tmpfs file
//!
//! `file:open` on OTP 29 returns an opaque `#Ref` handle — no integer fd ever
//! reaches Erlang (verified 2026-09-01). A memfd created IN the NIF comes back
//! as an integer immediately, is anonymous (no /tmp cleanup path), lives in
//! tmpfs by definition, and is exactly what wl_shm expects (it does not care
//! whether the fd is named; it only mmaps). The fd is handed to the compositor
//! by beam-lisp code (`wayland.conn`), not here — this crate never sees a
//! socket.
//!
//! # Surface
//!
//!   pool-new(bytes)             -> fd          memfd_create + ftruncate
//!   pool-write(fd, off, binary) -> :ok         pwrite, partial-write loop
//!   pool-close(fd)              -> :ok         close
//!   __nif-loaded__()            -> true        the available? marker
//!
//! Plain schedulers (not dirty): a bar frame is ~1 MB, written once per
//! repaint — sub-millisecond, no NIF-trap risk.

use rustler::NifResult;

rustler::atoms! {
    ok,
}

/// Create an anonymous memfd of `bytes` capacity; returns the integer fd.
#[rustler::nif]
fn pool_new(bytes: usize) -> NifResult<i32> {
    let name = c"loom-bar-pool";
    let fd = unsafe { libc::memfd_create(name.as_ptr(), libc::MFD_CLOEXEC) };
    if fd < 0 {
        return Err(rustler::Error::RaiseAtom("memfd_create_failed"));
    }
    if unsafe { libc::ftruncate(fd, bytes as libc::off_t) } != 0 {
        unsafe { libc::close(fd) };
        return Err(rustler::Error::RaiseAtom("ftruncate_failed"));
    }
    Ok(fd)
}

/// pwrite the whole binary at `offset` in the pool (partial-write loop).
#[rustler::nif]
fn pool_write(fd: i32, offset: i64, data: rustler::Term) -> NifResult<rustler::Atom> {
    let bin = match rustler::Binary::from_term(data) {
        Ok(b) => b,
        Err(_) => return Err(rustler::Error::RaiseAtom("not_a_binary")),
    };
    let buf = bin.as_slice();
    let mut done = 0usize;
    while done < buf.len() {
        let n = unsafe {
            libc::pwrite(
                fd,
                buf[done..].as_ptr() as *const libc::c_void,
                buf.len() - done,
                offset + done as i64,
            )
        };
        if n < 0 {
            return Err(rustler::Error::RaiseAtom("pwrite_failed"));
        }
        done += n as usize;
    }
    Ok(ok())
}

/// Close the fd once the pool is destroyed.
#[rustler::nif]
fn pool_close(fd: i32) -> rustler::Atom {
    unsafe { libc::close(fd) };
    ok()
}

/// The marker `BeamLisp.Native.available?/1` calls: a loaded NIF vs the
/// unloaded stub, so a checkout without cargo reads the bar as ABSENT.
#[rustler::nif]
fn __nif_loaded__() -> bool {
    true
}

// The host module name must match what `BeamLisp.Native.host_module/1` derives
// from the `wayland.shm` namespace: `BeamLisp.Native.Wayland.Shm`. Bare init! —
// rustler binds every #[nif] in the crate to this one Erlang module (the same
// shape the datom crates use).
rustler::init!("Elixir.BeamLisp.Native.Wayland.Shm");
