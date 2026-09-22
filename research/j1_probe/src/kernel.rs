//! The bl-ANF-shaped fragment IR and its Cranelift lowering.
//!
//! Extracted from the former `main.rs` monolith so every path shares one
//! compiler. The legacy CLI modes (`--run-ir`, `--serve-store`, the benchmark
//! default) call `compile` here directly, and `fold::CompiledFold` calls this
//! same `compile` — there is no second lowering path.
//!
//! Nothing here is BL-facing: the public surface for the fold is
//! `fold::CompiledFold` (strings, byte slices, `u64`). `compile` returns the raw
//! code address only because the legacy CLI modes adapt it themselves.

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

// ── the bl-ANF-shaped fragment IR ────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Var(pub usize);

/// Straight-line statements over I64 scalars. Dynamic offsets are explicit
/// (base + off var), exactly as bl-ANF names every intermediate.
#[derive(Clone)]
pub enum Stm {
    Imm { dst: Var, k: i64 },
    Add { dst: Var, a: Var, b: Var },
    Sub { dst: Var, a: Var, b: Var },
    Mul { dst: Var, a: Var, b: Var },
    AddImm { dst: Var, a: Var, k: i64 },
    /// dst = zext(load.i8 base + off)
    LoadU8 { dst: Var, base: Var, off: Var },
    Mov { dst: Var, a: Var },
    Zext8 { dst: Var, a: Var },
    UdivImm { dst: Var, a: Var, k: i64 },
    /// dst = (a <  b) ? 1 : 0   (signed)
    Lt { dst: Var, a: Var, b: Var },
    /// dst = (a <= b) ? 1 : 0   (signed)
    Le { dst: Var, a: Var, b: Var },
    /// dst = (a == b) ? 1 : 0
    Eq { dst: Var, a: Var, b: Var },
    /// dst = (c != 0) ? a : b   (BRANCHLESS select — both a,b already computed)
    Sel { dst: Var, c: Var, a: Var, b: Var },
    /// store.i8 base + off <- v
    StoreU8 { base: Var, off: Var, v: Var },
}

/// One counted loop: while i < limit { body; i += step }. Returns ret.
/// This is the only control shape the fragment admits (proven measure).
pub struct Kernel {
    pub name: String,
    pub n_params: usize,
    pub inits: Vec<(Var, i64)>, // non-param vars initialized before the loop
    pub i: Var,
    pub limit: Var,
    pub step: i64,
    pub body: Vec<Stm>,
    pub ret: Var,
}

// ── lowering: IR → cranelift → machine code ─────────────────────────────

pub fn module_new() -> JITModule {
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

pub fn compile(k: &Kernel) -> (JITModule, usize) {
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
            Stm::Add { dst, a, b } | Stm::Sub { dst, a, b } | Stm::Mul { dst, a, b }
            | Stm::Lt { dst, a, b } | Stm::Le { dst, a, b } | Stm::Eq { dst, a, b } => vs.extend([dst.0, a.0, b.0]),
            Stm::Sel { dst, c, a, b } => vs.extend([dst.0, c.0, a.0, b.0]),
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
            Stm::Sub { dst, a, b } => {
                let x = bcx.use_var(var(a.0));
                let y = bcx.use_var(var(b.0));
                let v = bcx.ins().isub(x, y);
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
                // zext8 = keep the low byte, zero-extended to i64. A same-width
                // `uextend(I64, I64)` is not a valid cranelift instruction, so
                // the honest lowering is a 0xff mask — this is the `mod 256`
                // step of the shared fold.
                let x = bcx.use_var(var(a.0));
                let v = bcx.ins().band_imm(x, 0xff);
                bcx.def_var(var(dst.0), v);
            }
            Stm::UdivImm { dst, a, k: c } => {
                let x = bcx.use_var(var(a.0));
                // strength reduction the way LLVM/rustc do it: for u16-range x,
                // x/255 == (x * 0x8081) >> 23. cranelift will NOT do this itself.
                // Unsigned divide by a CONSTANT, without a hardware divide.
                // Values here are pixel-range (< 2^32), so a 64-bit multiply by
                // a precomputed magic number + shift is exact and ~10x faster
                // than `udiv`. This is what LLVM/GCC do; cranelift does not.
                let v = if c > 0 && (c & (c - 1)) == 0 {
                    // power of two → shift right by log2(c)
                    bcx.ins().ushr_imm(x, c.trailing_zeros() as i64)
                } else if c > 0 {
                    // magic: for 0 <= x < 2^32 and divisor d, floor(x/d) =
                    // (x * m) >> (32 + s) with m,s from the round-up method.
                    // We compute in u64 (x < 2^32 so x*m < 2^64).
                    let d = c as u64;
                    let mut s = 0u32;
                    while (1u64 << s) < d { s += 1; }            // s = ceil(log2(d))
                    // m = ceil(2^(32+s) / d), fits in u64 for d in pixel range
                    let m = (((1u128 << (32 + s)) + (d as u128) - 1) / (d as u128)) as u64;
                    let mv = bcx.ins().iconst(I64, m as i64);
                    let prod = bcx.ins().imul(x, mv);
                    bcx.ins().ushr_imm(prod, (32 + s) as i64)
                } else {
                    bcx.ins().udiv_imm(x, c)
                };
                bcx.def_var(var(dst.0), v);
            }
            Stm::Lt { dst, a, b } => {
                let x = bcx.use_var(var(a.0));
                let y = bcx.use_var(var(b.0));
                let c = bcx.ins().icmp(cranelift_codegen::ir::condcodes::IntCC::SignedLessThan, x, y);
                let v = bcx.ins().uextend(I64, c);
                bcx.def_var(var(dst.0), v);
            }
            Stm::Le { dst, a, b } => {
                let x = bcx.use_var(var(a.0));
                let y = bcx.use_var(var(b.0));
                let c = bcx.ins().icmp(cranelift_codegen::ir::condcodes::IntCC::SignedLessThanOrEqual, x, y);
                let v = bcx.ins().uextend(I64, c);
                bcx.def_var(var(dst.0), v);
            }
            Stm::Eq { dst, a, b } => {
                let x = bcx.use_var(var(a.0));
                let y = bcx.use_var(var(b.0));
                let c = bcx.ins().icmp(cranelift_codegen::ir::condcodes::IntCC::Equal, x, y);
                let v = bcx.ins().uextend(I64, c);
                bcx.def_var(var(dst.0), v);
            }
            Stm::Sel { dst, c, a, b } => {
                // BRANCHLESS: both arms are already-computed values; pick by c!=0.
                let cv = bcx.use_var(var(c.0));
                let zero = bcx.ins().iconst(I64, 0);
                let cond = bcx.ins().icmp(cranelift_codegen::ir::condcodes::IntCC::NotEqual, cv, zero);
                let x = bcx.use_var(var(a.0));
                let y = bcx.use_var(var(b.0));
                let v = bcx.ins().select(cond, x, y);
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
        .declare_function(&k.name, Linkage::Export, &ctx.func.signature)
        .unwrap();
    module.define_function(fid, &mut ctx).unwrap();
    module.finalize_definitions().unwrap();
    let code = module.get_finalized_function(fid);
    (module, code as usize)
}


// ── text-IR parsing (the lowerer's output format) ───────────────────────

pub fn parse_ir(text: &str) -> Option<Kernel> {
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
            "sub" => body.push(Stm::Sub { dst: Var(v(t[1])), a: Var(v(t[2])), b: Var(v(t[3])) }),
            "mul" => body.push(Stm::Mul { dst: Var(v(t[1])), a: Var(v(t[2])), b: Var(v(t[3])) }),
            "addimm" => body.push(Stm::AddImm { dst: Var(v(t[1])), a: Var(v(t[2])), k: k(t[3]) }),
            "load" => body.push(Stm::LoadU8 { dst: Var(v(t[1])), base: Var(v(t[2])), off: Var(v(t[3])) }),
            "lt" => body.push(Stm::Lt { dst: Var(v(t[1])), a: Var(v(t[2])), b: Var(v(t[3])) }),
            "le" => body.push(Stm::Le { dst: Var(v(t[1])), a: Var(v(t[2])), b: Var(v(t[3])) }),
            "eq" => body.push(Stm::Eq { dst: Var(v(t[1])), a: Var(v(t[2])), b: Var(v(t[3])) }),
            "sel" => body.push(Stm::Sel { dst: Var(v(t[1])), c: Var(v(t[2])), a: Var(v(t[3])), b: Var(v(t[4])) }),
            "store" => body.push(Stm::StoreU8 { base: Var(v(t[1])), off: Var(v(t[2])), v: Var(v(t[3])) }),
            "udivimm" => body.push(Stm::UdivImm { dst: Var(v(t[1])), a: Var(v(t[2])), k: k(t[3]) }),
            "subimm" => body.push(Stm::AddImm { dst: Var(v(t[1])), a: Var(v(t[2])), k: -k(t[3]) }),
            "zext" => body.push(Stm::Zext8 { dst: Var(v(t[1])), a: Var(v(t[2])) }),
            "mov" => body.push(Stm::Mov { dst: Var(v(t[1])), a: Var(v(t[2])) }),
            "loop" => { i = Var(v(t[1])); limit = Var(v(t[2])); step = k(t[3]); }
            "ret" => ret = Var(v(t[1])),
            _ => {}
        }
    }
    if name.is_empty() { return None; }
    Some(Kernel { name, n_params, inits, i, limit, step, body, ret })
}
