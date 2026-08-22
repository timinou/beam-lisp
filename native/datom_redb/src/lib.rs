//! datom_redb — the storage port, in Rust, over redb.
//!
//! # What this is
//!
//! beam-lisp's `datom.store/Store` protocol is six methods over an
//! ordered key/value space. Everything above it — datoms, four covering
//! indexes, datalog, time travel — is pure logic and does not know what
//! is underneath. This crate is one thing that can be underneath.
//!
//! # The requirement that chose redb
//!
//! Three of the four port requirements are common: ordered byte-wise
//! keys, inclusive-bound range scans, compare-and-swap.
//!
//! The fourth is not. **A transaction writes one datom into two to four
//! index orderings, and all of them must land together.** A datom
//! present in EAVT but missing from AEVT is not a slow database, it is
//! a corrupt one: a query that consults AEVT will report the fact does
//! not exist while a query that consults EAVT reports it does.
//!
//! redb gives that directly. `Database::begin_write()` opens a
//! `WriteTransaction`; every table write inside it becomes visible at
//! `commit()` or not at all. So `-commit` is not something this adapter
//! implements, it is something it *delegates* — which is the whole
//! reason to have a real storage engine rather than a file.
//!
//! # Durability is explicit, and the default is the safe one
//!
//! redb offers `Durability::None`, which returns from `commit()`
//! without the data reaching disk. That is a legitimate mode for a
//! cache and a catastrophic default for a database, because a commit
//! that returns is a commit the caller believes. This adapter sets
//! `Durability::Immediate` on every write transaction and offers no way
//! to change it. If a faster mode is ever wanted it should be an
//! explicit, named, documented choice — not a flag someone flips.
//!
//! # The BEAM boundary
//!
//! Every operation here touches a file, so every NIF is scheduled on a
//! **dirty IO** scheduler. A NIF that blocks a normal scheduler stalls
//! every process the VM is running on that core; dirty schedulers exist
//! precisely so a filesystem call cannot do that.
//!
//! The boundary is also deliberately **coarse**: `commit` takes the
//! whole batch and `range` returns the whole window, so a transaction
//! costs one BEAM↔Rust crossing rather than one per datom. A chatty NIF
//! spends more time marshalling terms than doing work.

use rustler::{Atom, Binary, Env, Error, NifResult, OwnedBinary, Resource, ResourceArc, Term};
use redb::{Database, Durability, ReadableDatabase, ReadableTable, TableDefinition};
use std::io::Write;
use std::ops::Bound;
use std::path::Path;
use std::sync::Mutex;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        nil,
        put,
        delete,
    }
}

/// One table holds everything.
///
/// The database above encodes an INDEX TAG as the first component of
/// every key (EAVT=1, AEVT=2, AVET=3, VAET=4), so the four indexes are
/// already four disjoint key ranges in one ordered space. Splitting
/// them into four redb tables would add nothing and would make an
/// atomic cross-index commit a cross-table concern rather than a
/// single-table one.
const DATOMS: TableDefinition<&[u8], &[u8]> = TableDefinition::new("datoms");

/// A handle to an open database, held by the BEAM as a resource.
///
/// The `Mutex` is not for correctness — redb already serializes writers
/// internally, and `begin_write` blocks until it can proceed. It is
/// here so that a `-update` (read, apply, write) cannot interleave with
/// another `-update` on the same key between its read and its write.
/// redb would serialize the two *transactions*, but the read in one and
/// the write in the other could still straddle.
struct DbHandle {
    db: Mutex<Database>,
}

#[rustler::resource_impl]
impl Resource for DbHandle {}

fn err(msg: impl std::fmt::Display) -> Error {
    Error::Term(Box::new(format!("{}", msg)))
}

/// Copy a slice into a BEAM binary.
fn to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> NifResult<Binary<'a>> {
    let mut owned = OwnedBinary::new(bytes.len())
        .ok_or_else(|| err("could not allocate a binary"))?;
    owned
        .as_mut_slice()
        .write_all(bytes)
        .map_err(|e| err(e))?;
    Ok(Binary::from_owned(owned, env))
}

/// Open (or create) a database at `path`.
///
/// Dirty IO: this creates and mmaps a file.
#[rustler::nif(schedule = "DirtyIo")]
fn redb_open(path: String) -> NifResult<ResourceArc<DbHandle>> {
    let db = Database::create(Path::new(&path)).map_err(|e| err(e))?;

    // Create the table eagerly so that a read against a brand-new
    // database sees an empty table rather than a "no such table"
    // error. An empty database and a missing table are the same thing
    // to every caller above, and they should not have to know that
    // redb distinguishes them.
    {
        let mut txn = db.begin_write().map_err(|e| err(e))?;
        txn.set_durability(Durability::Immediate)
            .map_err(|e| err(e))?;
        {
            let _ = txn.open_table(DATOMS).map_err(|e| err(e))?;
        }
        txn.commit().map_err(|e| err(e))?;
    }

    Ok(ResourceArc::new(DbHandle { db: Mutex::new(db) }))
}

/// `-get`: the value at `key`, or `nil`.
#[rustler::nif(schedule = "DirtyIo")]
fn redb_get<'a>(env: Env<'a>, handle: ResourceArc<DbHandle>, key: Binary) -> NifResult<Term<'a>> {
    let db = handle.db.lock().map_err(|e| err(e))?;
    let txn = db.begin_read().map_err(|e| err(e))?;
    let table = txn.open_table(DATOMS).map_err(|e| err(e))?;

    match table.get(key.as_slice()).map_err(|e| err(e))? {
        Some(v) => Ok(to_binary(env, v.value())?.to_term(env)),
        None => Ok(atoms::nil().to_term(env)),
    }
}

/// `-range`: every `[k v]` with `start <= k <= stop`, in key order.
///
/// **Bounds are INCLUSIVE on both sides.** This is the single easiest
/// property for a backend to get wrong, and getting it wrong is silent:
/// a half-open upper bound drops exactly one datom from the end of
/// every scan, which reads as sporadically missing data rather than as
/// an error. The conformance suite asserts it directly.
///
/// A `nil` bound (passed as an empty option) means unbounded.
#[rustler::nif(schedule = "DirtyIo")]
fn redb_range<'a>(
    env: Env<'a>,
    handle: ResourceArc<DbHandle>,
    start: Option<Binary>,
    stop: Option<Binary>,
) -> NifResult<Term<'a>> {
    let db = handle.db.lock().map_err(|e| err(e))?;
    let txn = db.begin_read().map_err(|e| err(e))?;
    let table = txn.open_table(DATOMS).map_err(|e| err(e))?;

    let lower = match &start {
        Some(b) => Bound::Included(b.as_slice()),
        None => Bound::Unbounded,
    };
    // Included, not Excluded — see the note above.
    let upper = match &stop {
        Some(b) => Bound::Included(b.as_slice()),
        None => Bound::Unbounded,
    };

    let mut pairs: Vec<Term<'a>> = Vec::new();
    let iter = table.range::<&[u8]>((lower, upper)).map_err(|e| err(e))?;

    for entry in iter {
        let (k, v) = entry.map_err(|e| err(e))?;
        let kb = to_binary(env, k.value())?;
        let vb = to_binary(env, v.value())?;
        pairs.push(rustler::types::tuple::make_tuple(
            env,
            &[kb.to_term(env), vb.to_term(env)],
        ));
    }

    Ok(pairs.encode(env))
}

/// `-put`: store `value` at `key`.
#[rustler::nif(schedule = "DirtyIo")]
fn redb_put(handle: ResourceArc<DbHandle>, key: Binary, value: Binary) -> NifResult<Atom> {
    let db = handle.db.lock().map_err(|e| err(e))?;
    let mut txn = db.begin_write().map_err(|e| err(e))?;
    txn.set_durability(Durability::Immediate)
        .map_err(|e| err(e))?;
    {
        let mut table = txn.open_table(DATOMS).map_err(|e| err(e))?;
        table
            .insert(key.as_slice(), value.as_slice())
            .map_err(|e| err(e))?;
    }
    txn.commit().map_err(|e| err(e))?;
    Ok(atoms::ok())
}

/// `-delete`: remove `key`. Idempotent.
#[rustler::nif(schedule = "DirtyIo")]
fn redb_delete(handle: ResourceArc<DbHandle>, key: Binary) -> NifResult<Atom> {
    let db = handle.db.lock().map_err(|e| err(e))?;
    let mut txn = db.begin_write().map_err(|e| err(e))?;
    txn.set_durability(Durability::Immediate)
        .map_err(|e| err(e))?;
    {
        let mut table = txn.open_table(DATOMS).map_err(|e| err(e))?;
        table.remove(key.as_slice()).map_err(|e| err(e))?;
    }
    txn.commit().map_err(|e| err(e))?;
    Ok(atoms::ok())
}

/// Compare-and-swap: write `new` at `key` only if the current value is
/// `expected` (or the key is absent, when `expected` is `None`).
///
/// Returns the value now at the key. The caller compares it against
/// what they asked for to learn whether they won.
///
/// **The read and the write are inside ONE write transaction.** A `get`
/// followed by a separate `put` is not a CAS — it is a race with a
/// longer window. This is the operation that makes the database's
/// `:db/cas` and its id allocation safe, so it is the one place where
/// getting the transaction boundary wrong silently reintroduces lost
/// updates.
#[rustler::nif(schedule = "DirtyIo")]
fn redb_cas<'a>(
    env: Env<'a>,
    handle: ResourceArc<DbHandle>,
    key: Binary,
    expected: Option<Binary>,
    new: Binary,
) -> NifResult<Term<'a>> {
    let db = handle.db.lock().map_err(|e| err(e))?;
    let mut txn = db.begin_write().map_err(|e| err(e))?;
    txn.set_durability(Durability::Immediate)
        .map_err(|e| err(e))?;

    let result: Vec<u8>;
    {
        let mut table = txn.open_table(DATOMS).map_err(|e| err(e))?;

        let current: Option<Vec<u8>> = table
            .get(key.as_slice())
            .map_err(|e| err(e))?
            .map(|v| v.value().to_vec());

        let matches = match (&current, &expected) {
            (None, None) => true,
            (Some(c), Some(e)) => c.as_slice() == e.as_slice(),
            _ => false,
        };

        if matches {
            table
                .insert(key.as_slice(), new.as_slice())
                .map_err(|e| err(e))?;
            result = new.as_slice().to_vec();
        } else {
            result = current.unwrap_or_default();
        }
    }

    txn.commit().map_err(|e| err(e))?;
    to_binary(env, &result).map(|b| b.to_term(env))
}

/// `-commit`: apply a whole batch atomically.
///
/// **This is the method the backend exists for.** `ops` is a list of
/// `{:put, key, value}` and `{:delete, key}` tuples; they are applied
/// IN ORDER inside one write transaction.
///
/// Order is correctness, not an optimisation. `[[:delete k], [:put k v]]`
/// is what a transaction emits when it retracts and re-asserts a datom,
/// and a backend that grouped the puts ahead of the deletes would end
/// with the key absent — the value silently lost.
#[rustler::nif(schedule = "DirtyIo")]
fn redb_commit(handle: ResourceArc<DbHandle>, ops: Vec<Term>) -> NifResult<Atom> {
    let db = handle.db.lock().map_err(|e| err(e))?;
    let mut txn = db.begin_write().map_err(|e| err(e))?;
    txn.set_durability(Durability::Immediate)
        .map_err(|e| err(e))?;

    {
        let mut table = txn.open_table(DATOMS).map_err(|e| err(e))?;

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
                    table
                        .insert(k.as_slice(), v.as_slice())
                        .map_err(|e| err(e))?;
                }
                2 => {
                    let tag: Atom = tuple[0].decode()?;
                    if tag != atoms::delete() {
                        return Err(err("a 2-element op must be {:delete, key}"));
                    }
                    let k: Binary = tuple[1].decode()?;
                    table.remove(k.as_slice()).map_err(|e| err(e))?;
                }
                n => return Err(err(format!("an op must have 2 or 3 elements, got {}", n))),
            }
        }
    }

    // Everything above becomes visible here, or none of it does.
    txn.commit().map_err(|e| err(e))?;
    Ok(atoms::ok())
}

use rustler::Encoder;

/// A marker the host module only has once the NIF has actually
/// replaced its stubs. `BeamLisp.Native.available?/1` tests for it,
/// which is how a beam-lisp store decides whether to offer itself.
#[rustler::nif]
fn __nif_loaded__() -> bool {
    true
}

// The host module is created by `defnative` in the beam-lisp namespace
// that uses it — `datom.store-redb` — so there is no Elixir module in
// the path. The name here must match what `BeamLisp.Native.host_module/1`
// derives from that namespace.
rustler::init!("Elixir.BeamLisp.Native.Datom.StoreRedb");
