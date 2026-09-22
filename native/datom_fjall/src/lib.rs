//! datom_fjall — the storage port, in Rust, over fjall (an LSM engine).
//!
//! # A backend under a six-method protocol
//!
//! `datom.store/Store` is six methods over an ordered key/value space
//! (get, range, put, delete, cas, commit). This crate is the durable
//! substrate under it; the in-memory ETS and map stores are the others.
//! They are interchangeable — everything above L1 is written against the
//! protocol, never against a specific engine.
//!
//! # Why fjall specifically
//!
//! The datom log is APPEND-DOMINATED: a transaction writes each datom into
//! two-to-four index orderings, monotonically, and reads are ordered range
//! scans. That is the exact shape an LSM tree is built for — writes land in
//! a memtable and flush sequentially, range scans merge sorted runs. A
//! copy-on-write B-tree would instead pay page churn on every commit
//! (measured: ~13s to bulk-load the compiler's 11k-datom codebase graph);
//! fjall's LSM amortises the same writes through the memtable.
//!
//! # The one requirement that matters: atomic cross-index commit
//!
//! A datom present in EAVT but missing from AEVT is a CORRUPT database, not a
//! slow one. The four indexes share one keyspace (the index tag is the first
//! key byte — EAVT=1 AEVT=2 AVET=3 VAET=4), so an atomic commit is a single
//! atomic batch. fjall gives that via a keyspace-level `Batch`: every write in
//! the batch becomes durable together at `commit()`, or none does. `-commit`
//! delegates to that batch — the same all-or-nothing guarantee a write
//! transaction would give on a B-tree engine.
//!
//! # Durability
//!
//! Every commit is persisted (fjall persists the batch to the write-ahead log
//! before returning). A faster mode (defer the fsync) would be an explicit,
//! named choice, never a silent default.
//!
//! # The BEAM boundary
//!
//! Every operation touches a file, so every NIF runs on a DirtyIo scheduler.
//! The boundary is coarse — `commit` takes the whole batch, `range` returns
//! the whole window — so a transaction costs one BEAM↔Rust crossing.

use rustler::{Atom, Binary, Encoder, Env, Error, NifResult, OwnedBinary, Resource, ResourceArc, Term};
use rustler::types::map::map_new;
use std::io::Write;
use std::sync::Mutex;

use fjall::{Config, Keyspace, PartitionCreateOptions, PartitionHandle, PersistMode};

mod keycodec;
use keycodec::KeyVal;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        nil,
        put,
        delete,
        columns,
        datoms,
        pairs,
        // The boolean lane's decoded terms. The trailing underscore is a Rust
        // keyword accident, not part of the atom: without the alias rustler
        // stringifies the IDENTIFIER, so a stored `true` came back as `:true_`
        // — a keyword that is truthy, unequal to `true`, and unmatchable by a
        // bound query. Alias to the real atom names (the same form rustler's
        // own stdlib atoms use: `false_ = "false"`).
        true_ = "true",
        false_ = "false",
        // `fjall_stats` keys. The engine's own reporting surface: compaction,
        // flushing, journal and disk accounting, plus the block cache's
        // capacity. NONE of it was readable before this NIF, which is why
        // "the cache is too small" and "compaction has never been observed"
        // were inferences rather than measurements.
        cache_capacity,
        write_buffer,
        flushes_completed,
        active_compactions,
        compactions_completed,
        time_compacting_us,
        journal_count,
        journal_bytes,
        disk_bytes,
        partitions,
    }
}

/// A handle to an open keyspace + its single datom partition.
///
/// The `Mutex` is here for the reason any durable adapter needs it: a `-cas`
/// (read, compare, write) must not interleave with another writer between its
/// read and its write. fjall serialises its own writes, but the read in one
/// operation and the write in another could still straddle without this.
pub(crate) struct DbHandle {
    pub(crate) keyspace: Keyspace,
    pub(crate) datoms: PartitionHandle,
    pub(crate) lock: Mutex<()>,
}

#[rustler::resource_impl]
impl Resource for DbHandle {}

pub(crate) fn err(msg: impl std::fmt::Display) -> Error {
    Error::Term(Box::new(format!("{}", msg)))
}

fn to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> NifResult<Binary<'a>> {
    let mut owned = OwnedBinary::new(bytes.len())
        .ok_or_else(|| err("could not allocate a binary"))?;
    owned.as_mut_slice().write_all(bytes).map_err(|e| err(e))?;
    Ok(Binary::from_owned(owned, env))
}

/// Open (or create) a keyspace at `path`, with one partition "datoms".
///
/// An empty database and a missing partition are the same thing to every
/// caller above, so the partition is created eagerly: a read against a
/// brand-new database sees an empty partition, never a "no such partition".
#[rustler::nif(schedule = "DirtyIo")]
fn fjall_open<'a>(env: Env<'a>, path: String) -> NifResult<Term<'a>> {
    let keyspace = Config::new(&path).open().map_err(|e| err(e))?;
    let datoms = keyspace
        .open_partition("datoms", PartitionCreateOptions::default())
        .map_err(|e| err(e))?;
    let arc = ResourceArc::new(DbHandle {
        keyspace,
        datoms,
        lock: Mutex::new(()),
    });
    Ok(arc.encode(env))
}

/// `-get`: the value at `key`, or `nil`.
#[rustler::nif(schedule = "DirtyIo")]
fn fjall_get<'a>(env: Env<'a>, handle: ResourceArc<DbHandle>, key: Binary) -> NifResult<Term<'a>> {
    match handle.datoms.get(key.as_slice()).map_err(|e| err(e))? {
        Some(v) => Ok(to_binary(env, &v)?.to_term(env)),
        None => Ok(atoms::nil().to_term(env)),
    }
}

/// `-range`: every `[k v]` with `start <= k <= stop`, in key order.
///
/// **Bounds are INCLUSIVE on both sides** — the single easiest property to get
/// wrong, and silent when wrong (a half-open upper bound drops one datom from
/// the end of every scan). fjall's `range` takes a Rust range; we build an
/// inclusive `..=` when an upper bound is present, unbounded otherwise. A `nil`
/// bound (empty option) means unbounded on that side.
#[rustler::nif(schedule = "DirtyIo")]
fn fjall_range<'a>(
    env: Env<'a>,
    handle: ResourceArc<DbHandle>,
    start: Option<Binary>,
    stop: Option<Binary>,
) -> NifResult<Term<'a>> {
    use std::ops::Bound;
    let lower = match &start {
        Some(b) => Bound::Included(b.as_slice().to_vec()),
        None => Bound::Unbounded,
    };
    // Included, not Excluded — see the note above.
    let upper = match &stop {
        Some(b) => Bound::Included(b.as_slice().to_vec()),
        None => Bound::Unbounded,
    };

    let mut pairs: Vec<Term<'a>> = Vec::new();
    for entry in handle.datoms.range((lower, upper)) {
        let (k, v) = entry.map_err(|e| err(e))?;
        let kb = to_binary(env, &k)?;
        let vb = to_binary(env, &v)?;
        pairs.push(rustler::types::tuple::make_tuple(
            env,
            &[kb.to_term(env), vb.to_term(env)],
        ));
    }
    Ok(pairs.encode(env))
}

/// `fjall_range_chunk`: the NEXT `limit` `[k v]` pairs of a bounded scan.
///
/// `fjall_range` above returns the WHOLE window in one crossing. On a real
/// corpus that is 969 016 rows / 1.1 GB in one call (measured: 15.6 s), and
/// every fjall op runs on ONE dirty-IO scheduler (this host pins `+SDio 1:1`),
/// so a concurrent point get waits the ENTIRE scan — measured max 3421 ms
/// against a 0.05 ms median.
///
/// The scan is resumable instead of stateful: `start` (inclusive) bounds the
/// FIRST chunk, `after` (exclusive) the rest — the caller passes the last key
/// it received. Re-seeking per chunk costs microseconds against a 15 s scan,
/// and it buys two things the whole-window call cannot: the dirty-IO lane is
/// RELEASED between chunks (so other ops interleave instead of queueing), and
/// the transient the NIF materializes is bounded by `limit`, not by the table.
///
/// Bounds are INCLUSIVE on both sides for `start`/`stop`, as `fjall_range`
/// specifies; `after` is the exclusive resume point and wins over nothing —
/// pass either `start` (first chunk) or `after` (resume), never both.
#[rustler::nif(schedule = "DirtyIo")]
fn fjall_range_chunk<'a>(
    env: Env<'a>,
    handle: ResourceArc<DbHandle>,
    start: Option<Binary>,
    after: Option<Binary>,
    stop: Option<Binary>,
    limit: usize,
) -> NifResult<Term<'a>> {
    use std::ops::Bound;
    let lower = match (&start, &after) {
        (Some(b), _) => Bound::Included(b.as_slice().to_vec()),
        (None, Some(b)) => Bound::Excluded(b.as_slice().to_vec()),
        (None, None) => Bound::Unbounded,
    };
    let upper = match &stop {
        Some(b) => Bound::Included(b.as_slice().to_vec()),
        None => Bound::Unbounded,
    };

    let mut pairs: Vec<Term<'a>> = Vec::with_capacity(limit.min(4096));
    for entry in handle.datoms.range((lower, upper)).take(limit) {
        let (k, v) = entry.map_err(|e| err(e))?;
        let kb = to_binary(env, &k)?;
        let vb = to_binary(env, &v)?;
        pairs.push(rustler::types::tuple::make_tuple(
            env,
            &[kb.to_term(env), vb.to_term(env)],
        ));
    }
    Ok(pairs.encode(env))
}

// ══ the datom read path: one crossing, decoded natively ═════════════
//
// The storage slot (datom.value-codec, the "datom lane") packs a datom
// field-wise, so a reader recovers e/tx/op/a/v by OFFSET, with no ETF parse of
// a container and no per-field BEAM call. This module is that reader.
//
// It matters because of where the cost sits. Reading 969 016 rows through the
// port takes 8.57 s, of which only 2.48 s is fjall iteration: the rest is
// per-row work in the BEAM (`binary_to_term` of a 5-vector, a fresh vector per
// row, the range's [k v] pairs) — work that is thrown away whenever a filter
// rejects the row. A columnar read replaces it with a handful of bulk binaries.
//
// Two shapes, one decode loop:
//
//   datoms  — the same datoms the generic path returns, built here instead.
//             Drop-in for `scan-datoms`, and the win is simply that the parse
//             is a byte read in Rust rather than a BEAM term parse per row.
//
//   columns — the DENSE UNION layout a columnar engine uses for a
//             heterogeneous column: one lane tag per row plus a per-lane dense
//             array, and for variable-width lanes a shared offsets array beside
//             one bytes blob (Arrow's var-length layout). A caller can then
//             filter over columns — a text predicate becomes `binary.match`
//             over one blob — and materialize terms only for rows that survive.
//             The attribute column is dictionary-encoded, because in a range
//             scan `a` is nearly constant: an AEVT chunk carries ONE attribute
//             for its whole length.
//
// Rows written before the datom lane existed start with the ETF version byte.
// They are decoded with `binary_to_term` exactly as they always were (lane
// LEGACY), so a store upgrades lazily and a mixed keyspace reads correctly.

/// Lane tags, mirrored from `datom.value-codec`. Kept as plain constants so
/// this module and the bl codec can be read side by side.
const LANE_LONG: u8 = 1;
const LANE_BOOL: u8 = 2;
const LANE_STR: u8 = 3;
const LANE_KW: u8 = 4;
const LANE_FLOAT: u8 = 5;
const LANE_DATOM: u8 = 6;
const LANE_ESC: u8 = 255;
/// Not a codec lane: this crate's marker for a row still in the pre-lane
/// `term_to_binary` format. A caller that sees it decodes the whole value with
/// `binary_to_term` and takes element 2 — the old path, for old rows only.
const LANE_LEGACY: u8 = 254;
const ETF_VERSION: u8 = 131;

/// The five fields of one stored datom, borrowed from the row's bytes.
struct Row<'a> {
    e: i64,
    tx: i64,
    op: u8,
    a: &'a [u8],
    /// The `v` payload with its lane tag still on the front.
    v: &'a [u8],
    /// `Some(etf bytes)` for a row whose whole datom rode the any-term lane: a
    /// pre-lane (`term_to_binary`) value, or a value the datom lane could not
    /// pack (a bignum entity, an attribute name past 255 bytes). `v` is then
    /// meaningless and the bytes are the datom, ETF-encoded.
    legacy: Option<&'a [u8]>,
}

/// Read the datom payload at `val` into its fields by offset.
///
/// Every malformed shape is an ERROR naming the reason: a store that holds an
/// index range full of something other than datoms is a corrupted database, and
/// the one thing a reader must never do is invent a plausible datom for it.
fn read_row(val: &[u8]) -> Result<Row<'_>, Error> {
    if val.is_empty() {
        return Err(err("empty value in a datom index"));
    }
    if val[0] == ETF_VERSION {
        return Ok(Row { e: 0, tx: 0, op: 1, a: &[], v: &[], legacy: Some(val) });
    }
    if val[0] == LANE_ESC {
        // The slot's own escape lane: the datom did not fit the packed lane (a
        // bignum entity, an attribute name past 255 bytes), so the WRITER put
        // the whole datom in a term. This is not a defect to report — it is a
        // legal row, and a reader that refused it would break an entire scan
        // because one datom in it is unusual.
        return Ok(Row { e: 0, tx: 0, op: 1, a: &[], v: &[], legacy: Some(&val[1..]) });
    }
    if val[0] != LANE_DATOM {
        return Err(err(format!(
            "index row is not a datom payload (leading byte {}; expected {}, {} or {})",
            val[0], LANE_DATOM, LANE_ESC, ETF_VERSION
        )));
    }
    if val.len() < 19 {
        return Err(err(format!("datom payload truncated: {} bytes", val.len())));
    }
    let e = i64::from_le_bytes(val[1..9].try_into().unwrap());
    let tx = i64::from_le_bytes(val[9..17].try_into().unwrap());
    let a_len = val[18] as usize;
    if val.len() < 19 + a_len {
        return Err(err(format!(
            "datom payload truncated: attribute claims {} bytes, payload is {}",
            a_len,
            val.len()
        )));
    }
    Ok(Row {
        e,
        tx,
        op: val[17],
        a: &val[19..19 + a_len],
        v: &val[19 + a_len..],
        legacy: None,
    })
}

/// One stored value, decoded — the whole slot, not just a datom's `v`.
///
/// This is `datom.value-codec/decode-slot` executed in Rust. The port's generic
/// `-range` needs decoded values, and doing that decode in the BEAM made the port
/// FOUR TIMES SLOWER on packed values than on the ETF they replaced (measured on
/// 50 000 rows: 1964 ms against 479 ms) — because the packed payload is cheap
/// only when a compiled reader touches it. Decoding it here keeps every read
/// path's cost where it belongs, and keeps the regression off `-range` for any
/// caller that never touches datoms at all.
fn slot_term<'a>(env: Env<'a>, bytes: &[u8], shape: &VectorShape) -> NifResult<Term<'a>> {
    if bytes.is_empty() {
        return Err(err("empty value slot"));
    }
    match bytes[0] {
        ETF_VERSION => decode_stored(env, bytes, "stored value"),
        LANE_ESC => decode_stored(env, &bytes[1..], "escaped value"),
        LANE_DATOM => {
            let row = read_row(bytes)?;
            datom_term(env, &row, shape)
        }
        // A scalar slot: the same lanes a datom's `v` uses, with nothing in
        // front of them. The synthetic row carries no entity/attribute, which
        // `v_term` never reads for these lanes.
        _ => v_term(
            env,
            &Row { e: 0, tx: 0, op: 1, a: &[], v: bytes, legacy: None },
            shape,
        ),
    }
}

/// The shape of a bl VECTOR, resolved once per call.
///
/// A bl vector is the runtime's own struct: an Erlang map keyed by ATOMS
/// (`__struct__`, `items`, `meta`), and for 32 or fewer elements the elements
/// live in a plain tuple inside it. A NIF that hands back datoms must build
/// THAT, because an Erlang tuple is a near-miss — it prints like a vector, then
/// answers `get` with nil and `vector?` with false, so every reader above it
/// (the index accessors, the db filter) silently sees garbage. That failure is
/// a long way from its cause, which is why the shape is named once, here.
///
/// Datoms are 5 elements, well inside the tail, so the trie form never applies.
struct VectorShape {
    struct_value: Atom,
    struct_key: Atom,
    items: Atom,
    meta: Atom,
}

impl VectorShape {
    fn new(env: Env) -> NifResult<Self> {
        Ok(VectorShape {
            struct_value: Atom::from_str(env, "Elixir.BeamLisp.Vector")?,
            struct_key: Atom::from_str(env, "__struct__")?,
            items: Atom::from_str(env, "items")?,
            meta: Atom::from_str(env, "meta")?,
        })
    }

    fn vector<'a>(&self, env: Env<'a>, items: &[Term<'a>]) -> NifResult<Term<'a>> {
        let tup = rustler::types::tuple::make_tuple(env, items);
        Ok(map_new(env)
            .map_put(self.struct_key, self.struct_value)?
            .map_put(self.items, tup)?
            .map_put(self.meta, atoms::nil().to_term(env))?)
    }
}

/// Decode bytes this database wrote.
///
/// TRUSTED, deliberately. rustler's `binary_to_term` is the SAFE variant, which
/// refuses any binary carrying an atom that is not ALREADY in the atom table —
/// and on a fresh VM that is every attribute name in the store, so a legacy row
/// would fail to decode for a reason that has nothing to do with the row. The
/// BEAM's own `binary_to_term/1`, which the bl-side reader calls, interns atoms
/// exactly like this, so reading a store has always created its atoms: this is
/// parity with the existing path, not a new exposure. The bytes come from our
/// own value slot, under our own key space, written by our own writer.
fn decode_stored<'a>(env: Env<'a>, bytes: &[u8], what: &str) -> NifResult<Term<'a>> {
    unsafe { env.binary_to_term_trusted(bytes) }
        .map(|(term, _)| term)
        .ok_or_else(|| err(format!("{} did not decode", what)))
}

/// The five fields of a datom stored in the BEAM's own format.
///
/// A bl vector is NOT an Erlang tuple. For 32 or fewer elements it is the
/// runtime's struct — a map whose `items` key holds the elements — so a reader
/// that assumed a tuple would fail on EVERY row of a store written before the
/// packed lane existed, which is exactly the population a lazy upgrade must keep
/// serving. Both shapes are accepted here, and the tuple case is tried first
/// because it is the cheaper test.
fn datom_fields<'a>(env: Env<'a>, term: Term<'a>, shape: &VectorShape) -> NifResult<Vec<Term<'a>>> {
    if let Ok(items) = rustler::types::tuple::get_tuple(term) {
        return Ok(items.to_vec());
    }
    if let Ok(items) = term.map_get(shape.items) {
        if let Ok(elems) = rustler::types::tuple::get_tuple(items) {
            return Ok(elems.to_vec());
        }
    }
    let _ = env;
    Err(err("stored datom is neither a tuple nor a bl vector"))
}

/// The BEAM term for one row's `v`, chosen by its lane tag.
fn v_term<'a>(env: Env<'a>, row: &Row<'_>, shape: &VectorShape) -> NifResult<Term<'a>> {
    if let Some(whole) = row.legacy {
        // Pre-lane row: the value IS the datom, so recover `v` from it.
        let term = decode_stored(env, whole, "legacy datom value")?;
        let fields = datom_fields(env, term, shape)?;
        return fields
            .get(2)
            .copied()
            .ok_or_else(|| err("legacy datom value is not a 5-element datom"));
    }
    let v = row.v;
    match v.first() {
        Some(&LANE_LONG) if v.len() == 9 => {
            Ok(i64::from_le_bytes(v[1..9].try_into().unwrap()).encode(env))
        }
        Some(&LANE_BOOL) if v.len() == 2 => Ok(if v[1] == 1 {
            atoms::true_().to_term(env)
        } else {
            atoms::false_().to_term(env)
        }),
        Some(&LANE_FLOAT) if v.len() == 9 => {
            Ok(f64::from_le_bytes(v[1..9].try_into().unwrap()).encode(env))
        }
        Some(&LANE_STR) => Ok(to_binary(env, &v[1..])?.to_term(env)),
        Some(&LANE_KW) => Ok(Atom::from_bytes(env, &v[1..])?.to_term(env)),
        Some(&LANE_ESC) => {
            let term = decode_stored(env, &v[1..], "escaped value")?;
            Ok(term)
        }
        Some(&tag) => Err(err(format!(
            "unknown value lane {} (payload {} bytes)",
            tag,
            v.len()
        ))),
        None => Err(err("datom payload carries no value")),
    }
}

/// One row as the datom the index layer expects: `[e a v tx op]`.
fn datom_term<'a>(env: Env<'a>, row: &Row<'_>, shape: &VectorShape) -> NifResult<Term<'a>> {
    if row.legacy.is_some() {
        // Already a datom in the BEAM's own format: hand it back as-is.
        return decode_stored(env, row.legacy.unwrap(), "legacy datom value");
    }
    let a = Atom::from_bytes(env, row.a)?;
    let v = v_term(env, row, shape)?;
    shape.vector(
        env,
        &[
            row.e.encode(env),
            a.to_term(env),
            v,
            row.tx.encode(env),
            (row.op == 1).encode(env),
        ],
    )
}

/// The columnar form of a chunk: dense per-lane arrays + a lane tag per row.
///
/// The layout is deliberately index-addressable — `v_idx[i]` says where row i's
/// value lives, in its lane's dense array or in the shared variable-width
/// area — because late materialization picks rows out of order, and a layout
/// that only streams would force a full pass to reach row 900 000.
#[derive(Default)]
struct Columns {
    n: usize,
    e: Vec<u8>,
    tx: Vec<u8>,
    op: Vec<u8>,
    a_idx: Vec<u8>,
    a_dict: Vec<Vec<u8>>,
    v_lane: Vec<u8>,
    v_idx: Vec<u8>,
    v_long: Vec<u8>,
    v_bool: Vec<u8>,
    v_double: Vec<u8>,
    v_var_off: Vec<u8>,
    v_var: Vec<u8>,
}

impl Columns {
    fn new() -> Self {
        let mut c = Columns::default();
        // offsets[0] = 0, so row j of the variable area is off[j]..off[j+1]
        // without a special case for the first row.
        c.v_var_off.extend_from_slice(&0u32.to_le_bytes());
        c
    }

    fn push_var(&mut self, lane: u8, bytes: &[u8]) -> u32 {
        let ordinal = (self.v_var_off.len() / 4 - 1) as u32;
        self.v_var.extend_from_slice(bytes);
        self.v_var_off
            .extend_from_slice(&(self.v_var.len() as u32).to_le_bytes());
        self.v_lane.push(lane);
        ordinal
    }

    fn push(&mut self, env: Env, row: &Row<'_>, shape: &VectorShape) -> NifResult<()> {
        // NOTE: `push` is the only place a row's bytes become columns, so it is
        // also the only place the LEGACY/ESC distinction has to be resolved.
        self.e.extend_from_slice(&row.e.to_le_bytes());
        self.tx.extend_from_slice(&row.tx.to_le_bytes());
        self.op.push(row.op);

        // Dictionary-encode the attribute: in a range scan it is close to
        // constant (an AEVT chunk has exactly one value here), so a linear
        // scan over a tiny dictionary is both correct and the cheapest thing
        // to do — no hashing, no ordering, and the dictionary keeps the first
        // -seen order, which is the scan's own order.
        let idx = match self.a_dict.iter().position(|d| d.as_slice() == row.a) {
            Some(i) => i,
            None => {
                self.a_dict.push(row.a.to_vec());
                self.a_dict.len() - 1
            }
        };
        if idx > u16::MAX as usize {
            return Err(err("more distinct attributes in one chunk than a u16 holds"));
        }
        self.a_idx.extend_from_slice(&(idx as u16).to_le_bytes());

        if let Some(whole) = row.legacy {
            // A pre-lane (or unpackable) row: pull `v` out of the stored datom
            // and re-emit it as an ESC payload. The columnar reader's callers
            // then never see a legacy lane at all — one code path above, and no
            // migration step before a store can be read columnar.
            let term = decode_stored(env, whole, "legacy datom value")?;
            let fields = datom_fields(env, term, shape)?;
            let v = fields
                .get(2)
                .ok_or_else(|| err("legacy datom value is not a 5-element datom"))?;
            let etf = v.to_binary();
            let ordinal = self.push_var(LANE_ESC, etf.as_slice());
            self.v_idx.extend_from_slice(&ordinal.to_le_bytes());
            self.n += 1;
            return Ok(());
        }

        let v = row.v;
        let idx = match v.first() {
            Some(&LANE_LONG) if v.len() == 9 => {
                let i = (self.v_long.len() / 8) as u32;
                self.v_long.extend_from_slice(&v[1..9]);
                self.v_lane.push(LANE_LONG);
                Some(i)
            }
            Some(&LANE_BOOL) if v.len() == 2 => {
                let i = self.v_bool.len() as u32;
                self.v_bool.push(v[1]);
                self.v_lane.push(LANE_BOOL);
                Some(i)
            }
            Some(&LANE_FLOAT) if v.len() == 9 => {
                let i = (self.v_double.len() / 8) as u32;
                self.v_double.extend_from_slice(&v[1..9]);
                self.v_lane.push(LANE_FLOAT);
                Some(i)
            }
            Some(&LANE_STR) => Some(self.push_var(LANE_STR, &v[1..])),
            Some(&LANE_KW) => Some(self.push_var(LANE_KW, &v[1..])),
            Some(&LANE_ESC) => Some(self.push_var(LANE_ESC, &v[1..])),
            Some(&tag) => {
                return Err(err(format!(
                    "unknown value lane {} (payload {} bytes)",
                    tag,
                    v.len()
                )))
            }
            None => return Err(err("datom payload carries no value")),
        };
        if let Some(i) = idx {
            self.v_idx.extend_from_slice(&i.to_le_bytes());
        }
        self.n += 1;
        Ok(())
    }
}

/// `fjall_resolve_chunk`: up to `limit` datoms from a bounded scan, decoded in
/// Rust, in the shape `mode` asks for.
///
/// `mode` is `:datoms` (a list under `"datoms"`) or `:columns` (the dense-union
/// columns). Both return `"n"` and `"last"` — the last key read, which the
/// caller passes back as `after` to resume, exactly as `fjall_range_chunk`
/// specifies. The bounds are the same three options, with the same meanings.
#[rustler::nif(schedule = "DirtyIo")]
fn fjall_resolve_chunk<'a>(
    env: Env<'a>,
    handle: ResourceArc<DbHandle>,
    start: Option<Binary>,
    after: Option<Binary>,
    stop: Option<Binary>,
    limit: usize,
    mode: Atom,
) -> NifResult<Term<'a>> {
    use std::ops::Bound;
    let lower = match (&start, &after) {
        (Some(b), _) => Bound::Included(b.as_slice().to_vec()),
        (None, Some(b)) => Bound::Excluded(b.as_slice().to_vec()),
        (None, None) => Bound::Unbounded,
    };
    let upper = match &stop {
        Some(b) => Bound::Included(b.as_slice().to_vec()),
        None => Bound::Unbounded,
    };
    let want_columns = mode == atoms::columns();
    let want_datoms = mode == atoms::datoms();
    let want_pairs = mode == atoms::pairs();
    if !want_columns && !want_datoms && !want_pairs {
        return Err(err("resolve mode must be :datoms, :columns or :pairs"));
    }

    let mut datoms: Vec<Term<'a>> = Vec::new();
    let mut pairs: Vec<Term<'a>> = Vec::new();
    let mut cols = Columns::new();
    let mut last_key: Option<Vec<u8>> = None;
    let shape = VectorShape::new(env)?;

    for entry in handle.datoms.range((lower, upper)).take(limit) {
        let (k, v) = entry.map_err(|e| err(e))?;
        if want_pairs {
            // The port's `-range` holds ARBITRARY values (counters, blobs and
            // datoms share the keyspace), so this mode must not require a datom
            // shape — that is the `:datoms`/`:columns` contract, not the port's.
            let key = to_binary(env, &k)?.to_term(env);
            let value = slot_term(env, &v, &shape)?;
            pairs.push(shape.vector(env, &[key, value])?);
        } else {
            let row = read_row(&v)?;
            if want_datoms {
                datoms.push(datom_term(env, &row, &shape)?);
            } else {
                cols.push(env, &row, &shape)?;
            }
        }
        last_key = Some(k.to_vec());
    }

    let out = map_new(env);
    let n = if want_columns { cols.n } else if want_datoms { datoms.len() } else { pairs.len() };
    let out = out.map_put("n", n as u64)?;
    let out = match &last_key {
        Some(k) => out.map_put("last", to_binary(env, k)?)?,
        None => out.map_put("last", atoms::nil().to_term(env))?,
    };
    let out = if want_datoms {
        out.map_put("datoms", datoms.encode(env))?
    } else if want_pairs {
        out.map_put("pairs", pairs.encode(env))?
    } else {
        let paths = cols
            .a_dict
            .iter()
            .map(|d| to_binary(env, d).map(|b| b.to_term(env)))
            .collect::<NifResult<Vec<Term>>>()?;
        out.map_put("a-dict", paths.encode(env))?
            .map_put("a-idx", to_binary(env, &cols.a_idx)?)?
            .map_put("e", to_binary(env, &cols.e)?)?
            .map_put("tx", to_binary(env, &cols.tx)?)?
            .map_put("op", to_binary(env, &cols.op)?)?
            .map_put("v-lane", to_binary(env, &cols.v_lane)?)?
            .map_put("v-idx", to_binary(env, &cols.v_idx)?)?
            .map_put("v-long", to_binary(env, &cols.v_long)?)?
            .map_put("v-bool", to_binary(env, &cols.v_bool)?)?
            .map_put("v-double", to_binary(env, &cols.v_double)?)?
            .map_put("v-var-off", to_binary(env, &cols.v_var_off)?)?
            .map_put("v-var", to_binary(env, &cols.v_var)?)?
    };
    Ok(out)
}

/// `fjall_resolve_prefixes`: every datom under ANY of `bounds` (a list of
/// `[lo hi]` inclusive binary pairs), decoded in Rust, in ONE crossing.
///
/// The read behind the engine's semi-join: N prefixes — one per distinct
/// bound join value — in, only their datoms out. Bounds arrive sorted (the
/// index layer sorts them) so this is one forward pass over the LSM with N
/// short seeks, never a column scan. Rows are decoded the same way
/// `fjall_resolve_chunk`'s `:datoms` mode decodes them.
///
/// Not chunked: each prefix is bounded by construction (an entity's datoms,
/// one attribute's value), and the caller has already capped N
/// (`SEMI-JOIN-MAX`), so the transient is bounded by the ANSWER.
#[rustler::nif(schedule = "DirtyIo")]
fn fjall_resolve_prefixes<'a>(
    env: Env<'a>,
    handle: ResourceArc<DbHandle>,
    bounds: Vec<(Binary, Binary)>,
) -> NifResult<Term<'a>> {
    use std::ops::Bound;
    let shape = VectorShape::new(env)?;
    let mut datoms: Vec<Term<'a>> = Vec::new();
    for (lo, hi) in bounds {
        let lower = Bound::Included(lo.as_slice().to_vec());
        let upper = Bound::Included(hi.as_slice().to_vec());
        for entry in handle.datoms.range((lower, upper)) {
            let (_k, v) = entry.map_err(|e| err(e))?;
            let row = read_row(&v)?;
            datoms.push(datom_term(env, &row, &shape)?);
        }
    }
    let out = map_new(env)
        .map_put("n", datoms.len() as u64)?
        .map_put("datoms", datoms.encode(env))?;
    Ok(out)
}

/// `-put`: store `value` at `key`.
///
/// The write lands in the journal (WAL, crash-recoverable) and the memtable
/// synchronously; it is NOT fsync'd per call. Durability-to-disk is a separate,
/// explicit `fjall_sync` — because a per-write fsync is the single biggest cost
/// in a bulk load (measured: it made a 2721-group transaction 26s instead of
/// the memtable's few hundred ms), and the datom layer commits in GROUPS, so
/// the right place to fsync is once per transaction, not once per datom-group.
/// The keyspace also persists `SyncAll` on drop, so a clean shutdown is durable.
#[rustler::nif(schedule = "DirtyIo")]
fn fjall_put(handle: ResourceArc<DbHandle>, key: Binary, value: Binary) -> NifResult<Atom> {
    let _g = handle.lock.lock().map_err(|e| err(e))?;
    handle
        .datoms
        .insert(key.as_slice(), value.as_slice())
        .map_err(|e| err(e))?;
    Ok(atoms::ok())
}

/// `-delete`: remove `key`. Idempotent. Journaled, not fsync'd per call — see
/// `fjall_put` and `fjall_sync`.
#[rustler::nif(schedule = "DirtyIo")]
fn fjall_delete(handle: ResourceArc<DbHandle>, key: Binary) -> NifResult<Atom> {
    let _g = handle.lock.lock().map_err(|e| err(e))?;
    handle.datoms.remove(key.as_slice()).map_err(|e| err(e))?;
    Ok(atoms::ok())
}

/// `-sync`: force everything written so far to disk. The datom layer calls this
/// once at the end of a transaction (or a bulk load), turning N per-group
/// fsyncs into one. This is the durability boundary a caller can rely on: after
/// it returns, every prior put/delete/commit is on disk.
/// Engine statistics, for the questions only the engine can answer: how full the
/// block cache is, whether compaction runs at all, how much of the disk is the
/// journal.
///
/// WHY THIS EXISTS. `lsm-tree`'s block cache exposes `size`/`capacity`/`len` and
/// NO hit/miss counters, so the "block cache hit rate" cannot be measured — ever,
/// on this stack. What CAN be measured is what a hit rate is a proxy for: how
/// much the read path pulls from the OS (see the `rchar` deltas in
/// knowledger's `semantica/benches/bench-s93.bl`) and how full the cache is.
/// This NIF is the second half; without it, cache sizing was an inference.
///
/// Cheap and side-effect free: it reads atomics the engine already maintains.
#[rustler::nif]
fn fjall_stats<'a>(env: Env<'a>, handle: ResourceArc<DbHandle>) -> NifResult<Term<'a>> {
    let ks = &handle.keyspace;
    let m = map_new(env)
        .map_put(atoms::cache_capacity(), ks.cache_capacity())?
        .map_put(atoms::write_buffer(), ks.write_buffer_size())?
        .map_put(atoms::flushes_completed(), ks.flushes_completed())?
        .map_put(atoms::active_compactions(), ks.active_compactions())?
        .map_put(atoms::compactions_completed(), ks.compactions_completed())?
        .map_put(atoms::time_compacting_us(), ks.time_compacting().as_micros() as u64)?
        .map_put(atoms::journal_count(), ks.journal_count())?
        .map_put(atoms::journal_bytes(), ks.journal_disk_space())?
        .map_put(atoms::disk_bytes(), ks.disk_space())?
        .map_put(atoms::partitions(), ks.partition_count())?;
    Ok(m)
}

#[rustler::nif(schedule = "DirtyIo")]
fn fjall_sync(handle: ResourceArc<DbHandle>) -> NifResult<Atom> {
    let _g = handle.lock.lock().map_err(|e| err(e))?;
    handle
        .keyspace
        .persist(PersistMode::SyncAll)
        .map_err(|e| err(e))?;
    Ok(atoms::ok())
}

/// Compare-and-swap: write `new` at `key` only if the current value is
/// `expected` (or the key is absent, when `expected` is `None`). Returns
/// `{swapped?, value_now_at_key}`.
///
/// The read and the write are guarded by the handle lock so no other writer
/// straddles them — the LSM analogue of "one write transaction". The boolean
/// distinguishes a failed swap from a successful one whose new value already
/// equalled the target (a retry loop MUST tell those apart).
#[rustler::nif(schedule = "DirtyIo")]
fn fjall_cas<'a>(
    env: Env<'a>,
    handle: ResourceArc<DbHandle>,
    key: Binary,
    expected: Option<Binary>,
    new: Binary,
) -> NifResult<Term<'a>> {
    let _g = handle.lock.lock().map_err(|e| err(e))?;

    let current: Option<Vec<u8>> = handle
        .datoms
        .get(key.as_slice())
        .map_err(|e| err(e))?
        .map(|v| v.to_vec());

    let matches = match (&current, &expected) {
        (None, None) => true,
        (Some(c), Some(e)) => c.as_slice() == e.as_slice(),
        _ => false,
    };

    let (result, swapped): (Vec<u8>, bool) = if matches {
        handle
            .datoms
            .insert(key.as_slice(), new.as_slice())
            .map_err(|e| err(e))?;
        (new.as_slice().to_vec(), true)
    } else {
        (current.unwrap_or_default(), false)
    };

    let value = to_binary(env, &result)?.to_term(env);
    Ok(rustler::types::tuple::make_tuple(
        env,
        &[swapped.encode(env), value],
    ))
}

/// `-commit`: apply a whole batch atomically — the method the backend exists
/// for. `ops` is a list of `{:put, key, value}` and `{:delete, key}` tuples,
/// applied IN ORDER inside ONE fjall batch. Order is correctness:
/// `[[:delete k], [:put k v]]` is a retract-then-reassert, and grouping the
/// puts ahead of the deletes would silently lose the value. The batch is
/// atomic: everything becomes durable at `commit()`, or none of it does.
#[rustler::nif(schedule = "DirtyIo")]
fn fjall_commit(handle: ResourceArc<DbHandle>, ops: Vec<Term>) -> NifResult<Atom> {
    let _g = handle.lock.lock().map_err(|e| err(e))?;
    let mut batch = handle.keyspace.batch();

    for op in ops {
        let tuple = rustler::types::tuple::get_tuple(op)?;
        match tuple.len() {
            3 => {
                let tag: Atom = tuple[0].decode()?;
                if tag != atoms::put() {
                    return Err(err("a 3-element op must be {:put, key, value}"));
                }
                let k: Binary = tuple[1].decode()?;
                let v: Binary = tuple[2].decode()?;
                batch.insert(&handle.datoms, k.as_slice(), v.as_slice());
            }
            2 => {
                let tag: Atom = tuple[0].decode()?;
                if tag != atoms::delete() {
                    return Err(err("a 2-element op must be {:delete, key}"));
                }
                let k: Binary = tuple[1].decode()?;
                batch.remove(&handle.datoms, k.as_slice());
            }
            n => return Err(err(format!("an op must have 2 or 3 elements, got {}", n))),
        }
    }

    // The whole batch is journaled atomically here (crash-recoverable). It is
    // NOT fsync'd per commit — the datom layer commits per datom-group, so a
    // fsync here would be one-per-group; durability-to-disk is the explicit
    // `fjall_sync` the caller invokes once per transaction. Atomicity (all or
    // none) holds regardless of the fsync boundary.
    batch.commit().map_err(|e| err(e))?;
    Ok(atoms::ok())
}

/// Encode ONE value to its order-preserving key bytes (the codec.bl oracle
/// path, in Rust). `tag` names the lane the caller classified the value into
/// ("int"/"str"/"kw"/"bool"); the payload is the raw value. Returns the key
/// binary, or `nil` when the value is outside the four bulk lanes (e.g. a bignum
/// past 2^53) so the caller falls back to the bl codec. This exists so a
/// differential test can assert byte-identity with codec.bl before the fan-out
/// relies on it.
#[rustler::nif]
fn keycodec_encode<'a>(env: Env<'a>, tag: Atom, ival: i64, sval: Binary, bval: bool) -> NifResult<Term<'a>> {
    let kv = if tag == int_atom() {
        KeyVal::Int(ival)
    } else if tag == str_atom() {
        KeyVal::Str(sval.as_slice())
    } else if tag == kw_atom() {
        KeyVal::Keyword(sval.as_slice())
    } else if tag == bool_atom() {
        KeyVal::Bool(bval)
    } else {
        return Ok(atoms::nil().to_term(env));
    };
    match keycodec::encode(&kv) {
        Some(bytes) => Ok(to_binary(env, &bytes)?.to_term(env)),
        None => Ok(atoms::nil().to_term(env)),
    }
}

mod lane_atoms {
    rustler::atoms! { int, str, kw, boolean }
}
fn int_atom() -> Atom { lane_atoms::int() }
fn str_atom() -> Atom { lane_atoms::str() }
fn kw_atom() -> Atom { lane_atoms::kw() }
fn bool_atom() -> Atom { lane_atoms::boolean() }

/// Build a WHOLE index key from `idx_tag` and the datom's components already
/// ordered for that index, each pre-classified by the caller as one of the four
/// bulk lanes. `comps` is a list of `{lane_tag, ival, sval, bval}` tuples (the
/// caller reads the datom's [e a v tx op] and tags each). The key is
///   [idx_tag] ++ concat(encode(component))
/// byte-identical to codec.bl's `key-for`. Returns the key binary, or `nil` if
/// ANY component is out of lane — then the caller builds that one key with the
/// bl codec. One BEAM crossing per key (not one per component).
#[rustler::nif]
fn keycodec_key<'a>(env: Env<'a>, idx_tag: u8, comps: Vec<Term<'a>>) -> NifResult<Term<'a>> {
    let mut out: Vec<u8> = Vec::with_capacity(64);
    out.push(idx_tag);
    for c in comps {
        let t = rustler::types::tuple::get_tuple(c)?;
        if t.len() != 4 {
            return Err(err("a component must be {lane, ival, sval, bval}"));
        }
        let lane: Atom = t[0].decode()?;
        let kv = if lane == int_atom() {
            KeyVal::Int(t[1].decode()?)
        } else if lane == str_atom() {
            let b: Binary = t[2].decode()?;
            match keycodec::encode(&KeyVal::Str(b.as_slice())) {
                Some(bytes) => { out.extend_from_slice(&bytes); continue; }
                None => return Ok(atoms::nil().to_term(env)),
            }
        } else if lane == kw_atom() {
            let b: Binary = t[2].decode()?;
            match keycodec::encode(&KeyVal::Keyword(b.as_slice())) {
                Some(bytes) => { out.extend_from_slice(&bytes); continue; }
                None => return Ok(atoms::nil().to_term(env)),
            }
        } else if lane == bool_atom() {
            KeyVal::Bool(t[3].decode()?)
        } else {
            return Ok(atoms::nil().to_term(env));
        };
        match keycodec::encode(&kv) {
            Some(bytes) => out.extend_from_slice(&bytes),
            None => return Ok(atoms::nil().to_term(env)),
        }
    }
    Ok(to_binary(env, &out)?.to_term(env))
}

/// Classify a raw BEAM datom-component term into a KeyVal, inspecting the term
/// type in Rust (so the caller does NOT allocate a classify tuple per component
/// — that per-component allocation is what made a per-key path lose). Returns
/// None for a term outside the four bulk lanes. `owned` collects any binary we
/// must materialise (atom names) so its slice outlives the KeyVal.
fn classify_term<'a>(t: Term<'a>) -> Option<ClassifiedVal> {
    use rustler::TermType;
    match t.get_type() {
        TermType::Integer => t.decode::<i64>().ok().map(ClassifiedVal::Int),
        TermType::Binary => t.decode::<Binary>().ok().map(|b| ClassifiedVal::Str(b.as_slice().to_vec())),
        TermType::Atom => {
            // true/false are atoms -> bool lane; any other atom -> keyword name.
            let name: String = t.atom_to_string().ok()?;
            match name.as_str() {
                "true" => Some(ClassifiedVal::Bool(true)),
                "false" => Some(ClassifiedVal::Bool(false)),
                _ => Some(ClassifiedVal::Keyword(name.into_bytes())),
            }
        }
        _ => None,
    }
}

/// An owned classification (owns its bytes so it lives past term decoding).
enum ClassifiedVal {
    Int(i64),
    Str(Vec<u8>),
    Keyword(Vec<u8>),
    Bool(bool),
}
impl ClassifiedVal {
    fn as_keyval(&self) -> KeyVal {
        match self {
            ClassifiedVal::Int(n) => KeyVal::Int(*n),
            ClassifiedVal::Str(b) => KeyVal::Str(b),
            ClassifiedVal::Keyword(b) => KeyVal::Keyword(b),
            ClassifiedVal::Bool(b) => KeyVal::Bool(*b),
        }
    }
}

/// The component order for an index tag, as indices into a datom `[e a v tx op]`
/// (0=e 1=a 2=v 3=tx 4=op). Matches datom.index/index-components.
fn index_order(idx_tag: u8) -> Option<[usize; 5]> {
    match idx_tag {
        1 => Some([0, 1, 2, 3, 4]), // EAVT
        2 => Some([1, 0, 2, 3, 4]), // AEVT
        3 => Some([1, 2, 0, 3, 4]), // AVET
        4 => Some([2, 1, 0, 3, 4]), // VAET
        _ => None,
    }
}

/// BATCH key encoding: the whole transaction's keys in ONE crossing.
///
/// `datoms` is a list of `{e, a, v, tx, op}` 5-tuples (raw BEAM terms). `idx_lists`
/// is a parallel list: for datom i, the list of index tags (1-4) it must be
/// written into (the schema decided that on the bl side, cheaply, per-attribute).
/// Returns a flat list of key binaries in datom-major, index-order — exactly the
/// order `write-datoms` would produce — or `nil` if ANY component is out of lane
/// (then the caller builds the whole batch with the bl codec). One crossing, no
/// per-component BEAM allocation: classification and encoding are entirely native.
#[rustler::nif]
fn keycodec_batch<'a>(
    env: Env<'a>,
    datoms: Vec<Term<'a>>,
    idx_lists: Vec<Vec<u8>>,
) -> NifResult<Term<'a>> {
    if datoms.len() != idx_lists.len() {
        return Err(err("datoms and idx_lists must be the same length"));
    }
    let mut keys: Vec<Term<'a>> = Vec::with_capacity(datoms.len() * 4);
    for (d, idxs) in datoms.iter().zip(idx_lists.iter()) {
        let fields = rustler::types::tuple::get_tuple(*d)?;
        if fields.len() != 5 {
            return Err(err("a datom must be a 5-tuple {e a v tx op}"));
        }
        // classify all five components once per datom
        let mut classified: Vec<ClassifiedVal> = Vec::with_capacity(5);
        for f in &fields {
            match classify_term(*f) {
                Some(cv) => classified.push(cv),
                None => return Ok(atoms::nil().to_term(env)), // out of lane: whole batch to bl
            }
        }
        for &idx_tag in idxs {
            let order = match index_order(idx_tag) {
                Some(o) => o,
                None => return Err(err("unknown index tag")),
            };
            let mut buf: Vec<u8> = Vec::with_capacity(48);
            buf.push(idx_tag);
            for &pos in &order {
                if !keycodec::encode_into(&classified[pos].as_keyval(), &mut buf) {
                    return Ok(atoms::nil().to_term(env));
                }
            }
            keys.push(to_binary(env, &buf)?.to_term(env));
        }
    }
    Ok(keys.encode(env))
}

/// A marker the host module only has once the NIF has replaced its stubs.
#[rustler::nif]
fn __nif_loaded__() -> bool {
    true
}

rustler::init!("Elixir.BeamLisp.Native.Datom.StoreFjall");



