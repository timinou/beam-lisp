//! datom_sqlite — the storage port, in Rust, over SQLite (a B-tree engine).
//!
//! # A backend under a six-method protocol
//!
//! `datom.store/Store` is six methods over an ordered key/value space
//! (get, range, put, delete, cas, commit). This crate is a durable
//! substrate under it, beside the fjall LSM backend and the in-memory
//! ETS/map stores. They are interchangeable — everything above L1 is
//! written against the protocol, never against a specific engine. This
//! crate exists so the two DURABLE engines (an LSM tree and a B-tree) can
//! be measured against each other on the exact same workload.
//!
//! # Why SQLite maps onto the port so directly
//!
//! The port needs an ORDERED key space with range scans and an ATOMIC
//! multi-key commit. SQLite gives both from one table:
//!
//! ```sql
//! CREATE TABLE datoms (k BLOB PRIMARY KEY, v BLOB NOT NULL) WITHOUT ROWID;
//! ```
//!
//! `WITHOUT ROWID` makes the table itself a B-tree keyed by `k`, and a
//! `BLOB` primary key compares by `memcmp` — byte-lexicographic, which is
//! EXACTLY the ordering the datom key codec is built to exploit (a covering
//! index is an order-preserving key encoding plus a range scan over it).
//! No secondary index, no rowid indirection: the key IS the physical order.
//!
//! # The one requirement that matters: atomic cross-index commit
//!
//! A datom present in EAVT but missing from AEVT is a CORRUPT database, not a
//! slow one. A transaction writes each datom into two-to-four index orderings;
//! all of those writes must land together or not at all. SQLite's write
//! transaction gives that directly — `-commit` opens one transaction, applies
//! every op IN ORDER, and commits atomically. Order is correctness:
//! `[[:delete k] [:put k v]]` is a retract-then-reassert, and reordering would
//! silently lose the value.
//!
//! # Durability
//!
//! WAL journal mode with `synchronous = NORMAL`: a commit appends to the
//! write-ahead log and is crash-recoverable across an APPLICATION crash, but
//! is NOT fsync'd per commit (the WAL is fsync'd at a checkpoint). That mirrors
//! the fjall backend exactly — journaled per commit, fsync deferred — so the
//! durability/throughput tradeoff is the same on both, and the benchmark
//! compares engines rather than fsync policies. `-sync` forces a full
//! checkpoint (fsync), the explicit durability boundary the datom layer calls
//! once per transaction/bulk-load.
//!
//! # The BEAM boundary
//!
//! Every operation touches a file, so every NIF runs on a DirtyIo scheduler.
//! The boundary is coarse — `commit` takes the whole batch, `range` returns
//! the whole window — so a transaction costs one BEAM↔Rust crossing. The
//! single `Connection` is guarded by a `Mutex`: rusqlite serialises anyway,
//! and the guard is what keeps a `-cas` read+write from interleaving with
//! another writer.

use rusqlite::{params, params_from_iter, Connection, OptionalExtension, TransactionBehavior};
use rustler::{
    Atom, Binary, Encoder, Env, Error, NifResult, OwnedBinary, Resource, ResourceArc, Term,
};
use std::io::Write;
use std::sync::Mutex;

mod atoms {
    rustler::atoms! {
        ok,
        nil,
        put,
        delete,
    }
}

/// A handle to an open SQLite database.
///
/// The `Mutex` serialises access to the single connection. rusqlite would
/// serialise writes on its own, but a `-cas` does a READ then a WRITE and the
/// two must not straddle another writer — the guard is that atomicity, the
/// B-tree analogue of "one write transaction".
pub(crate) struct DbHandle {
    pub(crate) conn: Mutex<Connection>,
}

#[rustler::resource_impl]
impl Resource for DbHandle {}

pub(crate) fn err(msg: impl std::fmt::Display) -> Error {
    Error::Term(Box::new(format!("{}", msg)))
}

fn to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> NifResult<Binary<'a>> {
    let mut owned =
        OwnedBinary::new(bytes.len()).ok_or_else(|| err("could not allocate a binary"))?;
    owned.as_mut_slice().write_all(bytes).map_err(|e| err(e))?;
    Ok(Binary::from_owned(owned, env))
}

/// Open (or create) a SQLite database at `path`, with one `datoms` table.
///
/// The table is created eagerly so a read against a brand-new database sees an
/// empty table, never a "no such table". WAL + `synchronous = NORMAL` set the
/// durability model (see the module docs); `WITHOUT ROWID` + a `BLOB` primary
/// key make the table a byte-ordered B-tree, which is the whole reason the
/// engine can back an index.
#[rustler::nif(schedule = "DirtyIo")]
fn sqlite_open<'a>(env: Env<'a>, path: String) -> NifResult<Term<'a>> {
    let conn = Connection::open(&path).map_err(|e| err(e))?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;\n\
         PRAGMA synchronous = NORMAL;\n\
         CREATE TABLE IF NOT EXISTS datoms (k BLOB PRIMARY KEY, v BLOB NOT NULL) WITHOUT ROWID;",
    )
    .map_err(|e| err(e))?;
    let arc = ResourceArc::new(DbHandle {
        conn: Mutex::new(conn),
    });
    Ok(arc.encode(env))
}

/// `-get`: the value at `key`, or `nil`.
#[rustler::nif(schedule = "DirtyIo")]
fn sqlite_get<'a>(env: Env<'a>, handle: ResourceArc<DbHandle>, key: Binary) -> NifResult<Term<'a>> {
    let conn = handle.conn.lock().map_err(|e| err(e))?;
    let value: Option<Vec<u8>> = conn
        .query_row(
            "SELECT v FROM datoms WHERE k = ?1",
            params![key.as_slice()],
            |row| row.get(0),
        )
        .optional()
        .map_err(|e| err(e))?;
    match value {
        Some(v) => Ok(to_binary(env, &v)?.to_term(env)),
        None => Ok(atoms::nil().to_term(env)),
    }
}

/// `-range`: every `[k v]` with `start <= k <= stop`, in ascending key order.
///
/// **Bounds are INCLUSIVE on both sides** — the single easiest property to get
/// wrong, and silent when wrong (a half-open upper bound drops one datom from
/// the end of every scan). A `nil` bound (empty option) means unbounded on that
/// side, so the WHERE clause is built from only the bounds that are present.
/// The comparison is `memcmp` on the `BLOB` key column — byte-lexicographic,
/// matching the datom key codec's ordering.
#[rustler::nif(schedule = "DirtyIo")]
fn sqlite_range<'a>(
    env: Env<'a>,
    handle: ResourceArc<DbHandle>,
    start: Option<Binary>,
    stop: Option<Binary>,
) -> NifResult<Term<'a>> {
    let conn = handle.conn.lock().map_err(|e| err(e))?;

    // Build the WHERE clause from whichever bounds are present. Inclusive on
    // both sides (>= and <=), never a half-open >.
    let mut clauses: Vec<&str> = Vec::new();
    let mut binds: Vec<Vec<u8>> = Vec::new();
    if let Some(b) = &start {
        binds.push(b.as_slice().to_vec());
        clauses.push("k >= ?1");
    }
    if let Some(b) = &stop {
        binds.push(b.as_slice().to_vec());
        // The bind index is 1 when start is absent, 2 when present — which is
        // exactly binds.len() after the push above.
        clauses.push(if start.is_some() {
            "k <= ?2"
        } else {
            "k <= ?1"
        });
    }
    let where_sql = if clauses.is_empty() {
        String::new()
    } else {
        format!("WHERE {}", clauses.join(" AND "))
    };
    let sql = format!("SELECT k, v FROM datoms {} ORDER BY k ASC", where_sql);

    let mut stmt = conn.prepare_cached(&sql).map_err(|e| err(e))?;
    let rows = stmt
        .query_map(
            params_from_iter(binds.iter().map(|b| b.as_slice())),
            |row| {
                let k: Vec<u8> = row.get(0)?;
                let v: Vec<u8> = row.get(1)?;
                Ok((k, v))
            },
        )
        .map_err(|e| err(e))?;

    let mut pairs: Vec<Term<'a>> = Vec::new();
    for row in rows {
        let (k, v) = row.map_err(|e| err(e))?;
        let kb = to_binary(env, &k)?;
        let vb = to_binary(env, &v)?;
        pairs.push(rustler::types::tuple::make_tuple(
            env,
            &[kb.to_term(env), vb.to_term(env)],
        ));
    }
    Ok(pairs.encode(env))
}

/// `-put`: store `value` at `key`, replacing any existing value.
///
/// Journaled to the WAL synchronously (crash-recoverable) but NOT fsync'd per
/// call — durability-to-disk is the explicit `sqlite_sync`, because a per-write
/// fsync is the dominant bulk-load cost and the datom layer commits in GROUPS.
#[rustler::nif(schedule = "DirtyIo")]
fn sqlite_put(handle: ResourceArc<DbHandle>, key: Binary, value: Binary) -> NifResult<Atom> {
    let conn = handle.conn.lock().map_err(|e| err(e))?;
    conn.execute(
        "INSERT INTO datoms (k, v) VALUES (?1, ?2) \
         ON CONFLICT(k) DO UPDATE SET v = excluded.v",
        params![key.as_slice(), value.as_slice()],
    )
    .map_err(|e| err(e))?;
    Ok(atoms::ok())
}

/// `-delete`: remove `key`. Idempotent. Journaled, not fsync'd per call.
#[rustler::nif(schedule = "DirtyIo")]
fn sqlite_delete(handle: ResourceArc<DbHandle>, key: Binary) -> NifResult<Atom> {
    let conn = handle.conn.lock().map_err(|e| err(e))?;
    conn.execute("DELETE FROM datoms WHERE k = ?1", params![key.as_slice()])
        .map_err(|e| err(e))?;
    Ok(atoms::ok())
}

/// `-sync`: force everything written so far to disk via a full WAL checkpoint
/// (which fsyncs under `synchronous = NORMAL`). The datom layer calls this once
/// at the end of a transaction or bulk load, turning N per-group fsyncs into
/// one. After it returns, every prior put/delete/commit is durable on disk.
#[rustler::nif(schedule = "DirtyIo")]
fn sqlite_sync(handle: ResourceArc<DbHandle>) -> NifResult<Atom> {
    let conn = handle.conn.lock().map_err(|e| err(e))?;
    conn.execute_batch("PRAGMA wal_checkpoint(FULL);")
        .map_err(|e| err(e))?;
    Ok(atoms::ok())
}

/// Compare-and-swap: write `new` at `key` only if the current value is
/// `expected` (or the key is absent, when `expected` is `None`). Returns
/// `{swapped?, value_now_at_key}`.
///
/// The read and the write run inside one IMMEDIATE transaction so no other
/// writer straddles them — the B-tree analogue of "one write transaction". The
/// boolean distinguishes a failed swap from a successful one whose new value
/// already equalled the target (a retry loop MUST tell those apart).
#[rustler::nif(schedule = "DirtyIo")]
fn sqlite_cas<'a>(
    env: Env<'a>,
    handle: ResourceArc<DbHandle>,
    key: Binary,
    expected: Option<Binary>,
    new: Binary,
) -> NifResult<Term<'a>> {
    let mut conn = handle.conn.lock().map_err(|e| err(e))?;
    let tx = conn
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|e| err(e))?;

    let current: Option<Vec<u8>> = tx
        .query_row(
            "SELECT v FROM datoms WHERE k = ?1",
            params![key.as_slice()],
            |row| row.get(0),
        )
        .optional()
        .map_err(|e| err(e))?;

    let matches = match (&current, &expected) {
        (None, None) => true,
        (Some(c), Some(e)) => c.as_slice() == e.as_slice(),
        _ => false,
    };

    let (result, swapped): (Vec<u8>, bool) = if matches {
        tx.execute(
            "INSERT INTO datoms (k, v) VALUES (?1, ?2) \
             ON CONFLICT(k) DO UPDATE SET v = excluded.v",
            params![key.as_slice(), new.as_slice()],
        )
        .map_err(|e| err(e))?;
        (new.as_slice().to_vec(), true)
    } else {
        (current.unwrap_or_default(), false)
    };

    tx.commit().map_err(|e| err(e))?;

    let value = to_binary(env, &result)?.to_term(env);
    Ok(rustler::types::tuple::make_tuple(
        env,
        &[swapped.encode(env), value],
    ))
}

/// `-commit`: apply a whole batch atomically — the method the backend exists
/// for. `ops` is a list of `{:put, key, value}` and `{:delete, key}` tuples,
/// applied IN ORDER inside ONE transaction. Order is correctness:
/// `[[:delete k] [:put k v]]` is a retract-then-reassert, and grouping the puts
/// ahead of the deletes would silently lose the value. The transaction is
/// atomic: everything becomes visible at commit, or none of it does.
#[rustler::nif(schedule = "DirtyIo")]
fn sqlite_commit(handle: ResourceArc<DbHandle>, ops: Vec<Term>) -> NifResult<Atom> {
    let mut conn = handle.conn.lock().map_err(|e| err(e))?;
    let tx = conn.transaction().map_err(|e| err(e))?;

    // Prepared statements are cached on the CONNECTION, so a bulk load's
    // thousands of ops reuse one compiled plan each rather than recompiling
    // per row. Scoped so they drop before the transaction commits.
    {
        let mut put_stmt = tx
            .prepare_cached(
                "INSERT INTO datoms (k, v) VALUES (?1, ?2) \
                 ON CONFLICT(k) DO UPDATE SET v = excluded.v",
            )
            .map_err(|e| err(e))?;
        let mut del_stmt = tx
            .prepare_cached("DELETE FROM datoms WHERE k = ?1")
            .map_err(|e| err(e))?;

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
                    put_stmt
                        .execute(params![k.as_slice(), v.as_slice()])
                        .map_err(|e| err(e))?;
                }
                2 => {
                    let tag: Atom = tuple[0].decode()?;
                    if tag != atoms::delete() {
                        return Err(err("a 2-element op must be {:delete, key}"));
                    }
                    let k: Binary = tuple[1].decode()?;
                    del_stmt
                        .execute(params![k.as_slice()])
                        .map_err(|e| err(e))?;
                }
                n => return Err(err(format!("an op must have 2 or 3 elements, got {}", n))),
            }
        }
    }

    // The whole batch commits atomically here (journaled to the WAL,
    // crash-recoverable). It is NOT fsync'd per commit — the datom layer
    // commits per datom-group, so a fsync here would be one-per-group;
    // durability-to-disk is the explicit `sqlite_sync` the caller invokes once
    // per transaction. Atomicity holds regardless of the fsync boundary.
    tx.commit().map_err(|e| err(e))?;
    Ok(atoms::ok())
}

/// A marker the host module only has once the NIF has replaced its stubs.
#[rustler::nif]
fn __nif_loaded__() -> bool {
    true
}

rustler::init!("Elixir.BeamLisp.Native.Datom.StoreSqlite");
