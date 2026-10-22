//! Cycle collector for the native memo resources (trial deletion).
//!
//! A memo cell (atom value, delay, promise, lazy node) and a cursor are ERTS
//! resources: reference counted. A cycle through saved terms — an atom whose
//! value holds the atom, a delay whose thunk captures itself through a
//! promise, two atoms pointing at each other, an atom holding a lazy seq that
//! derefs the atom — never reaches zero and was leaked for the VM's lifetime.
//! This module finds such cycles and breaks them, so reference types are
//! structurally leak-free rather than leak-free by programmer discipline.
//!
//! # Soundness
//! Three VM facts carry it. `calibrate` re-proves all three at runtime, on
//! this exact emulator, before the first round; if any fails the collector
//! stays off (`cycle_enabled` false in the stats) and nothing else changes.
//! 1. A resource's refcount counts EVERY holder: each heap copy of its
//!    reference (process heap, ETS row, another resource's saved term — a
//!    saved term is copied WITHOUT sharing, so each occurrence is one count)
//!    and each Rust handle.
//! 2. `term_to_binary` lists each embedded reference once per occurrence and
//!    itself holds no count, so the ETF of a saved term is an exact census of
//!    the counts that term contributes.
//! 3. The refcount and the reference number sit at fixed offsets before the
//!    resource data. ERTS has no public API for either; they are read through
//!    the calibrated offsets.
//!
//! # A round
//! Pin every registered node, trace each one's saved term (censused at most
//! once per state, so a state costs its size at most once in its life), count
//! INTERNAL references (held by traced nodes). A node whose refcount exceeds
//! its internal count is held from outside — a root. Everything a root
//! reaches is live; the rest is garbage candidate `G`.
//!
//! Mutators are never stopped. Validation is two passes over `G`, in this
//! order: (1) every member's outside count is zero; (2) every member is still
//! `quiet` (unread and unchanged since its trace). That is sufficient. After
//! the trace began, a process can gain a reference to a `G` member only by
//! reading a `G` cell (all of `G`'s holders are inside `G`), and the FIRST such
//! read needs a reference held since before the trace. Its holder must have
//! dropped it before pass (1) inspected that cell — so the read happened
//! before pass (2) inspected it, and set `touched`. Hence after both passes no
//! process holds, or can obtain, a reference into `G`.
//!
//! The one residual is ETF revival: `binary_to_term` of a binary taken earlier
//! revives a live resource by reference number. A revived handle to a
//! collected cycle reads as reclaimed (`badarg`), as a weak reference would.
//!
//! Breaking a validated cycle takes each `G` cell's state; the refcounts then
//! fall to zero in ERTS's own order and the ordinary destructors run.

use crate::collector_schedule::Schedule;
use rustler::types::tuple::get_tuple;
use rustler::{Encoder, MapIterator, OwnedEnv, ResourceArc, Term, TermType};
use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicU64, Ordering};
use std::sync::{Condvar, Mutex, OnceLock};

/// A reference number as `term_to_binary` writes it (three 32-bit words).
pub type Key = [u32; 3];

/// What `Node::trace` found.
pub enum Traced {
    /// Holds no state (never filled, or already detached): no edges.
    Vacant,
    /// Holds a term the census could not read: a conservative root.
    Opaque,
    /// Holds a state at this version; its references were visited.
    At(u64),
}

/// A resource the collector can see into.
pub trait Node: Send + Sync {
    /// Forget earlier reads, then visit the key of every resource this node
    /// holds a count on, and report the state's version.
    fn trace(&self, visit: &mut dyn FnMut(&Key)) -> Traced;
    /// Unread and unchanged since `trace` reported `version`?
    fn quiet(&self, version: u64) -> bool;
    /// Give up the held state (None when there is nothing to give up). The
    /// caller drops it outside every lock: dropping releases counts, which may
    /// run destructors.
    fn detach(&self) -> Option<Box<dyn Send>>;
}

// ── registry ────────────────────────────────────────────────────────────────

#[derive(Clone, Copy)]
struct Entry {
    raw: usize,
    node: *const dyn Node,
}
// The pointer is only dereferenced while the resource is pinned.
unsafe impl Send for Entry {}

static REGISTRY: OnceLock<Mutex<HashMap<u64, Entry>>> = OnceLock::new();

fn registry() -> &'static Mutex<HashMap<u64, Entry>> {
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Make a freshly allocated resource visible to the collector.
pub fn register<T: Node + rustler::Resource>(id: u64, resource: &ResourceArc<T>) {
    if !STARTED.load(Ordering::Acquire) {
        return;
    }
    let node: &T = resource;
    let entry = Entry {
        raw: resource.as_c_arg() as usize,
        node: node as &dyn Node as *const dyn Node,
    };
    lock(registry()).insert(id, entry);
    if SCHEDULE.registration() {
        wake();
    }
}

/// Called from the destructor, which runs while the memory is still valid —
/// so an entry the collector copied under this lock is safe to pin.
pub fn unregister(id: u64) {
    lock(registry()).remove(&id);
}

/// The reference number of a resource the caller holds (so it is live).
pub fn key_of<T: rustler::Resource>(resource: &ResourceArc<T>) -> Key {
    layout()
        .map(|l| l.key(resource.as_c_arg() as usize))
        .unwrap_or([0; 3])
}

// ── calibration ─────────────────────────────────────────────────────────────

/// The only unsafe knowledge of ERTS internals, proven at runtime.
struct Layout {
    refc: usize,
    refn: usize,
    refn_reversed: bool,
}

impl Layout {
    fn refc(&self, raw: usize) -> &AtomicIsize {
        unsafe { &*((raw - self.refc) as *const AtomicIsize) }
    }

    fn key(&self, raw: usize) -> Key {
        let mut key = read_key(raw - self.refn);
        if self.refn_reversed {
            key.reverse();
        }
        key
    }
}

fn read_key(addr: usize) -> Key {
    let at = |i: usize| unsafe { std::ptr::read_unaligned((addr + 4 * i) as *const u32) };
    [at(0), at(1), at(2)]
}

fn read_word(addr: usize) -> isize {
    unsafe { std::ptr::read_volatile(addr as *const isize) }
}

struct Probe;
#[rustler::resource_impl]
impl rustler::Resource for Probe {}

/// Bytes before the resource data searched for the header fields. The magic
/// binary header of OTP 26–29 puts them 30–60 bytes back.
const WINDOW: usize = 80;

fn calibrate() -> Result<Layout, &'static str> {
    let probes: Vec<ResourceArc<Probe>> = (0..3).map(|_| ResourceArc::new(Probe)).collect();
    let raws: Vec<usize> = probes.iter().map(|p| p.as_c_arg() as usize).collect();

    // Refcount: an aligned word reading exactly the expected count on every
    // probe, through keep/release and through term copies.
    let mut candidates: Vec<usize> = (8..=WINDOW).collect();
    let expect = |candidates: &mut Vec<usize>, count: isize| {
        candidates.retain(|&k| {
            raws.iter().all(|&raw| {
                (raw - k) % std::mem::align_of::<isize>() == 0 && read_word(raw - k) == count
            })
        })
    };
    expect(&mut candidates, 1);
    for &raw in &raws {
        unsafe { rustler::sys::enif_keep_resource(raw as *const c_void) };
    }
    expect(&mut candidates, 2);
    for &raw in &raws {
        unsafe { rustler::sys::enif_release_resource(raw as *const c_void) };
    }
    expect(&mut candidates, 1);

    // Facts 1 and 2: a heap reference counts once; a saved COPY of a list
    // sharing it three times counts three (copies do not preserve sharing);
    // its ETF lists it three times and holds nothing.
    let mut census = Vec::new();
    let mut copies = Vec::new();
    for probe in &probes {
        let heap = OwnedEnv::new();
        let shared = heap.run(|env| {
            let t = probe.encode(env);
            heap.save(vec![t, t, t].encode(env))
        });
        let copy = OwnedEnv::new();
        let copied = heap.run(|env| copy.save(shared.load(env)));
        census.push(copy.run(|env| etf_keys(copied.load(env).to_binary().as_slice())));
        drop(shared);
        drop(heap);
        copies.push((copied, copy));
    }
    expect(&mut candidates, 4); // its own handle + three copied occurrences
    drop(copies);
    expect(&mut candidates, 1);
    let refc = match candidates[..] {
        [one] => one,
        _ => return Err("refcount offset not unique"),
    };

    // Reference number: the three words the ETF wrote, found at one offset on
    // every probe (each probe has distinct numbers, so this cannot match by
    // accident three times).
    let mut keys = Vec::new();
    for found in census {
        let found = found.ok_or("probe ETF unreadable")?;
        match found[..] {
            [a, b, c] if a == b && b == c => keys.push(a),
            _ => return Err("probe ETF census is not three identical references"),
        }
    }
    for reversed in [false, true] {
        let hits: Vec<usize> = (4..=WINDOW)
            .filter(|&j| {
                raws.iter().zip(&keys).all(|(&raw, key)| {
                    let mut k = read_key(raw - j);
                    if reversed {
                        k.reverse();
                    }
                    k == *key
                })
            })
            .collect();
        if let [refn] = hits[..] {
            let layout = Layout {
                refc,
                refn,
                refn_reversed: reversed,
            };
            // The IN-PLACE census must agree with the proven ETF reader on this
            // exact emulator — every occurrence, order aside — before a single
            // round may rely on it. A walker this build cannot vouch for (a
            // type it mis-classifies, a container it fails to descend) must
            // leave the collector OFF, never collect through a wrong census.
            // The probe term mixes nesting shapes so this proves more than the
            // flat list above: tuple, list-in-list, and list-in-tuple.
            let probe = &probes[0];
            let env = OwnedEnv::new();
            let term = env.run(|e| {
                let t = probe.encode(e);
                let pair = (t, t).encode(e);
                let nested = vec![t, t].encode(e);
                env.save(vec![t, pair, nested].encode(e))
            });
            let by_etf = env.run(|e| etf_keys(term.load(e).to_binary().as_slice()));
            let by_walk = env.run(|e| {
                census_keys(term.load(e), |t| {
                    t.decode::<ResourceArc<Probe>>()
                        .ok()
                        .map(|p| layout.key(p.as_c_arg() as usize))
                })
            });
            match (sorted_keys(by_walk), sorted_keys(by_etf)) {
                (Some(walk), Some(etf)) if !walk.is_empty() && walk == etf => {}
                _ => return Err("the in-place census disagrees with the ETF census"),
            }
            return Ok(layout);
        }
    }
    Err("reference number offset not found")
}

/// A census answer with its occurrences in a canonical order, so two readers
/// that visit the same occurrences in different orders compare equal. The
/// collector counts occurrences, so order carries no meaning to it.
fn sorted_keys(keys: Option<Vec<Key>>) -> Option<Vec<Key>> {
    keys.map(|mut keys| {
        keys.sort();
        keys
    })
}

static LAYOUT: OnceLock<Option<Layout>> = OnceLock::new();

fn layout() -> Option<&'static Layout> {
    LAYOUT
        .get_or_init(|| {
            calibrate()
                .map_err(|why| *CALIBRATION_ERROR.lock().unwrap() = why)
                .ok()
        })
        .as_ref()
}

static CALIBRATION_ERROR: Mutex<&'static str> = Mutex::new("");

pub fn enabled() -> bool {
    STARTED.load(Ordering::Acquire) && layout().is_some()
}

// ── ETF census ──────────────────────────────────────────────────────────────

/// Every three-word reference in `etf`, in order — or None on a tag this
/// reader does not know (the node is then a conservative root). ETF is prefix
/// order, so a single `pending` counter replaces a stack: a container adds
/// its children, every term consumes one.
///
/// This is the reference reader for a term that has to be SERIALISED: the
/// `Seen` set's admitted keys, the calibration probes, and the `census_keys`
/// fallback for a closure (no public accessor for its captures) or an
/// unclassified term. A whole state is walked in place instead.
pub fn etf_keys(etf: &[u8]) -> Option<Vec<Key>> {
    let mut r = Reader { bytes: etf, at: 0 };
    if r.u8()? != 131 {
        return None;
    }
    let mut keys = Vec::new();
    let mut pending: usize = 1;
    while pending > 0 {
        pending -= 1;
        let children = match r.u8()? {
            97 => r.skip(1)?,
            98 => r.skip(4)?,
            70 => r.skip(8)?,
            99 => r.skip(31)?,
            106 => 0,
            100 | 107 | 118 => {
                let n = r.u16()?;
                r.skip(n)?
            }
            115 | 119 => {
                let n = r.u8()?;
                r.skip(n)?
            }
            109 => {
                let n = r.u32()?;
                r.skip(n)?
            }
            77 => {
                let n = r.u32()?;
                r.skip(1 + n)?
            }
            110 => {
                let n = r.u8()?;
                r.skip(1 + n)?
            }
            111 => {
                let n = r.u32()?;
                r.skip(1 + n)?
            }
            104 => r.u8()?,
            105 => r.u32()?,
            108 => r.u32()?.checked_add(1)?, // elements + tail
            116 => r.u32()?.checked_mul(2)?,
            113 => 3, // export: module, function, arity
            88 => {
                r.atom()?;
                r.skip(12)? // new pid: id, serial, creation
            }
            89 => {
                r.atom()?;
                r.skip(8)?
            }
            120 => {
                r.atom()?;
                r.skip(12)?
            }
            90 => {
                let words = r.u16()?;
                r.atom()?;
                r.skip(4)?; // creation
                let id = r.take(4 * words)?;
                if words == 3 {
                    let w = |i: usize| u32::from_be_bytes(id[4 * i..4 * i + 4].try_into().unwrap());
                    keys.push([w(0), w(1), w(2)]);
                }
                0
            }
            112 => {
                // new fun: size, arity, uniq, index, then the free-variable
                // count; module, old index, old uniq and pid are terms.
                r.skip(4 + 1 + 16 + 4)?;
                r.u32()?.checked_add(4)?
            }
            _ => return None,
        };
        pending = pending.checked_add(children)?;
    }
    Some(keys)
}

// ── in-place census ─────────────────────────────────────────────────────────

/// Every reference `term` holds, ONCE PER OCCURRENCE — read by walking the term
/// IN PLACE, with no whole-term export.
///
/// The whole-cell censuses that came before this walked `term_to_binary`: the
/// state was serialised to ETF (a fresh allocation the size of the term) and the
/// bytes were parsed, both under the cell's own state lock. This walk reaches
/// the same occurrences through the NIF's public shape API instead:
///
/// * `Term::get_type` (an `enif_term_type` call) classifies every subterm. No
///   assumption is made about ERTS's word layout — this is the public API.
/// * a cons, tuple or map is descended element by element, so the answer is
///   occurrence-EXACT: a term holding the same resource 20 times reports 20
///   keys, exactly as `term_to_binary` did, not one key for a unique node.
/// * a resource is recognised by the resource API itself — `resource_key`
///   answers the collector key of a subterm that IS a collector node, and None
///   for everything else (a plain reference, a resource of another type).
///
/// Two shapes still need the ETF reader above, on that SUBTERM alone:
///   * a closure — the installed NIF API exposes no accessor for a fun's
///     captured environment, and a closure may capture a resource, so its
///     captures are read from its own ETF;
///   * a type this build cannot classify (`TermType::Unknown`), which is read
///     rather than guessed at.
///
/// `None` means a subterm could not be read at all: the caller MUST treat the
/// node as an OPAQUE root — a conservative root that is never collected through.
///
/// The worklist is explicit, so a deeply nested term costs heap, not stack.
pub fn census_keys<'a, F>(term: Term<'a>, resource_key: F) -> Option<Vec<Key>>
where
    F: Fn(Term<'a>) -> Option<Key>,
{
    let mut keys = Vec::new();
    let mut pending: Vec<Term<'a>> = vec![term];
    while let Some(current) = pending.pop() {
        match current.get_type() {
            // A leaf: no reference can be inside it.
            TermType::Atom
            | TermType::Integer
            | TermType::Float
            | TermType::Binary
            | TermType::Pid
            | TermType::Port => {}
            // A plain reference is a leaf; a collector node's reference is a key.
            TermType::Ref => {
                if let Some(key) = resource_key(current) {
                    keys.push(key);
                }
            }
            TermType::List => {
                let mut cell = current;
                loop {
                    if cell.is_empty_list() {
                        break;
                    }
                    match cell.list_get_cell() {
                        Ok((head, tail)) => {
                            push(&mut pending, head);
                            cell = tail;
                        }
                        // An improper tail (`[1 | foo]`) is a term on its own.
                        // The classifier guard is what makes this loop
                        // terminate: a term that is not a cons cannot be a
                        // list, so a `List` answer here must not re-enter.
                        Err(_) => {
                            if !matches!(cell.get_type(), TermType::List) {
                                push(&mut pending, cell);
                            }
                            break;
                        }
                    }
                }
            }
            TermType::Tuple => {
                for element in get_tuple(current).ok()? {
                    push(&mut pending, element);
                }
            }
            TermType::Map => {
                for (key, value) in MapIterator::new(current)? {
                    push(&mut pending, key);
                    push(&mut pending, value);
                }
            }
            // No public accessor for a closure's captures; an unclassified
            // term is read rather than guessed at. Both are read from their
            // OWN ETF, so the rest of the term is never serialised.
            TermType::Fun | TermType::Unknown => {
                keys.extend(etf_keys(current.to_binary().as_slice())?);
            }
        }
    }
    Some(keys)
}

/// Queue a subterm unless it can hold no reference at all. A flat list of
/// numbers — the common shape of a produced chunk or a range's backing — then
/// costs one shape test per element and no worklist growth.
fn push<'a>(pending: &mut Vec<Term<'a>>, term: Term<'a>) {
    if !matches!(
        term.get_type(),
        TermType::Atom
            | TermType::Integer
            | TermType::Float
            | TermType::Binary
            | TermType::Pid
            | TermType::Port
    ) {
        pending.push(term);
    }
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let end = self.at.checked_add(n)?;
        let out = self.bytes.get(self.at..end)?;
        self.at = end;
        Some(out)
    }
    /// Skip `n` bytes; a leaf has no children.
    fn skip(&mut self, n: usize) -> Option<usize> {
        self.take(n).map(|_| 0)
    }
    fn u8(&mut self) -> Option<usize> {
        self.take(1).map(|b| b[0] as usize)
    }
    fn u16(&mut self) -> Option<usize> {
        self.take(2)
            .map(|b| u16::from_be_bytes([b[0], b[1]]) as usize)
    }
    fn u32(&mut self) -> Option<usize> {
        self.take(4)
            .map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]) as usize)
    }
    fn atom(&mut self) -> Option<()> {
        match self.u8()? {
            100 | 118 => {
                let n = self.u16()?;
                self.skip(n).map(drop)
            }
            115 | 119 => {
                let n = self.u8()?;
                self.skip(n).map(drop)
            }
            _ => None,
        }
    }
}

// ── the round ───────────────────────────────────────────────────────────────

pub static RUNS: AtomicU64 = AtomicU64::new(0);
pub static ABORTS: AtomicU64 = AtomicU64::new(0);
pub static COLLECTED: AtomicU64 = AtomicU64::new(0);
pub static ANOMALIES: AtomicU64 = AtomicU64::new(0);

/// A counted hold on a node for the duration of a round.
struct Pin {
    raw: usize,
    node: *const dyn Node,
}

impl Pin {
    /// Take a count on a live resource; None for one already at zero (its
    /// destructor is waiting on the registry lock this caller holds).
    fn new(layout: &Layout, entry: Entry) -> Option<Pin> {
        let refc = layout.refc(entry.raw);
        let mut count = refc.load(Ordering::Acquire);
        loop {
            if count <= 0 {
                return None;
            }
            match refc.compare_exchange_weak(count, count + 1, Ordering::AcqRel, Ordering::Acquire)
            {
                Ok(_) => break,
                Err(now) => count = now,
            }
        }
        // Swap the raw increment for an API-owned one, so the release below
        // is the ordinary path (and a debug emulator's shadow count agrees).
        unsafe { rustler::sys::enif_keep_resource(entry.raw as *const c_void) };
        refc.fetch_sub(1, Ordering::AcqRel);
        Some(Pin {
            raw: entry.raw,
            node: entry.node,
        })
    }

    fn node(&self) -> &dyn Node {
        unsafe { &*self.node }
    }
}

impl Drop for Pin {
    fn drop(&mut self) {
        unsafe { rustler::sys::enif_release_resource(self.raw as *const c_void) };
    }
}

static ROUND: Mutex<()> = Mutex::new(());

/// Run one round; answers how many nodes were detached.
pub fn collect() -> usize {
    if !enabled() {
        return 0;
    }
    let Some(layout) = layout() else { return 0 };
    let _one_at_a_time = lock(&ROUND);
    RUNS.fetch_add(1, Ordering::Relaxed);

    let pins: Vec<Pin> = {
        let registry = lock(registry());
        registry
            .values()
            .filter_map(|&e| Pin::new(layout, e))
            .collect()
    };
    let n = pins.len();
    let index: HashMap<Key, usize> = pins
        .iter()
        .enumerate()
        .map(|(i, p)| (layout.key(p.raw), i))
        .collect();

    // Census: internal counts and edges, from each node's traced state.
    let mut internal = vec![0isize; n];
    let mut edges: Vec<Vec<usize>> = vec![Vec::new(); n];
    let mut traced = Vec::with_capacity(n);
    for (i, pin) in pins.iter().enumerate() {
        traced.push(pin.node().trace(&mut |key| {
            if let Some(&j) = index.get(key) {
                internal[j] += 1;
                edges[i].push(j);
            }
        }));
    }
    let outside = |i: usize| layout.refc(pins[i].raw).load(Ordering::Acquire) - 1 - internal[i];

    // Mark: whatever a root reaches is live.
    let mut live = vec![false; n];
    let mut stack: Vec<usize> = (0..n)
        .filter(|&i| matches!(traced[i], Traced::Opaque) || outside(i) != 0)
        .collect();
    while let Some(i) = stack.pop() {
        if !std::mem::replace(&mut live[i], true) {
            stack.extend(edges[i].iter().copied().filter(|&j| !live[j]));
        }
    }
    let garbage: Vec<(usize, u64)> = (0..n)
        .filter(|&i| !live[i])
        .filter_map(|i| match traced[i] {
            Traced::At(version) => Some((i, version)),
            _ => None,
        })
        .collect();

    // Validate the whole set before touching any of it — counts FIRST, then
    // quiet (the order is the soundness argument in the module header).
    let valid = garbage.iter().all(|&(i, _)| outside(i) == 0)
        && garbage
            .iter()
            .all(|&(i, version)| pins[i].node().quiet(version));
    if !valid {
        ABORTS.fetch_add(1, Ordering::Relaxed);
        return 0;
    }
    let detached: Vec<Box<dyn Send>> = garbage
        .iter()
        .filter_map(|&(i, _)| pins[i].node().detach())
        .collect();
    let count = detached.len();
    COLLECTED.fetch_add(count as u64, Ordering::Relaxed);
    // States first (the pins keep every node's memory valid while cascading
    // releases run), then the pins themselves.
    drop(detached);
    drop(pins);
    count
}

// ── scheduling ──────────────────────────────────────────────────────────────

/// Counts amortize O(nodes); accounted committed growth amortizes O(saved
/// bytes). This same worker services both, including arrivals during a round.
static SCHEDULE: Schedule = Schedule::new();

/// Call only after actual allocation/publication and after graph/state locks
/// are dropped. Reservations, retries, and failed publications are not growth.
/// This function only records demand; it never scans or runs user code.
pub fn note_growth(bytes: usize) {
    if STARTED.load(Ordering::Acquire) && SCHEDULE.growth(bytes) {
        wake();
    }
}

static WAKE: (Mutex<bool>, Condvar) = (Mutex::new(false), Condvar::new());
static STOP: AtomicBool = AtomicBool::new(false);
static WORKER: Mutex<Option<std::thread::JoinHandle<()>>> = Mutex::new(None);
static STARTED: AtomicBool = AtomicBool::new(false);
static START_ERROR: Mutex<&'static str> = Mutex::new("");

fn wake() {
    *lock(&WAKE.0) = true;
    WAKE.1.notify_one();
}

pub fn start() -> std::io::Result<()> {
    STOP.store(false, Ordering::Release);
    STARTED.store(false, Ordering::Release);
    *lock(&START_ERROR) = "";
    let worker = std::thread::Builder::new()
        .name("beam-lisp-cycle-collector".into())
        .spawn(|| {
            let mut settling = false;
            loop {
                let _ = layout(); // calibrate once, off the schedulers
                {
                    let mut woken = lock(&WAKE.0);
                    while !*woken {
                        if settling {
                            // A threshold round can observe the last producer's
                            // roots before its process exits. One delayed sweep
                            // reclaims that tail even when no further allocations
                            // arrive to cross another threshold. Idle collectors
                            // do not poll, and shutdown still wakes immediately.
                            let (guard, elapsed) = WAKE
                                .1
                                .wait_timeout(woken, std::time::Duration::from_millis(100))
                                .unwrap_or_else(|p| p.into_inner());
                            woken = guard;
                            if elapsed.timed_out() {
                                settling = false;
                                break;
                            }
                        } else {
                            woken = WAKE.1.wait(woken).unwrap_or_else(|p| p.into_inner());
                        }
                    }
                    if *woken {
                        settling = true;
                    }
                    *woken = false;
                }
                if STOP.load(Ordering::Acquire) {
                    return;
                }
                if SCHEDULE.begin_round() {
                    wake();
                }
                if std::panic::catch_unwind(collect).is_err() {
                    ANOMALIES.fetch_add(1, Ordering::Relaxed);
                }
                let live = lock(registry()).len();
                if SCHEDULE.finish_round(live, crate::accounted_retained_bytes()) {
                    wake();
                }
            }
        });
    record_worker_start(worker);
    Ok(())
}

fn record_worker_start(worker: std::io::Result<std::thread::JoinHandle<()>>) {
    match worker {
        Ok(worker) => {
            *lock(&WORKER) = Some(worker);
            STARTED.store(true, Ordering::Release);
        }
        Err(_) => {
            // Collection is optional. A thread-spawn refusal must not prevent
            // the mandatory memo-cell NIF from loading or claim it is enabled.
            *lock(&START_ERROR) = "collector thread could not start";
        }
    }
}

pub fn stop() {
    STARTED.store(false, Ordering::Release);
    STOP.store(true, Ordering::Release);
    wake();
    if let Some(worker) = lock(&WORKER).take() {
        let _ = worker.join();
    }
}

pub fn calibration_error() -> &'static str {
    let _ = layout();
    let calibration = *lock(&CALIBRATION_ERROR);
    if calibration.is_empty() {
        *lock(&START_ERROR)
    } else {
        calibration
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `term_to_binary({R, [R, 1 | R], #{k => fun() -> {R, 7, R} end}, <<1,2,3>>,
    /// 1.5, self(), make_ref(), fun erlang:self/0, 123456789012345678901234567890,
    /// "str", -5, 300})` from OTP 29, R an atomics ref: R appears 4 times (the fun
    /// captures it once), make_ref() once.
    #[test]
    fn census_counts_every_reference_occurrence() {
        let etf: Vec<u8> = include_str!("../fixtures/census.etf")
            .trim()
            .split(',')
            .map(|b| b.trim().parse().unwrap())
            .collect();
        let keys = etf_keys(&etf).expect("parses");
        assert_eq!(keys.len(), 5);
        let r = keys[0];
        assert_eq!(keys.iter().filter(|k| **k == r).count(), 4);
    }

    #[test]
    fn collector_thread_refusal_disables_only_collection() {
        STARTED.store(false, Ordering::Release);
        *lock(&START_ERROR) = "";
        record_worker_start(Err(std::io::Error::other("thread unavailable")));
        assert!(!enabled());
        assert_eq!(collect(), 0);
        assert_eq!(*lock(&START_ERROR), "collector thread could not start");
        *lock(&START_ERROR) = "";
    }

    #[test]
    fn census_refuses_what_it_cannot_read() {
        assert!(etf_keys(&[131, 200]).is_none());
        assert!(etf_keys(&[130, 106]).is_none());
        assert!(etf_keys(&[131, 104, 2, 106]).is_none(), "truncated tuple");
        assert_eq!(etf_keys(&[131, 106]), Some(vec![]));
    }

    #[test]
    fn the_census_canonical_order_keeps_every_occurrence() {
        // The in-place walk and the ETF reader visit the same occurrences in
        // different orders (the walk pops a LIFO worklist). The calibration
        // compares them by occurrence, NOT by position — so a repeated
        // reference must survive canonicalisation as many times as it appears.
        let one = [7, 8, 9];
        let two = [1, 2, 3];
        let walked = Some(vec![one, two, one]);
        let etf = Some(vec![one, one, two]);
        assert_eq!(sorted_keys(walked.clone()), sorted_keys(etf));
        let canonical = sorted_keys(walked).expect("readable");
        assert_eq!(canonical.iter().filter(|k| **k == one).count(), 2);
        assert_ne!(
            sorted_keys(Some(vec![one])),
            sorted_keys(Some(vec![one, two]))
        );
        assert_eq!(sorted_keys(None), None);
    }
}
