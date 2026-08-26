//! `datom_resolve` — read a datom index range and return TYPED COLUMNS.
//!
//! This is Fix A of PLAN-042. The datalog engine's inner loop is
//! *scan a key range → decode each value → drop retractions → project*. The
//! first three steps carry no query semantics and, on the durable (redb)
//! backend, are dominated by decoding the value slot. `store-redb` now stores
//! each datom's value as a PACKED TYPED RECORD (scheme C) instead of
//! `term_to_binary`, so this NIF decodes it by fixed offsets in Rust and builds
//! columns in one crossing — removing the ~40% per-datom ETF-decode tax the BEAM
//! used to pay.
//!
//! Layout it reads (must match `priv/datom/store-redb.bl` and
//! `priv/datom/value-codec.bl` EXACTLY — the golden-vector suite locks this):
//!
//!   value slot = [ TAG_DATOM(1) | e:8 LE i64 | tx:8 LE i64 | op:1
//!                  | a_len:2 LE | a_payload… | v_payload… ]
//!   a_payload / v_payload = [ lane(1) | body… ]     (value-codec lanes)
//!     LANE_LONG=1   8B LE i64
//!     LANE_BOOL=2   1B 0/1
//!     LANE_STR=3    raw UTF-8
//!     LANE_KEYWORD=4 raw UTF-8 (keyword string, incl namespace)
//!     LANE_FLOAT=5  8B LE IEEE-754
//!     LANE_ESC=255  term_to_binary bytes (handed back opaque)
//!
//! The NIF NEVER touches the sortable KEY (that codec stays in beam-lisp): the
//! caller passes the key range it already builds, and every field the engine
//! needs is in the value slot.

use crate::{err, DbHandle, DATOMS};
use redb::ReadableDatabase;
use rustler::{Binary, Encoder, Env, NifResult, OwnedBinary, ResourceArc, Term};
use std::collections::HashMap;
use std::io::Write;
use std::ops::Bound;

const TAG_DATOM: u8 = 1;

const LANE_LONG: u8 = 1;
const LANE_BOOL: u8 = 2;
const LANE_STR: u8 = 3;
const LANE_KEYWORD: u8 = 4;
const LANE_FLOAT: u8 = 5;
const LANE_ESC: u8 = 255;

mod ra {
    rustler::atoms! { long, boolean, string, keyword, float, esc }
}

/// A decoded value-codec payload, tagged so the BEAM side rebuilds the right
/// term. Fixed lanes decode fully; the ESC lane keeps its raw ETF bytes and is
/// reconstituted by `binary_to_term` on the BEAM (the NIF never interprets an
/// arbitrary term — datom's "any structure" promise, handed back whole).
enum Val {
    Long(i64),
    Bool(bool),
    Str(Vec<u8>),
    Keyword(Vec<u8>),
    Float(f64),
    Esc(Vec<u8>),
}

fn le_i64(b: &[u8]) -> i64 {
    let mut a = [0u8; 8];
    a.copy_from_slice(&b[..8]);
    i64::from_le_bytes(a)
}

/// Decode one value-codec payload (`[lane | body]`). Returns None on a malformed
/// lane so the scan can skip rather than abort — a single bad value must not
/// lose a whole query.
fn decode_payload(p: &[u8]) -> Option<Val> {
    let (&lane, body) = p.split_first()?;
    Some(match lane {
        LANE_LONG => Val::Long(le_i64(body)),
        LANE_BOOL => Val::Bool(body.first().copied().unwrap_or(0) == 1),
        LANE_STR => Val::Str(body.to_vec()),
        LANE_KEYWORD => Val::Keyword(body.to_vec()),
        LANE_FLOAT => {
            let mut a = [0u8; 8];
            a.copy_from_slice(&body[..8]);
            Val::Float(f64::from_le_bytes(a))
        }
        LANE_ESC => Val::Esc(body.to_vec()),
        _ => return None,
    })
}

/// One decoded datom's relevant fields. `a` is carried as its raw payload bytes
/// because callers of `resolve` scan a single attribute (AEVT/AVET) and don't
/// need it decoded per row — but we keep it to reconstruct identity for the
/// retraction filter, which keys on `[e, a-bytes, v-bytes]`.
struct Row {
    e: i64,
    tx: i64,
    op: bool,
    a_bytes: Vec<u8>,
    v_bytes: Vec<u8>,
    v: Val,
}

/// Parse a packed value slot. Returns None for a non-datom (TAG_OPAQUE) or a
/// malformed record.
fn parse_record(slot: &[u8]) -> Option<Row> {
    if slot.first().copied()? != TAG_DATOM {
        return None;
    }
    // [1 | e:8 | tx:8 | op:1 | a_len:2 | a_pay | v_pay]
    if slot.len() < 20 {
        return None;
    }
    let e = le_i64(&slot[1..9]);
    let tx = le_i64(&slot[9..17]);
    let op = slot[17] == 1;
    let a_len = (slot[18] as usize) | ((slot[19] as usize) << 8);
    let a_start = 20;
    let a_end = a_start + a_len;
    if slot.len() < a_end {
        return None;
    }
    let a_bytes = slot[a_start..a_end].to_vec();
    let v_bytes = slot[a_end..].to_vec();
    let v = decode_payload(&v_bytes)?;
    Some(Row {
        e,
        tx,
        op,
        a_bytes,
        v_bytes,
        v,
    })
}

fn to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> NifResult<Binary<'a>> {
    let mut owned = OwnedBinary::new(bytes.len()).ok_or_else(|| err("alloc"))?;
    owned.as_mut_slice().write_all(bytes).map_err(err)?;
    Ok(Binary::from_owned(owned, env))
}

/// Encode one decoded value as a BEAM term tagged with its lane, so the
/// beam-lisp side can rebuild the exact value (`{:long, i}`, `{:string, bin}`,
/// `{:keyword, bin}`, `{:esc, etf_bytes}` …). The ESC lane returns the raw ETF
/// bytes for `binary_to_term` on the BEAM.
fn encode_val<'a>(env: Env<'a>, v: &Val) -> NifResult<Term<'a>> {
    Ok(match v {
        Val::Long(i) => (ra::long(), i).encode(env),
        Val::Bool(b) => (ra::boolean(), b).encode(env),
        Val::Str(s) => (ra::string(), to_binary(env, s)?).encode(env),
        Val::Keyword(k) => (ra::keyword(), to_binary(env, k)?).encode(env),
        Val::Float(f) => (ra::float(), f).encode(env),
        Val::Esc(b) => (ra::esc(), to_binary(env, b)?).encode(env),
    })
}

/// `resolve(handle, lo, hi)` — scan the datom index range `[lo, hi]` inclusive,
/// decode each packed value record, apply the retraction filter in Rust, and
/// return three parallel columns: `{e_list, v_list, tx_list}`.
///
/// - `e_list`  : `[i64]`         entity ids
/// - `v_list`  : `[{lane, val}]` typed values (see `encode_val`)
/// - `tx_list` : `[i64]`         transaction ids
///
/// `a` is constant per scan (an AEVT/AVET range fixes one attribute), so it is
/// not returned. The retraction filter drops a datom whose `[e, a, v]` is later
/// retracted (a higher `tx` with `op = false`), matching `db/filter-datoms`.
#[rustler::nif(schedule = "DirtyIo")]
pub fn datom_resolve<'a>(
    env: Env<'a>,
    handle: ResourceArc<DbHandle>,
    lo: Option<Binary>,
    hi: Option<Binary>,
) -> NifResult<Term<'a>> {
    let db = handle.db.lock().map_err(err)?;
    let txn = db.begin_read().map_err(err)?;
    let table = txn.open_table(DATOMS).map_err(err)?;

    let lower = match &lo {
        Some(b) => Bound::Included(b.as_slice()),
        None => Bound::Unbounded,
    };
    let upper = match &hi {
        Some(b) => Bound::Included(b.as_slice()),
        None => Bound::Unbounded,
    };

    let iter = table.range::<&[u8]>((lower, upper)).map_err(err)?;

    // Collect decoded rows, then apply the retraction filter. The filter keys
    // on identity `[e, a_bytes, v_bytes]`: the latest op for a given fact wins;
    // if it is a retraction the fact is currently absent and drops.
    let mut rows: Vec<Row> = Vec::new();
    for entry in iter {
        let (_k, val) = entry.map_err(err)?;
        if let Some(row) = parse_record(val.value()) {
            rows.push(row);
        }
        // a non-datom slot (a counter) inside a datom range should not occur —
        // counter keys live outside every index prefix — so skipping is safe.
    }

    // Retraction filter: latest-tx op per identity decides presence.
    // key = (e, a_bytes, v_bytes) → (max_tx, op_at_max_tx)
    let mut latest: HashMap<(i64, Vec<u8>, Vec<u8>), (i64, bool)> = HashMap::new();
    for r in &rows {
        let key = (r.e, r.a_bytes.clone(), r.v_bytes.clone());
        match latest.get(&key) {
            Some(&(t, _)) if t >= r.tx => {}
            _ => {
                latest.insert(key, (r.tx, r.op));
            }
        }
    }

    let mut es: Vec<i64> = Vec::with_capacity(rows.len());
    let mut vs: Vec<Term<'a>> = Vec::with_capacity(rows.len());
    let mut txs: Vec<i64> = Vec::with_capacity(rows.len());
    // Emit each present fact once, at the row that carries its latest assertion.
    for r in &rows {
        let key = (r.e, r.a_bytes.clone(), r.v_bytes.clone());
        if let Some(&(t, op)) = latest.get(&key) {
            if op && t == r.tx {
                es.push(r.e);
                vs.push(encode_val(env, &r.v)?);
                txs.push(r.tx);
            }
        }
    }

    let e_term = es.encode(env);
    let v_term = vs.encode(env);
    let tx_term = txs.encode(env);
    Ok(rustler::types::tuple::make_tuple(
        env,
        &[e_term, v_term, tx_term],
    ))
}

