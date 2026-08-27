//! The BEAM boundary for the native Datalog spike.
//!
//! The wire encoding is deliberately flat integers so bl can build it with
//! ordinary vectors and the NIF decodes without cleverness:
//!
//!   rules  : list of {head, body} where an atom is {pred, terms} and a term
//!            is {0, slot} (variable) or {1, const} (constant).
//!   idb    : list of predicate ids.
//!   edb    : list of {pred, arity, flat_tuples} — flat_tuples is one flat
//!            i64 list, row-major.
//!   query  : the predicate id to return.
//!
//! Only what the spike needs: enough to run a whole program and hand back one
//! relation. This is NOT a general FFI — it is the measurement harness.

use crate::eval::{eval_naive, eval_seminaive, eval_delta};
use crate::ir::*;
use crate::magic;
use rustler::{Encoder, Env, NifResult, Term as T};

fn decode_term(t: T) -> NifResult<Term> {
    // {0, slot} | {1, const}
    let (tag, val): (i64, i64) = t.decode()?;
    Ok(if tag == 0 {
        Term::Var(val as u32)
    } else {
        Term::Const(val)
    })
}

fn decode_atom(t: T) -> NifResult<Atom> {
    let (pred, terms): (u32, Vec<T>) = t.decode()?;
    let terms = terms
        .into_iter()
        .map(decode_term)
        .collect::<NifResult<Vec<_>>>()?;
    Ok(Atom { pred, terms })
}

/// A body item on the wire is tagged:
///   {0, {pred, terms}}          an atom (a relation to join)
///   {1, op_code, [args], out}   a computed value (arithmetic / comparison)
fn decode_body_item(t: T) -> NifResult<BodyItem> {
    // peek the tag
    let tag: i64 = t.decode::<(i64, T)>().map(|(g, _)| g).or_else(|_| {
        t.decode::<(i64, i64, Vec<T>, T)>().map(|(g, _, _, _)| g)
    })?;
    if tag == 0 {
        let (_g, atom): (i64, T) = t.decode()?;
        Ok(BodyItem::Atom(decode_atom(atom)?))
    } else {
        let (_g, op_code, args, out): (i64, i64, Vec<T>, T) = t.decode()?;
        let op = crate::ir::Op::from_code(op_code)
            .ok_or_else(|| crate::err(format!("unknown computed op code {}", op_code)))?;
        let args = args
            .into_iter()
            .map(decode_term)
            .collect::<NifResult<Vec<_>>>()?;
        let out = decode_term(out)?;
        Ok(BodyItem::Computed(Computed { op, args, out }))
    }
}

fn decode_rule(t: T) -> NifResult<Rule> {
    let (head, body): (T, Vec<T>) = t.decode()?;
    let head = decode_atom(head)?;
    let body = body
        .into_iter()
        .map(decode_body_item)
        .collect::<NifResult<Vec<_>>>()?;
    // nvars = 1 + max variable slot mentioned, across head + all body items
    let mut nvars = 0u32;
    let mut note = |t: &Term| {
        if let Term::Var(v) = t {
            nvars = nvars.max(v + 1);
        }
    };
    for term in &head.terms {
        note(term);
    }
    for item in &body {
        match item {
            BodyItem::Atom(a) => {
                for term in &a.terms {
                    note(term);
                }
            }
            BodyItem::Computed(c) => {
                for term in &c.args {
                    note(term);
                }
                note(&c.out);
            }
        }
    }
    Ok(Rule { head, body, nvars })
}

fn decode_program(rules: Vec<T>, idb: Vec<u32>) -> NifResult<Program> {
    let rules = rules
        .into_iter()
        .map(decode_rule)
        .collect::<NifResult<Vec<_>>>()?;
    Ok(Program { rules, idb })
}

fn decode_edb(edb: Vec<T>) -> NifResult<Db> {
    let mut db = Db::default();
    for e in edb {
        let (pred, arity, flat): (u32, usize, Vec<i64>) = e.decode()?;
        let mut rel = Relation::new(arity);
        if arity > 0 {
            let n = flat.len() / arity;
            for i in 0..n {
                rel.insert(&flat[i * arity..(i + 1) * arity]);
            }
        }
        db.set(pred, rel);
    }
    Ok(db)
}

/// Encode a relation as `{arity, flat_tuples}`.
fn encode_relation<'a>(env: Env<'a>, rel: &Relation) -> T<'a> {
    (rel.arity, rel.data.clone()).encode(env)
}

/// `dl_eval(rules, idb, edb, query_pred, strategy)` → `{arity, flat}` for the
/// query predicate's relation. `strategy`: 0 = naive, 1 = semi-naive nested,
/// 2 = semi-naive indexed.
#[rustler::nif(schedule = "DirtyCpu")]
fn dl_eval<'a>(
    env: Env<'a>,
    rules: Vec<T<'a>>,
    idb: Vec<u32>,
    edb: Vec<T<'a>>,
    query_pred: u32,
    strategy: i64,
) -> NifResult<T<'a>> {
    let prog = decode_program(rules, idb)?;
    let edb = decode_edb(edb)?;
    let (db, _rounds) = match strategy {
        0 => eval_naive(&prog, &edb, false),
        2 => eval_seminaive(&prog, &edb, true),
        _ => eval_seminaive(&prog, &edb, false),
    };
    let empty = Relation::new(0);
    let rel = db.get(query_pred).unwrap_or(&empty);
    Ok(encode_relation(env, rel))
}

/// `dl_eval_magic(rules, idb, edb, query_pred, seed)` → magic-sets-rewritten
/// semi-naive evaluation, returning the query relation. The DEMAND path: only
/// facts relevant to `seed` (the bound first argument) are derived.
#[rustler::nif(schedule = "DirtyCpu")]
fn dl_eval_magic<'a>(
    env: Env<'a>,
    rules: Vec<T<'a>>,
    idb: Vec<u32>,
    edb: Vec<T<'a>>,
    query_pred: u32,
    seed: i64,
) -> NifResult<T<'a>> {
    let prog = decode_program(rules, idb)?;
    let mut edb = decode_edb(edb)?;
    let (rewritten, seed_db) = magic::transform(&prog, query_pred, seed);
    // merge the seed magic relation into the EDB
    for (p, r) in seed_db.rels {
        edb.set(p, r);
    }
    let (db, _rounds) = eval_seminaive(&rewritten, &edb, true);
    let empty = Relation::new(0);
    let rel = db.get(query_pred).unwrap_or(&empty);
    Ok(encode_relation(env, rel))
}

/// `dl_eval_incremental(rules, idb, edb, new_edb, query_pred)` → maintain the
/// fixpoint under new base facts. `edb` must already include `new_edb` (so
/// joins see the new facts); `new_edb` names just the delta. Returns the query
/// relation after maintenance. For the spike this recomputes the base state
/// then applies the delta pass, so the timing isolates the delta propagation.
#[rustler::nif(schedule = "DirtyCpu")]
fn dl_eval_incremental<'a>(
    env: Env<'a>,
    rules: Vec<T<'a>>,
    idb: Vec<u32>,
    edb_before: Vec<T<'a>>,
    new_edb: Vec<T<'a>>,
    query_pred: u32,
) -> NifResult<T<'a>> {
    let prog = decode_program(rules, idb)?;
    let edb_before = decode_edb(edb_before)?;
    let new_edb = decode_edb(new_edb)?;
    // materialise the "before" state, then merge new facts into the EDB and
    // maintain incrementally.
    let (state, _) = eval_seminaive(&prog, &edb_before, true);
    let mut edb_after = edb_before.clone();
    for (p, r) in &new_edb.rels {
        let dst = edb_after
            .rels
            .entry(*p)
            .or_insert_with(|| Relation::new(r.arity));
        for row in r.rows() {
            dst.insert(row);
        }
    }
    let (db, _rounds) = eval_delta(&prog, &edb_after, &state, &new_edb);
    let empty = Relation::new(0);
    let rel = db.get(query_pred).unwrap_or(&empty);
    Ok(encode_relation(env, rel))
}

#[rustler::nif]
fn __nif_loaded__() -> bool {
    true
}
