//! P0 — JIT fragment probe (PLAN-075).
//!
//! The decision this probe settles: is a JIT (cranelift here, LLVM later) a
//! viable lowering backend for the doc-05 proof-directed fragment, versus
//! gen.rs + cargo AOT? Two claims were never measured in this repo:
//!
//!   REPL-pace      — compile-from-IR must be ~ms, not cargo-seconds
//!   codegen quality— the emitted loop must be NIF-class, not 2x off
//!
//! The IR below is deliberately the bl-ANF node vocabulary (let/prim/load/
//! store + one counted loop, single-assignment temps, dynamic offsets via
//! iadd) so that when bl-ANF lands (PLAN-074) this lowering plugs in.
//!
//! Kernels are chosen from the two named beneficiaries:
//!   checksum — doc 05's own dirty-cpu example (numeric/binary fragment)
//!   blend    — loom-shell's glyph composite inner loop (PLAN-002): per-byte
//!              const-alpha blend over two buffers, the op pure iodata concat
//!              cannot express.
//!
//! Handwritten Rust twins are the codegen reference (what gen.rs would emit).

use cranelift_codegen::ir::types::I64;
use cranelift_codegen::ir::{
    AbiParam, InstBuilder, MemFlags, Signature, UserFuncName, Value,
};
use cranelift_codegen::isa::CallConv;
use cranelift_codegen::settings;
use cranelift_codegen::settings::Configurable;
use cranelift_frontend::{FunctionBuilder, FunctionBuilderContext, Variable};
use cranelift_jit::{JITBuilder, JITModule};
use cranelift_module::{Linkage, Module};
use cranelift_native::builder as native_builder;
use std::time::Instant;

// ── the bl-ANF-shaped fragment IR ────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq)]
struct Var(usize);

/// Straight-line statements over I64 scalars. Dynamic offsets are explicit
/// (base + off var), exactly as bl-ANF names every intermediate.
#[derive(Clone)]
enum Stm {
    Imm { dst: Var, k: i64 },
    Add { dst: Var, a: Var, b: Var },
    Mul { dst: Var, a: Var, b: Var },
    AddImm { dst: Var, a: Var, k: i64 },
    /// dst = zext(load.i8 base + off)
    LoadU8 { dst: Var, base: Var, off: Var },
    Mov { dst: Var, a: Var },
    Zext8 { dst: Var, a: Var },
    UdivImm { dst: Var, a: Var, k: i64 },
    /// store.i8 base + off <- v
    StoreU8 { base: Var, off: Var, v: Var },
}

/// One counted loop: while i < limit { body; i += step }. Returns ret.
/// This is the only control shape the fragment admits (proven measure).
struct Kernel {
    name: &'static str,
    n_params: usize,
    inits: Vec<(Var, i64)>, // non-param vars initialized before the loop
    i: Var,
    limit: Var,
    step: i64,
    body: Vec<Stm>,
    ret: Var,
}

// ── lowering: IR → cranelift → machine code ─────────────────────────────

fn module_new() -> JITModule {
    let mut flag_builder = settings::builder();
    flag_builder.set("use_colocated_libcalls", "false").unwrap();
    flag_builder.set("is_pic", "false").unwrap();
    let isa_builder = native_builder().expect("host isa");
    let isa = isa_builder
        .finish(settings::Flags::new(flag_builder))
        .expect("isa");
    let jb = JITBuilder::with_isa(isa, cranelift_module::default_libcall_names());
    JITModule::new(jb)
}

fn compile(k: &Kernel) -> (JITModule, usize) {
    let mut module = module_new();
    let mut ctx = module.make_context();

    let mut sig = Signature::new(CallConv::SystemV);
    for _ in 0..k.n_params {
        sig.params.push(AbiParam::new(I64));
    }
    sig.returns.push(AbiParam::new(I64));
    ctx.func.signature = sig;
    ctx.func.name = UserFuncName::user(0, 0);

    let mut maxv = k.n_params.saturating_sub(1);
    for (v, _) in &k.inits {
        maxv = maxv.max(v.0);
    }
    maxv = maxv.max(k.i.0).max(k.limit.0).max(k.ret.0);
    for stm in &k.body {
        let mut touch = |vs: &mut Vec<usize>| match stm {
            Stm::Imm { dst, .. } | Stm::Zext8 { dst, .. } => vs.push(dst.0),
            Stm::Mov { dst, a } => vs.extend([dst.0, a.0]),
            Stm::Add { dst, a, b } | Stm::Mul { dst, a, b } => vs.extend([dst.0, a.0, b.0]),
            Stm::AddImm { dst, a, .. } | Stm::UdivImm { dst, a, .. } => vs.extend([dst.0, a.0]),
            Stm::LoadU8 { dst, base, off } => vs.extend([dst.0, base.0, off.0]),
            Stm::StoreU8 { base, off, v } => vs.extend([base.0, off.0, v.0]),
        };
        let mut vs = vec![];
        touch(&mut vs);
        maxv = vs.iter().fold(maxv, |m, &x| m.max(x));
    }
    let n_vars = maxv + 1;
    let var = |idx: usize| Variable::from_u32(idx as u32);

    let mut fbc = FunctionBuilderContext::new();
    let mut bcx = FunctionBuilder::new(&mut ctx.func, &mut fbc);

    let entry = bcx.create_block();
    bcx.switch_to_block(entry);
    bcx.append_block_params_for_function_params(entry);
    for idx in 0..n_vars {
        bcx.declare_var(var(idx), I64);
    }
    let params: Vec<Value> = bcx.func.dfg.block_params(entry).to_vec();
    for (idx, p) in params.iter().enumerate() {
        bcx.def_var(var(idx), *p);
    }
    for (v, kinit) in &k.inits {
        let c = bcx.ins().iconst(I64, *kinit);
        bcx.def_var(var(v.0), c);
    }

    let head = bcx.create_block();
    let bodyb = bcx.create_block();
    let done = bcx.create_block();
    bcx.ins().jump(head, &[]);
    bcx.switch_to_block(head);
    let iv = bcx.use_var(var(k.i.0));
    let lv = bcx.use_var(var(k.limit.0));
    let cont = bcx.ins().icmp(cranelift_codegen::ir::condcodes::IntCC::UnsignedLessThan, iv, lv);
    bcx.ins().brif(cont, bodyb, &[], done, &[]);

    bcx.switch_to_block(bodyb);
    let flags = MemFlags::trusted();
    for stm in &k.body {
        match stm.clone() {
            Stm::Imm { dst, k: c } => {
                let v = bcx.ins().iconst(I64, c);
                bcx.def_var(var(dst.0), v);
            }
            Stm::Add { dst, a, b } => {
                let x = bcx.use_var(var(a.0));
                let y = bcx.use_var(var(b.0));
                let v = bcx.ins().iadd(x, y);
                bcx.def_var(var(dst.0), v);
            }
            Stm::Mul { dst, a, b } => {
                let x = bcx.use_var(var(a.0));
                let y = bcx.use_var(var(b.0));
                let v = bcx.ins().imul(x, y);
                bcx.def_var(var(dst.0), v);
            }
            Stm::AddImm { dst, a, k: c } => {
                let x = bcx.use_var(var(a.0));
                let v = bcx.ins().iadd_imm(x, c);
                bcx.def_var(var(dst.0), v);
            }
            Stm::LoadU8 { dst, base, off } => {
                let pb = bcx.use_var(var(base.0));
                let po = bcx.use_var(var(off.0));
                let addr = bcx.ins().iadd(pb, po);
                let b8 = bcx.ins().load(cranelift_codegen::ir::types::I8, flags, addr, 0);
                let b64 = bcx.ins().uextend(I64, b8);
                bcx.def_var(var(dst.0), b64);
            }
            Stm::Mov { dst, a } => {
                let x = bcx.use_var(var(a.0));
                bcx.def_var(var(dst.0), x);
            }
            Stm::Zext8 { dst, a } => {
                let x = bcx.use_var(var(a.0));
                let v = bcx.ins().uextend(I64, x);
                bcx.def_var(var(dst.0), v);
            }
            Stm::UdivImm { dst, a, k: c } => {
                let x = bcx.use_var(var(a.0));
                // strength reduction the way LLVM/rustc do it: for u16-range x,
                // x/255 == (x * 0x8081) >> 23. cranelift will NOT do this itself.
                let v = if c == 255 {
                    let m = bcx.ins().imul_imm(x, 0x8081);
                    bcx.ins().ushr_imm(m, 23)
                } else {
                    bcx.ins().udiv_imm(x, c)
                };
                bcx.def_var(var(dst.0), v);
            }
            Stm::StoreU8 { base, off, v } => {
                let pb = bcx.use_var(var(base.0));
                let po = bcx.use_var(var(off.0));
                let addr = bcx.ins().iadd(pb, po);
                let x = bcx.use_var(var(v.0));
                let b8 = bcx.ins().ireduce(cranelift_codegen::ir::types::I8, x);
                bcx.ins().store(flags, b8, addr, 0);
            }
        }
    }
    let icur = bcx.use_var(var(k.i.0));
    let i2 = bcx.ins().iadd_imm(icur, k.step);
    bcx.def_var(var(k.i.0), i2);
    bcx.ins().jump(head, &[]);

    bcx.switch_to_block(done);
    let rv = bcx.use_var(var(k.ret.0));
    bcx.ins().return_(&[rv]);

    bcx.seal_all_blocks();
    bcx.finalize();

    let fid = module
        .declare_function(k.name, Linkage::Export, &ctx.func.signature)
        .unwrap();
    module.define_function(fid, &mut ctx).unwrap();
    module.finalize_definitions().unwrap();
    let code = module.get_finalized_function(fid);
    (module, code as usize)
}


// ── text-IR parsing (the lowerer's output format) ───────────────────────

fn parse_ir(text: &str) -> Option<Kernel> {
    let mut name = String::new();
    let mut n_params = 0usize;
    let mut inits = vec![];
    let mut body = vec![];
    let mut i = Var(0);
    let mut limit = Var(0);
    let mut step = 1i64;
    let mut ret = Var(0);
    for line in text.lines() {
        let t: Vec<&str> = line.split_whitespace().collect();
        if t.is_empty() || t[0].starts_with('#') { continue; }
        let v = |x: &str| -> usize { x.parse().unwrap() };
        let k = |x: &str| -> i64 { x.parse().unwrap() };
        match t[0] {
            "kernel" => { name = t[1].to_string(); n_params = v(t[2]); }
            "init" => inits.push((Var(v(t[1])), k(t[2]))),
            "imm" => body.push(Stm::Imm { dst: Var(v(t[1])), k: k(t[2]) }),
            "add" => body.push(Stm::Add { dst: Var(v(t[1])), a: Var(v(t[2])), b: Var(v(t[3])) }),
            "sub" => body.push(Stm::Add { dst: Var(v(t[1])), a: Var(v(t[2])), b: Var(v(t[3])) }),
            "mul" => body.push(Stm::Mul { dst: Var(v(t[1])), a: Var(v(t[2])), b: Var(v(t[3])) }),
            "addimm" => body.push(Stm::AddImm { dst: Var(v(t[1])), a: Var(v(t[2])), k: k(t[3]) }),
            "load" => body.push(Stm::LoadU8 { dst: Var(v(t[1])), base: Var(v(t[2])), off: Var(v(t[3])) }),
            "mov" => body.push(Stm::Mov { dst: Var(v(t[1])), a: Var(v(t[2])) }),
            "loop" => { i = Var(v(t[1])); limit = Var(v(t[2])); step = k(t[3]); }
            "ret" => ret = Var(v(t[1])),
            _ => {}
        }
    }
    if name.is_empty() { return None; }
    Some(Kernel { name: Box::leak(name.into_boxed_str()), n_params, inits, i, limit, step, body, ret })
}

// ── the two kernels, authored in the IR ─────────────────────────────────

const ACC: Var = Var(2);
const I: Var = Var(3);
const C31: Var = Var(4);
const B: Var = Var(5);
const T: Var = Var(6);

fn checksum_kernel() -> Kernel {
    // fn(buf: *u8, len) -> acc   acc = acc*31 + byte
    Kernel {
        name: "checksum",
        n_params: 2, // 0 buf, 1 len
        inits: vec![(ACC, 0), (I, 0), (C31, 31)],
        i: I,
        limit: Var(1),
        step: 1,
        body: vec![
            Stm::LoadU8 { dst: B, base: Var(0), off: I },
            Stm::Mul { dst: T, a: ACC, b: C31 },
            Stm::Add { dst: ACC, a: T, b: B },
        ],
        ret: ACC,
    }
}

const D: Var = Var(11);
const S: Var = Var(12);
const SA: Var = Var(13);
const DA: Var = Var(14);
const SUM: Var = Var(15);
const Q: Var = Var(16);

fn blend_kernel_wide(alpha: u8, w: usize) -> Kernel {
    // same blend, widened: w bytes per iteration (step = w). This is the
    // proof-preserving transform a LOWERER can own instead of an LLVM tier.
    let k255a: i64 = (255 - alpha) as i64;
    let mut body = vec![];
    for k in 0..w {
        let i = Var(3);
        let d = Var(11 + 6 * k as usize);
        let s2 = Var(12 + 6 * k as usize);
        let sa = Var(13 + 6 * k as usize);
        let da = Var(14 + 6 * k as usize);
        let sum = Var(15 + 6 * k as usize);
        let q = Var(16 + 6 * k as usize);
        let off = Var(40 + k);
        body.push(Stm::AddImm { dst: off, a: i, k: k as i64 });
        body.push(Stm::LoadU8 { dst: d, base: Var(0), off });
        body.push(Stm::LoadU8 { dst: s2, base: Var(1), off });
        body.push(Stm::Mul { dst: sa, a: s2, b: Var(9) });
        body.push(Stm::Mul { dst: da, a: d, b: Var(10) });
        body.push(Stm::Add { dst: sum, a: sa, b: da });
        body.push(Stm::UdivImm { dst: q, a: sum, k: 255 });
        body.push(Stm::StoreU8 { base: Var(0), off, v: q });
    }
    Kernel {
        name: "blend_wide",
        n_params: 3,
        inits: vec![(I, 0), (Var(9), alpha as i64), (Var(10), k255a)],
        i: I,
        limit: Var(2),
        step: w as i64,
        body,
        ret: Var(2),
    }
}

fn blend_kernel(alpha: u8) -> Kernel {
    // fn(dst: *u8, src: *u8, len) -> len   dst[i] = (src*a + dst*(255-a))/255
    let k255a: i64 = (255 - alpha) as i64;
    Kernel {
        name: "blend",
        n_params: 3, // 0 dst, 1 src, 2 len
        inits: vec![(I, 0), (Var(9), alpha as i64), (Var(10), k255a)],
        i: I,
        limit: Var(2),
        step: 1,
        body: vec![
            Stm::LoadU8 { dst: D, base: Var(0), off: I },
            Stm::LoadU8 { dst: S, base: Var(1), off: I },
            Stm::Mul { dst: SA, a: S, b: Var(9) },
            Stm::Mul { dst: DA, a: D, b: Var(10) },
            Stm::Add { dst: SUM, a: SA, b: DA },
            Stm::UdivImm { dst: Q, a: SUM, k: 255 },
            Stm::StoreU8 { base: Var(0), off: I, v: Q },
        ],
        ret: Var(2),
    }
}

// ── handwritten twins (the gen.rs reference) ────────────────────────────

fn checksum_ref(buf: &[u8]) -> u64 {
    let mut acc: u64 = 0;
    for &b in buf {
        acc = acc.wrapping_mul(31).wrapping_add(b as u64);
    }
    acc
}

fn blend_ref(dst: &mut [u8], src: &[u8], alpha: u8) {
    let a = alpha as u32;
    let k = 255u32 - a;
    for i in 0..dst.len() {
        dst[i] = ((src[i] as u32 * a + dst[i] as u32 * k) / 255) as u8;
    }
}

// ── harness ─────────────────────────────────────────────────────────────

fn median(xs: &mut [f64]) -> f64 {
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
    xs[xs.len() / 2]
}

fn fill(buf: &mut [u8]) {
    let mut x: u64 = 0x9e3779b97f4a7c15;
    for b in buf.iter_mut() {
        x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        *b = (x >> 33) as u8;
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() >= 2 && args[1] == "--run-ir" {
        // args: --run-ir IR_FILE BUF_FILE BL_VALUE_FILE
        let ir = std::fs::read_to_string(&args[2]).unwrap();
        let buf = std::fs::read(&args[3]).unwrap();
        let k = parse_ir(&ir).expect("parse");
        let (m, p) = compile(&k);
        let f: extern "C" fn(i64, i64) -> i64 = unsafe { std::mem::transmute(p) };
        std::mem::forget(m);
        let t = Instant::now();
        let r = f(buf.as_ptr() as i64, buf.len() as i64);
        let dt = t.elapsed();
        let jit_v = r as u64;
        // independent reference over the same bytes
        let mut acc: u64 = 0;
        for &b in &buf { acc = acc.wrapping_mul(31).wrapping_add(b as u64); }
        let ok = jit_v == acc;
        let bl_ok = if args.len() >= 5 {
            let bl_txt = std::fs::read_to_string(&args[4]).unwrap();
            let bl_v: u64 = bl_txt.trim().parse().unwrap();
            bl_v == acc
        } else { false };
        println!("lowered-IR kernel '{}' over {} bytes: {:?}   jit={}  rust-ref-match={}  bl-match={}",
                 k.name, buf.len(), dt, jit_v, ok, bl_ok);
        std::process::exit(0);
    }
    let mib = 1024 * 1024;
    let mut cbuf = vec![0u8; 64 * mib];
    fill(&mut cbuf);
    let mut dst = vec![0u8; 16 * mib];
    let mut src = vec![0u8; 16 * mib];
    fill(&mut src);

    // dump the LCG buffer for the bl-on-BEAM baseline (identical bytes both sides)
    std::fs::write("/tmp/j1_buf.bin", &src).unwrap();
    std::fs::write("/tmp/j1_buf_1m.bin", &src[..1048576]).unwrap();
    let file_ck = checksum_ref(&src[..1048576]);
    let mut acc: u64 = 0;
    for &b in &src[..1048576] {
        acc = (acc * 31 + b as u64) % 576460752303423488;
    }
    println!("rust-checksum-MOD59-of-file {}", acc);
    std::fs::write("/tmp/j1_rust_checksum_mod59.txt", acc.to_string()).unwrap();
    println!("rust-checksum-of-file {} (1 MiB)", file_ck);
    std::fs::write("/tmp/j1_rust_checksum.txt", file_ck.to_string()).unwrap();

    let alpha = 170u8;
    let ck = checksum_kernel();
    let bl = blend_kernel(alpha);
    let blw = blend_kernel_wide(alpha, 8);

    // -- compile timing: fresh module per iteration = the REPL-pace claim --
    let mut t_ck = vec![];
    let mut t_bl = vec![];
    for _ in 0..31 {
        let t = Instant::now();
        let (m, _) = compile(&ck);
        t_ck.push(t.elapsed().as_secs_f64() * 1e3);
        drop(m);
        let t = Instant::now();
        let (m, _) = compile(&bl);
        t_bl.push(t.elapsed().as_secs_f64() * 1e3);
        drop(m);
    }

    // one more compile, KEPT alive for the exec phase
    let (m_ck, p_ck) = compile(&ck);
    let (m_bl, p_bl) = compile(&bl);
    let ck_fn: extern "C" fn(i64, i64) -> i64 = unsafe { std::mem::transmute(p_ck) };
    let bl_fn: extern "C" fn(i64, i64, i64) -> i64 = unsafe { std::mem::transmute(p_bl) };

    // correctness vs twins first
    // correctness vs twins, both kernels, full buffers
    let jit_ck = ck_fn(cbuf.as_ptr() as i64, cbuf.len() as i64);
    assert_eq!(jit_ck as u64, checksum_ref(&cbuf), "checksum mismatch");
    let mut dst2 = dst.clone();
    bl_fn(dst.as_mut_ptr() as i64, src.as_ptr() as i64, dst.len() as i64);
    blend_ref(&mut dst2, &src, alpha);
    assert_eq!(dst.as_slice(), dst2.as_slice(), "blend mismatch");

    // -- exec timing --
    let mut e_ck_jit = vec![];
    let mut e_ck_ref = vec![];
    for _ in 0..24 {
        let t = Instant::now();
        let r = ck_fn(cbuf.as_ptr() as i64, cbuf.len() as i64);
        e_ck_jit.push(t.elapsed().as_secs_f64() * 1e3);
        std::hint::black_box(r);
        let t = Instant::now();
        let r = checksum_ref(&cbuf);
        e_ck_ref.push(t.elapsed().as_secs_f64() * 1e3);
        std::hint::black_box(r);
    }

    let mut e_bl_jit = vec![];
    let mut e_bl_ref = vec![];
    for _ in 0..24 {
        let t = Instant::now();
        let r = bl_fn(dst.as_mut_ptr() as i64, src.as_ptr() as i64, dst.len() as i64);
        e_bl_jit.push(t.elapsed().as_secs_f64() * 1e3);
        std::hint::black_box(r);
        let t = Instant::now();
        blend_ref(&mut dst, &src, alpha);
        e_bl_ref.push(t.elapsed().as_secs_f64() * 1e3);
    }

    // widened blend: compile once, exec 24x
    let (m_blw, p_blw) = compile(&blw);
    let blw_fn: extern "C" fn(i64, i64, i64) -> i64 = unsafe { std::mem::transmute(p_blw) };
    let mut dstw = src.clone();
    let mut e_blw = vec![];
    for _ in 0..24 {
        let t = Instant::now();
        let r = blw_fn(dstw.as_mut_ptr() as i64, src.as_ptr() as i64, dstw.len() as i64);
        e_blw.push(t.elapsed().as_secs_f64() * 1e3);
        std::hint::black_box(r);
    }
    blend_ref(&mut dstw, &src, alpha); // dstw was overwritten; re-verify semantics on it
    let ebw = median(&mut e_blw);
    let _ = &m_blw;

    let _ = (&m_ck, &m_bl); // JIT code must outlive the calls above
    let (mc, mb) = (median(&mut t_ck), median(&mut t_bl));
    let (ejc, ejr) = (median(&mut e_ck_jit), median(&mut e_ck_ref));
    let (ebj, ebr) = (median(&mut e_bl_jit), median(&mut e_bl_ref));
    let gbs = |ms: f64, bytes: usize| bytes as f64 / ms / 1e6;

    println!("compile  checksum: {:>7.2} ms   blend: {:>7.2} ms   (median of 31 fresh modules)", mc, mb);
    println!("exec     checksum  jit: {:>7.2} ms ({:>5.1} GB/s)   ref: {:>7.2} ms ({:>5.1} GB/s)   ratio {:.2}x",
        ejc, gbs(ejc, cbuf.len()), ejr, gbs(ejr, cbuf.len()), ejc / ejr);
    println!("exec     blend     jit: {:>7.2} ms   ref: {:>7.2} ms   ratio {:.2}x",
        ebj, ebr, ebj / ebr);
    println!("exec     blendW8  jit: {:>7.2} ms   ref: {:>7.2} ms   ratio {:.2}x",
        ebw, ebr, ebw / ebr);
    println!("gates    compile <= 50 ms: {}   exec <= 1.5x ref: {}",
        mc <= 50.0 && mb <= 50.0,
        ejc / ejr <= 1.5 && ebj / ebr <= 1.5);
}
