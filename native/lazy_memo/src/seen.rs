//! `Seen`: the membership set behind `distinct`, owned natively.
//!
//! `distinct` must remember every key it has emitted. Kept as a persistent set
//! threaded through the chunk continuation, that set lived in every memo cell's
//! saved thunk, so each chunk copied the whole set in and out: O(n²/32). A
//! `Seen` is a resource, so a cell captures an O(1) handle and each key is
//! copied exactly once, when it is admitted: O(n) for the whole walk.
//!
//! Admission is one call per chunk, AFTER the chunk's keys are computed: every
//! fallible step (forcing the input, calling `keyfn`) happens first, so a
//! chunk attempt that throws admits nothing and its retry sees exactly the keys
//! of the chunks before it. Chunks of one `distinct` run strictly in order
//! (chunk k+1's thunk exists only once chunk k sealed), so no two admits for
//! one set ever race; the mutex is for memory safety, not ordering.
//!
//! Membership is BEAM exact equality (`=:=`) on the caller's `hash_key`ed
//! terms — the relation a `MapSet` key uses.

use crate::collector::{self, register, unregister, Key, Node, Traced};
use rustler::env::SavedTerm;
use rustler::{Env, OwnedEnv, ResourceArc, Term, TermType};
use std::collections::HashMap;
use std::sync::Mutex;

pub struct Seen {
    id: u64,
    table: Mutex<Table>,
}

struct Table {
    // Saved terms before the environment that backs them (drop order).
    buckets: HashMap<u32, Vec<SavedTerm>>,
    env: OwnedEnv,
    /// Every resource reference the admitted keys hold, for the collector.
    refs: Vec<Key>,
    /// A key the ETF census could not read: the set is then a collector root.
    opaque: bool,
}

#[rustler::resource_impl]
impl rustler::Resource for Seen {
    fn destructor(self, _env: Env<'_>) {
        unregister(self.id);
    }
}

impl Seen {
    pub fn arc(id: u64) -> ResourceArc<Seen> {
        let seen = ResourceArc::new(Seen {
            id,
            table: Mutex::new(Table {
                buckets: HashMap::new(),
                env: OwnedEnv::new(),
                refs: Vec::new(),
                opaque: false,
            }),
        });
        register(id, &seen);
        seen
    }

    /// For each key in order: true when it was not yet a member (it is one
    /// now). A key repeated inside one batch is admitted at its first place.
    pub fn admit(&self, keys: &[Term<'_>]) -> Vec<bool> {
        let mut guard = self.table.lock().unwrap_or_else(|p| p.into_inner());
        let table = &mut *guard;
        keys.iter()
            .map(|&key| {
                let bucket = table.buckets.entry(key.hash_internal(0)).or_default();
                if bucket.iter().any(|saved| table.env.run(|env| saved.load(env) == key)) {
                    return false;
                }
                if !matches!(
                    key.get_type(),
                    TermType::Atom | TermType::Integer | TermType::Float | TermType::Binary
                ) {
                    match collector::etf_keys(key.to_binary().as_slice()) {
                        Some(found) => table.refs.extend(found),
                        None => table.opaque = true,
                    }
                }
                bucket.push(table.env.save(key));
                true
            })
            .collect()
    }
}

/// The set only grows, and only through `admit`, whose caller holds the
/// handle — so a set no process can reach cannot change: always quiet. It
/// never detaches; it is freed with the last cell that captured it.
impl Node for Seen {
    fn trace(&self, visit: &mut dyn FnMut(&Key)) -> Traced {
        let table = self.table.lock().unwrap_or_else(|p| p.into_inner());
        if table.opaque {
            return Traced::Opaque;
        }
        table.refs.iter().for_each(|k| visit(k));
        Traced::At(0)
    }
    fn quiet(&self, _version: u64) -> bool {
        true
    }
    fn detach(&self) -> Option<Box<dyn Send>> {
        None
    }
}
