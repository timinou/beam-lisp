//! datom_fjall — the storage port, in Rust, over fjall (an LSM engine).
//!
//! # Why a second backend
//!
//! `datom.store/Store` is six methods over an ordered key/value space
//! (get, range, put, delete, cas, commit). redb (a copy-on-write B-tree)
//! is one substrate under it; this crate is another. They are
//! interchangeable — everything above L1 is written against the protocol.
//!
//! # Why fjall specifically
//!
//! The datom log is APPEND-DOMINATED: a transaction writes each datom into
//! two-to-four index orderings, monotonically, and reads are ordered range
//! scans. That is the exact shape an LSM tree is built for — writes land in
//! a memtable and flush sequentially, range scans merge sorted runs. redb's
//! B-tree pays copy-on-write page churn on every commit (measured: ~13s to
//! bulk-load the compiler's 11k-datom codebase graph); fjall's LSM amortises
//! the same writes through the memtable.
//!
//! # The one requirement that matters: atomic cross-index commit
//!
//! A datom present in EAVT but missing from AEVT is a CORRUPT database, not a
//! slow one. The four indexes share one keyspace (the index tag is the first
//! key byte — EAVT=1 AEVT=2 AVET=3 VAET=4), so an atomic commit is a single
//! atomic batch. fjall gives that via a keyspace-level `Batch`: every write in
//! the batch becomes durable together at `commit()`, or none does. `-commit`
//! delegates to that batch, exactly as the redb adapter delegates to a write
//! transaction.
//!
//! # Durability
//!
//! Every commit is persisted (fjall persists the batch to the write-ahead log
//! before returning). A faster mode (defer the fsync) would be an explicit,
//! named choice, never a silent default — same policy as the redb adapter.
//!
//! # The BEAM boundary
//!
//! Every operation touches a file, so every NIF runs on a DirtyIo scheduler.
//! The boundary is coarse — `commit` takes the whole batch, `range` returns
//! the whole window — so a transaction costs one BEAM↔Rust crossing.

use rustler::{Atom, Binary, Encoder, Env, Error, NifResult, OwnedBinary, Resource, ResourceArc, Term};
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
    }
}

/// A handle to an open keyspace + its single datom partition.
///
/// The `Mutex` is here for the same reason as the redb adapter's: a `-cas`
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

/// A marker the host module only has once the NIF has replaced its stubs.
#[rustler::nif]
fn __nif_loaded__() -> bool {
    true
}

rustler::init!("Elixir.BeamLisp.Native.Datom.StoreFjall");



