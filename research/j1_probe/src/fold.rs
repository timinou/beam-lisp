//! Exact shared-pipeline fold server for `j1_probe --serve-fold`.
//!
//! Wire contract, verifier envelope, and limits: `research/j1_probe/PROTOCOL.md`.
//!
//! The frozen shared pipeline is `y = (3*b + 7) mod 256; keep y < 128;
//! acc += y (wrapping u64)`, over one immutable byte buffer, starting from a
//! supplied u64 accumulator. This module does NOT recognise that formula — it
//! admits a conservative read-only u64 loop envelope and lets the generator own
//! the arithmetic. It reuses the crate's existing `parse_ir` / `compile`; there
//! is no second compiler here.

use crate::kernel::{compile, parse_ir, Kernel, Stm};
use cranelift_jit::JITModule;
use std::sync::Mutex;
use std::time::Instant;

const FOLD_MAX_VAR: usize = 255; // 0..=255 → compile declares ≤ 256 vars
/// Cap on the IR text accepted by [`CompiledFold::compile`], in bytes.
pub const FOLD_MAX_IR: usize = 64 * 1024; // 64 KiB of text IR
/// Cap on body statements in an admitted kernel, checked before Cranelift runs.
pub const FOLD_MAX_STMS: usize = 4096;
/// Cap on the immutable byte buffer passed to [`CompiledFold::run`] — the
/// dirty-CPU (1 MiB) envelope. The regular-NIF 4 KiB envelope is a *caller*
/// policy: a NIF that runs on a normal scheduler slot checks
/// `buf.len() <= 4096` before calling `run`.
pub const FOLD_MAX_BUF: usize = 1024 * 1024; // 1 MiB immutable byte buffer
const FOLD_MAX_PAYLOAD: usize = 8 + FOLD_MAX_BUF; // init u64 + buffer

/// Canonical fused descriptor in the exact SSA shape the verifier admits.
/// `fn(ptr,len,init)`: i = var3 (init 0, step 1), acc = var2, single read-only
/// load `load 4 0 3`, then `acc += (y < 128 ? y : 0)`.
#[allow(dead_code)]
pub const FIXTURE_IR: &str = "\
kernel fused 3
init 3 0
load 4 0 3
imm 5 3
mul 6 4 5
addimm 7 6 7
zext 8 7
imm 9 128
lt 10 8 9
imm 11 0
sel 12 10 8 11
add 2 2 12
loop 3 1 1
ret 2
";

fn fold_line_err(ln: usize, m: impl std::fmt::Display) -> String {
    format!("line {ln}: {m}")
}

fn fold_need(t: &[&str], ln: usize, n: usize) -> Result<(), String> {
    if t.len() == n {
        Ok(())
    } else {
        Err(fold_line_err(
            ln,
            format!("'{}' expects {} fields, got {}", t[0], n, t.len()),
        ))
    }
}

fn fold_uvar(s: &str, ln: usize) -> Result<usize, String> {
    s.parse::<usize>()
        .map_err(|_| fold_line_err(ln, format!("bad var index '{s}'")))
}

fn fold_iconst(s: &str, ln: usize) -> Result<i64, String> {
    s.parse::<i64>()
        .map_err(|_| fold_line_err(ln, format!("bad integer literal '{s}'")))
}

/// Strict grammar + opcode allowlist. Runs BEFORE `parse_ir` (whose numeric
/// fields are `unwrap`-parsed) so malformed text is rejected, never compiled.
fn fold_ir_check(text: &str) -> Result<(), String> {
    let (mut n_kernel, mut n_loop, mut n_ret) = (0usize, 0usize, 0usize);
    for (idx, raw) in text.lines().enumerate() {
        let ln = idx + 1;
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let t: Vec<&str> = line.split_whitespace().collect();
        let all_vars = |t: &[&str]| -> Result<(), String> {
            for x in &t[1..] {
                fold_uvar(x, ln)?;
            }
            Ok(())
        };
        match t[0] {
            "kernel" => {
                fold_need(&t, ln, 3)?;
                if n_kernel > 0 {
                    return Err(fold_line_err(ln, "duplicate 'kernel' line"));
                }
                n_kernel += 1;
                fold_uvar(t[2], ln)?;
            }
            "loop" => {
                fold_need(&t, ln, 4)?;
                if n_loop > 0 {
                    return Err(fold_line_err(ln, "duplicate 'loop' line (extra loop shape)"));
                }
                n_loop += 1;
                fold_uvar(t[1], ln)?;
                fold_uvar(t[2], ln)?;
                fold_iconst(t[3], ln)?;
            }
            "ret" => {
                fold_need(&t, ln, 2)?;
                if n_ret > 0 {
                    return Err(fold_line_err(ln, "duplicate 'ret' line"));
                }
                n_ret += 1;
                fold_uvar(t[1], ln)?;
            }
            "init" => {
                fold_need(&t, ln, 3)?;
                fold_uvar(t[1], ln)?;
                fold_iconst(t[2], ln)?;
            }
            "imm" => {
                fold_need(&t, ln, 3)?;
                fold_uvar(t[1], ln)?;
                fold_iconst(t[2], ln)?;
            }
            "addimm" | "subimm" | "udivimm" => {
                fold_need(&t, ln, 4)?;
                fold_uvar(t[1], ln)?;
                fold_uvar(t[2], ln)?;
                let value = fold_iconst(t[3], ln)?;
                if t[0] == "subimm" && value == i64::MIN {
                    return Err(fold_line_err(ln, "subimm literal cannot be i64::MIN"));
                }
            }
            "load" => {
                fold_need(&t, ln, 4)?;
                all_vars(&t)?;
            }
            "add" | "sub" | "mul" | "lt" => {
                fold_need(&t, ln, 4)?;
                all_vars(&t)?;
            }
            "sel" => {
                fold_need(&t, ln, 5)?;
                all_vars(&t)?;
            }
            "mov" | "zext" => {
                fold_need(&t, ln, 3)?;
                all_vars(&t)?;
            }
            "le" | "eq" | "store" => {
                return Err(fold_line_err(
                    ln,
                    format!("opcode '{}' is not in the read-only allowlist", t[0]),
                ));
            }
            other => return Err(fold_line_err(ln, format!("unknown opcode '{other}'"))),
        }
    }
    if n_kernel != 1 {
        return Err(format!(
            "fold IR needs exactly one 'kernel' line, got {n_kernel}"
        ));
    }
    if n_loop != 1 {
        return Err(format!(
            "fold IR needs exactly one 'loop' line, got {n_loop}"
        ));
    }
    if n_ret != 1 {
        return Err(format!("fold IR needs exactly one 'ret' line, got {n_ret}"));
    }
    Ok(())
}

fn stm_dst(s: &Stm) -> Option<usize> {
    match s {
        Stm::Imm { dst, .. }
        | Stm::Add { dst, .. }
        | Stm::Sub { dst, .. }
        | Stm::Mul { dst, .. }
        | Stm::AddImm { dst, .. }
        | Stm::LoadU8 { dst, .. }
        | Stm::Mov { dst, .. }
        | Stm::Zext8 { dst, .. }
        | Stm::UdivImm { dst, .. }
        | Stm::Lt { dst, .. }
        | Stm::Le { dst, .. }
        | Stm::Eq { dst, .. }
        | Stm::Sel { dst, .. } => Some(dst.0),
        Stm::StoreU8 { .. } => None,
    }
}

fn stm_srcs(s: &Stm) -> Vec<usize> {
    match s {
        Stm::Imm { .. } => vec![],
        Stm::Add { a, b, .. }
        | Stm::Sub { a, b, .. }
        | Stm::Mul { a, b, .. }
        | Stm::Lt { a, b, .. }
        | Stm::Le { a, b, .. }
        | Stm::Eq { a, b, .. } => vec![a.0, b.0],
        Stm::Sel { c, a, b, .. } => vec![c.0, a.0, b.0],
        Stm::AddImm { a, .. }
        | Stm::UdivImm { a, .. }
        | Stm::Mov { a, .. }
        | Stm::Zext8 { a, .. } => vec![a.0],
        Stm::LoadU8 { base, off, .. } => vec![base.0, off.0],
        Stm::StoreU8 { base, off, v } => vec![base.0, off.0, v.0],
    }
}

/// Structural + dataflow gate over the parsed kernel. Conservative: it admits
/// a superset of the fused pipeline but never anything unsafe (no stores, no
/// arbitrary pointers, no param/counter rewriting, no unbounded var fan-out).
fn verify_fold(k: &Kernel) -> Result<(), String> {
    const PTR: usize = 0;
    const LEN: usize = 1;
    const ACC: usize = 2;
    if k.n_params != 3 {
        return Err(format!(
            "fold kernel needs 3 params (ptr,len,init), got {}",
            k.n_params
        ));
    }
    if k.step != 1 {
        return Err(format!("fold loop step must be 1 (progress), got {}", k.step));
    }
    if k.limit.0 != LEN {
        return Err(format!(
            "fold loop limit must be param 1 (len), got var {}",
            k.limit.0
        ));
    }
    if k.ret.0 != ACC {
        return Err(format!(
            "fold ret must be param 2 (acc/init), got var {}",
            k.ret.0
        ));
    }
    let i = k.i.0;
    if i == PTR || i == LEN || i == ACC {
        return Err(format!("fold loop counter must not alias a param (got var {i})"));
    }
    // Bound the codegen input before it reaches Cranelift (the var fan-out is
    // bounded below by FOLD_MAX_VAR; this bounds the statement fan-out).
    if k.body.len() > FOLD_MAX_STMS {
        return Err(format!(
            "fold body has {} statements, cap {FOLD_MAX_STMS}",
            k.body.len()
        ));
    }

    let mut maxv = k.n_params - 1;
    maxv = maxv.max(i).max(k.limit.0).max(k.ret.0);
    for (v, _) in &k.inits {
        maxv = maxv.max(v.0);
    }
    for s in &k.body {
        for v in stm_srcs(s) {
            maxv = maxv.max(v);
        }
        if let Some(d) = stm_dst(s) {
            maxv = maxv.max(d);
        }
    }
    if maxv > FOLD_MAX_VAR {
        return Err(format!("fold var {maxv} out of range (max {FOLD_MAX_VAR})"));
    }
    let n_vars = maxv + 1;

    let mut defined = vec![false; n_vars];
    defined[PTR] = true;
    defined[LEN] = true;
    defined[ACC] = true;
    let mut counter_init = false;
    for (v, c) in &k.inits {
        let v = v.0;
        if v < k.n_params {
            return Err(format!(
                "fold init targets param var {v} (params arrive as arguments)"
            ));
        }
        if v == i {
            if *c != 0 {
                return Err(format!("fold loop counter must init to 0, got {c}"));
            }
            counter_init = true;
        }
        defined[v] = true;
    }
    if !counter_init {
        return Err(format!(
            "fold loop counter var {i} must be initialized (`init {i} 0`)"
        ));
    }

    for s in &k.body {
        if let Stm::StoreU8 { .. } = s {
            return Err("fold kernel must not store (read-only)".into());
        }
        for v in stm_srcs(s) {
            if v >= n_vars || !defined[v] {
                return Err(format!("fold use of undefined var {v}"));
            }
        }
        if let Some(d) = stm_dst(s) {
            if d < k.n_params && d != ACC {
                return Err(format!(
                    "fold write to param var {d} (only acc var {ACC} is assignable)"
                ));
            }
            if d == i {
                return Err(format!("fold write to loop counter var {i} (nonprogress)"));
            }
            if d >= n_vars {
                return Err(format!("fold write to out-of-range var {d}"));
            }
            defined[d] = true;
        }
        match s {
            Stm::LoadU8 { base, off, .. } => {
                if base.0 != PTR {
                    return Err(format!(
                        "fold load base must be param 0 (ptr), got var {}",
                        base.0
                    ));
                }
                if off.0 != i {
                    return Err(format!(
                        "fold load offset must be the loop counter var {i}, got var {}",
                        off.0
                    ));
                }
            }
            Stm::UdivImm { k: c, .. } => {
                let d = *c as u64;
                if *c <= 0 || (d & (d - 1)) != 0 {
                    return Err(format!(
                        "fold udivimm divisor must be a positive power of two, got {c} \
                         (the non-power-of-two strength reduction is exact only below 2^32)"
                    ));
                }
            }
            Stm::Le { .. } | Stm::Eq { .. } => {
                return Err("fold compare must be `lt` (signed)".into());
            }
            _ => {}
        }
    }
    if !defined[k.ret.0] {
        return Err(format!("fold ret var {} is undefined", k.ret.0));
    }
    Ok(())
}

fn parse_and_verify_fold(text: &str) -> Result<Kernel, String> {
    fold_ir_check(text)?;
    let k = parse_ir(text).ok_or_else(|| "fold IR produced no kernel".to_string())?;
    verify_fold(&k)?;
    Ok(k)
}

// ── the reusable compiled resource ───────────────────────────────────────

/// A verified, JIT-compiled instance of the frozen fold.
///
/// Owns the finalized `JITModule` and a typed entry point (private — never
/// handed out). The module sits behind `Mutex<Option<..>>` for exactly one
/// reason: `JITModule` is `Send` but **not** `Sync` (it holds a `RefCell`),
/// while `Mutex<T>: Sync` requires only `T: Send`. That is what makes
/// `CompiledFold: Send + Sync` through Rust's auto traits — there is no
/// `unsafe impl Send`/`Sync` here, and none is needed.
///
/// Invocation happens only through [`CompiledFold::run`], on an immutable byte
/// slice, after the verifier's bounds were enforced at compile time. `Drop`
/// frees the module's executable memory; see its comment for why that is sound.
pub struct CompiledFold {
    module: Mutex<Option<JITModule>>,
    entry: extern "C" fn(i64, i64, i64) -> i64,
    body_statements: usize,
}

impl CompiledFold {
    /// Parse, verify and compile `text` (the text IR format of `PROTOCOL.md`).
    ///
    /// Bounds are enforced *before* Cranelift runs: the IR text is capped at
    /// [`FOLD_MAX_IR`] bytes, and the verifier caps the body at
    /// [`FOLD_MAX_STMS`] statements and every var at `FOLD_MAX_VAR`.
    pub fn compile(text: &str) -> Result<Self, String> {
        if text.len() > FOLD_MAX_IR {
            return Err(format!("fold IR is {} bytes, cap {FOLD_MAX_IR}", text.len()));
        }
        let k = parse_and_verify_fold(text)?;
        let (module, code) = compile(&k);
        // The verifier fixed the signature to `fn(ptr,len,acc)->u64`; this is
        // the address Cranelift produced for that exact signature.
        let entry: extern "C" fn(i64, i64, i64) -> i64 = unsafe { std::mem::transmute(code) };
        Ok(Self {
            module: Mutex::new(Some(module)),
            entry,
            body_statements: k.body.len(),
        })
    }

    /// Run the fold over `buf` with initial accumulator `init`.
    ///
    /// `buf` is treated as strictly immutable: only its address and length reach
    /// the kernel. Returns `Err` if `buf` exceeds [`FOLD_MAX_BUF`] (the 1 MiB
    /// dirty-CPU envelope); the regular-NIF 4 KiB envelope is a *caller* policy
    /// — check it before calling `run`.
    pub fn run(&self, buf: &[u8], init: u64) -> Result<u64, String> {
        if buf.len() > FOLD_MAX_BUF {
            return Err(format!(
                "fold buffer is {} bytes, cap {FOLD_MAX_BUF} (1 MiB)",
                buf.len()
            ));
        }
        let entry = self.entry;
        let r = entry(buf.as_ptr() as i64, buf.len() as i64, init as i64);
        Ok(r as u64)
    }

    /// Static straight-line work per byte. A small binary alone is not a
    /// sufficient scheduler bound when the admitted IR body can be large.
    pub fn body_statements(&self) -> usize {
        self.body_statements
    }

    /// Total bytes of immutable input this resource accepts (the 1 MiB
    /// dirty-CPU envelope). Caller-side policies (the 4 KiB regular NIF) check
    /// against this *before* calling [`CompiledFold::run`].
    pub const MAX_BUF: usize = FOLD_MAX_BUF;
}

impl Drop for CompiledFold {
    fn drop(&mut self) {
        // `free_memory` invalidates pointers retrieved from the module, so it is
        // sound here precisely because no active references remain:
        //   · `run` borrows `&self`, so no call can be in flight while `drop`
        //     holds `&mut self`;
        //   · the entry pointer is private and never handed out; callers own the
        //     `CompiledFold` itself (by value, or via `Arc`), never a raw
        //     pointer into its code.
        // Rust's default drop for `JITModule` *leaks* its mappings (`Memory::drop`
        // mem::forgets them), so this explicit free is what reclaims them.
        let slot = self.module.get_mut().unwrap_or_else(|e| e.into_inner());
        if let Some(module) = slot.take() {
            unsafe { module.free_memory() };
        }
    }
}

// ── Port framing (Erlang `{packet, 4}`: 4-byte big-endian length + payload) ──

fn frame_len_check(len: usize) -> Result<(), String> {
    if len < 8 {
        return Err(format!("frame payload length {len} < 8 (init u64 required)"));
    }
    if len > FOLD_MAX_PAYLOAD {
        return Err(format!(
            "frame payload length {len} exceeds cap {FOLD_MAX_PAYLOAD} (8 + 1 MiB)"
        ));
    }
    Ok(())
}

fn write_frame(w: &mut impl std::io::Write, payload: &[u8]) -> std::io::Result<()> {
    w.write_all(&(payload.len() as u32).to_be_bytes())?;
    w.write_all(payload)?;
    w.flush()
}

/// Fill `buf` exactly. `Ok(false)` = clean EOF before any byte (frame boundary);
/// `Err` = EOF mid-buffer (truncated) or an I/O error.
fn read_exact_eof(r: &mut impl std::io::Read, buf: &mut [u8]) -> Result<bool, String> {
    let mut off = 0;
    while off < buf.len() {
        match r.read(&mut buf[off..]) {
            Ok(0) => {
                if off == 0 {
                    return Ok(false);
                }
                return Err(format!("truncated frame: {off} of {} bytes", buf.len()));
            }
            Ok(n) => off += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(format!("read error: {e}")),
        }
    }
    Ok(true)
}

/// `--serve-fold IR`: compile once through [`CompiledFold`], then serve
/// `{packet,4}` frames. Request payload = init(u64 BE) ‖ raw buffer; response
/// payload = result(u64 BE) ‖ inner_ns(u64 BE). First frame out is ASCII `READY`.
///
/// Exit codes: 0 = clean EOF at a frame boundary; 1 = malformed/truncated/
/// oversized frame (message on stderr); 2 = IR missing or rejected. No stdout
/// diagnostics other than frames.
pub fn serve_fold(ir_path: &str) -> ! {
    let text = match std::fs::read_to_string(ir_path) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("serve-fold: cannot read {ir_path}: {e}");
            std::process::exit(2);
        }
    };
    // The one shared resource: parse + verify + compile happen once, and every
    // frame runs through the same `CompiledFold::run` the NIF path uses — the
    // sidecar is not a second codepath. The resource owns the JIT module for the
    // whole process lifetime and frees its code on drop at exit.
    let fold = match CompiledFold::compile(&text) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("serve-fold: rejected IR: {e}");
            std::process::exit(2);
        }
    };

    let mut stdin = std::io::stdin().lock();
    let mut stdout = std::io::stdout().lock();
    if write_frame(&mut stdout, b"READY").is_err() {
        std::process::exit(1);
    }
    loop {
        let mut lenb = [0u8; 4];
        match read_exact_eof(&mut stdin, &mut lenb) {
            Ok(true) => {}
            Ok(false) => std::process::exit(0), // clean EOF at a frame boundary
            Err(e) => {
                eprintln!("serve-fold: {e}");
                std::process::exit(1);
            }
        }
        let len = u32::from_be_bytes(lenb) as usize;
        if let Err(e) = frame_len_check(len) {
            eprintln!("serve-fold: {e}");
            std::process::exit(1);
        }
        // Allocation happens only after the cap check, and is bounded by it.
        let mut payload = vec![0u8; len];
        match read_exact_eof(&mut stdin, &mut payload) {
            Ok(true) => {}
            Ok(false) => {
                eprintln!("serve-fold: truncated frame payload at EOF");
                std::process::exit(1);
            }
            Err(e) => {
                eprintln!("serve-fold: {e}");
                std::process::exit(1);
            }
        }
        let init = u64::from_be_bytes(payload[..8].try_into().unwrap());
        let buf = &payload[8..];
        let t = Instant::now();
        let r = match fold.run(std::hint::black_box(buf), std::hint::black_box(init)) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("serve-fold: {e}");
                std::process::exit(1);
            }
        };
        let ns = t.elapsed().as_nanos() as u64;
        let r = std::hint::black_box(r);
        let mut resp = [0u8; 16];
        resp[..8].copy_from_slice(&r.to_be_bytes());
        resp[8..].copy_from_slice(&ns.to_be_bytes());
        if write_frame(&mut stdout, &resp).is_err() {
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    /// Independent reference for the frozen shared pipeline.
    fn fold_ref(buf: &[u8], init: u64) -> u64 {
        let mut acc = init;
        for &b in buf {
            let y = (3u64.wrapping_mul(b as u64).wrapping_add(7)) & 0xff;
            if y < 128 {
                acc = acc.wrapping_add(y);
            }
        }
        acc
    }

    fn rejection(ir: &str) -> String {
        match parse_and_verify_fold(ir) {
            Ok(_) => panic!("expected the fold verifier to reject this IR:\n{ir}"),
            Err(e) => e,
        }
    }

    #[test]
    fn fixture_verifies() {
        let k = parse_and_verify_fold(FIXTURE_IR).expect("canonical fused IR verifies");
        assert_eq!(k.n_params, 3);
        assert_eq!(k.ret.0, 2);
        assert_eq!(k.i.0, 3);
        assert_eq!(k.step, 1);
        assert_eq!(k.limit.0, 1);
    }

    #[test]
    fn fixture_runs_and_matches_independent_reference() {
        let fold = CompiledFold::compile(FIXTURE_IR).unwrap();
        let mut buf = Vec::with_capacity(4096);
        let mut x: u64 = 0x9e3779b97f4a7c15;
        for _ in 0..4096 {
            x = x
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            buf.push((x >> 33) as u8);
        }
        for init in [0u64, 1, 7, 12345, 0xdead_beef_cafe_babe, u64::MAX] {
            let got = fold.run(&buf, init).unwrap();
            assert_eq!(got, fold_ref(&buf, init), "init={init:#x}");
        }
    }

    #[test]
    fn fixture_handles_edge_buffers_at_cap() {
        let fold = CompiledFold::compile(FIXTURE_IR).unwrap();
        let cases: Vec<Vec<u8>> = vec![
            vec![],
            vec![0],
            vec![255],
            (0..=255u8).collect(),
            vec![0u8; FOLD_MAX_BUF],
            vec![255u8; FOLD_MAX_BUF],
            (0..FOLD_MAX_BUF).map(|i| (i % 256) as u8).collect(),
        ];
        for buf in &cases {
            let got = fold.run(buf, 3).unwrap();
            assert_eq!(got, fold_ref(buf, 3), "len={}", buf.len());
        }
        // u64 wrap: init near MAX plus a large retained sum.
        let big = vec![1u8; 300_000]; // y = 10 per byte
        assert_eq!(
            fold.run(&big, u64::MAX).unwrap(),
            fold_ref(&big, u64::MAX)
        );
    }

    #[test]
    fn rejects_unsafe_shapes() {
        assert!(rejection(&FIXTURE_IR.replace("add 2 2 12", "store 0 3 12"))
            .contains("allowlist"));
        assert!(rejection(&FIXTURE_IR.replace("lt 10 8 9", "le 10 8 9")).contains("allowlist"));
        assert!(rejection(&FIXTURE_IR.replace("lt 10 8 9", "eq 10 8 9")).contains("allowlist"));

        assert!(rejection(&FIXTURE_IR.replace("load 4 0 3", "load 4 1 3")).contains("load base"));
        assert!(rejection(&FIXTURE_IR.replace("load 4 0 3", "load 4 0 2")).contains("load offset"));

        assert!(rejection(&FIXTURE_IR.replace("add 2 2 12", "add 0 2 12")).contains("param var 0"));
        assert!(rejection(&FIXTURE_IR.replace("add 2 2 12", "add 1 2 12")).contains("param var 1"));
        assert!(
            rejection(&FIXTURE_IR.replace("add 2 2 12", "add 3 2 12")).contains("loop counter")
        );

        assert!(rejection(&FIXTURE_IR.replace("loop 3 1 1", "loop 3 1 2")).contains("step"));
        assert!(rejection(&FIXTURE_IR.replace("loop 3 1 1", "loop 3 3 1")).contains("limit"));
        assert!(rejection(&FIXTURE_IR.replace("ret 2", "ret 4")).contains("ret"));

        assert!(rejection(&FIXTURE_IR.replace("init 3 0", "init 3 1")).contains("counter"));
        assert!(rejection(&FIXTURE_IR.replace("init 3 0\n", "")).contains("counter"));
        assert!(rejection(&FIXTURE_IR.replace("init 3 0", "init 2 0")).contains("param var 2"));

        assert!(rejection(&FIXTURE_IR.replace("add 2 2 12", "add 2 2 30")).contains("undefined"));
        assert!(rejection(&FIXTURE_IR.replace("imm 5 3", "imm 300 3")).contains("out of range"));

        assert!(
            rejection(&FIXTURE_IR.replace("mul 6 4 5", "udivimm 6 4 0")).contains("divisor")
        );
        assert!(
            rejection(&FIXTURE_IR.replace("mul 6 4 5", "udivimm 6 4 -7")).contains("divisor")
        );
        assert!(
            rejection(&FIXTURE_IR.replace("mul 6 4 5", "udivimm 6 4 255")).contains("divisor")
        );
        assert!(
            rejection(&FIXTURE_IR.replace("mul 6 4 5", "udivimm 6 4 3")).contains("divisor")
        );
    }

    #[test]
    fn admits_power_of_two_udivimm() {
        let ir = FIXTURE_IR.replace("mul 6 4 5", "udivimm 6 4 8");
        assert!(parse_and_verify_fold(&ir).is_ok());
    }

    #[test]
    fn rejects_malformed_ir_and_extra_loops() {
        assert!(rejection(&format!("{FIXTURE_IR}loop 3 1 1\n")).contains("duplicate 'loop'"));
        assert!(rejection(&format!("{FIXTURE_IR}ret 2\n")).contains("duplicate 'ret'"));
        assert!(rejection(&format!("{FIXTURE_IR}kernel fused 3\n")).contains("duplicate 'kernel'"));

        assert!(rejection("kernel fused 2\ninit 3 0\nloop 3 1 1\nret 2\n").contains("3 params"));
        assert!(rejection(&FIXTURE_IR.replace("imm 5 3", "imm 5 x")).contains("bad integer"));
        assert!(rejection(&FIXTURE_IR.replace("addimm 7 6 7", "subimm 7 6 -9223372036854775808"))
            .contains("i64::MIN"));
        assert!(rejection(&FIXTURE_IR.replace("mul 6 4 5", "frob 6 4 5")).contains("unknown opcode"));
        assert!(rejection(&FIXTURE_IR.replace("ret 2\n", "")).contains("exactly one 'ret'"));
        assert!(rejection("init 3 0\nloop 3 1 1\nret 2\n").contains("exactly one 'kernel'"));
    }

    #[test]
    fn frame_length_gate_is_exact() {
        assert!(frame_len_check(0).is_err());
        assert!(frame_len_check(7).is_err());
        assert!(frame_len_check(8).is_ok());
        assert!(frame_len_check(8 + 1).is_ok());
        assert!(frame_len_check(FOLD_MAX_PAYLOAD).is_ok());
        assert!(frame_len_check(FOLD_MAX_PAYLOAD + 1).is_err());
    }

    #[test]
    fn framing_is_packet4_big_endian() {
        let mut out = Vec::new();
        write_frame(&mut out, b"READY").unwrap();
        assert_eq!(out, vec![0, 0, 0, 5, b'R', b'E', b'A', b'D', b'Y']);

        let mut out = Vec::new();
        let payload: Vec<u8> = (0..16u8).collect();
        write_frame(&mut out, &payload).unwrap();
        assert_eq!(&out[..4], &[0, 0, 0, 16]);
        assert_eq!(&out[4..], &payload[..]);
    }

    #[test]
    fn read_exact_eof_distinguishes_clean_from_truncated() {
        let mut c = Cursor::new(vec![1u8, 2, 3, 4]);
        let mut b = [0u8; 4];
        assert!(matches!(read_exact_eof(&mut c, &mut b), Ok(true)));
        assert_eq!(b, [1, 2, 3, 4]);

        let mut c = Cursor::new(Vec::<u8>::new());
        let mut b = [0u8; 4];
        assert!(matches!(read_exact_eof(&mut c, &mut b), Ok(false)));

        let mut c = Cursor::new(vec![1u8, 2, 3]);
        let mut b = [0u8; 4];
        let e = read_exact_eof(&mut c, &mut b).unwrap_err();
        assert!(e.contains("truncated"), "{e}");
    }

    // ── the reusable resource: auto traits, lifetime, caps ───────────────

    #[test]
    fn compiled_fold_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<CompiledFold>();
    }

    #[test]
    fn create_invoke_drop_roundtrips_and_reclaims() {
        // Repeated create → invoke → drop exercises the explicit `free_memory`
        // on the JIT module. A leaked, double-freed or dangling mapping would
        // fault or exhaust address space well before this many iterations.
        let buf: Vec<u8> = (0..=255u8).collect();
        for _ in 0..64 {
            let fold = CompiledFold::compile(FIXTURE_IR).expect("compile");
            assert_eq!(fold.run(&buf, 7).unwrap(), fold_ref(&buf, 7));
        }
    }

    #[test]
    fn run_rejects_buffers_over_cap() {
        let fold = CompiledFold::compile(FIXTURE_IR).unwrap();
        assert!(fold.run(&[], 0).is_ok());
        assert!(fold.run(&vec![0u8; FOLD_MAX_BUF], 0).is_ok());
        let over = vec![0u8; FOLD_MAX_BUF + 1];
        let e = fold.run(&over, 0).err().expect("over-cap buffer must be rejected");
        assert!(e.contains("cap"), "{e}");
        // The public cap constant is what the caller-side 4 KiB NIF policy
        // compares against; keep it visible and exact.
        assert_eq!(CompiledFold::MAX_BUF, FOLD_MAX_BUF);
    }

    #[test]
    fn compile_rejects_oversized_ir() {
        let mut big = String::from(FIXTURE_IR);
        while big.len() <= FOLD_MAX_IR {
            big.push_str("# padding padding padding padding padding padding\n");
        }
        let e = CompiledFold::compile(&big).err().expect("oversized IR must be rejected");
        assert!(e.contains("cap"), "{e}");
    }

    #[test]
    fn compile_rejects_too_many_statements() {
        let mut ir = String::from("kernel fused 3\ninit 3 0\n");
        for _ in 0..=FOLD_MAX_STMS {
            ir.push_str("mov 4 4\n");
        }
        ir.push_str("loop 3 1 1\nret 2\n");
        let e = CompiledFold::compile(&ir).err().expect("over-cap body must be rejected");
        assert!(e.contains("statements"), "{e}");
    }

    #[test]
    fn compile_rejects_malformed_ir() {
        // `CompiledFold::compile` is the sidecar/NIF entry, so the verifier's
        // rejections must surface there and not only in `parse_and_verify_fold`.
        let bad = format!("{FIXTURE_IR}store 0 3 12\n");
        let e = CompiledFold::compile(&bad).err().expect("malformed IR must be rejected");
        assert!(e.contains("allowlist"), "{e}");
    }
}
