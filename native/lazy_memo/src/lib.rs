//! Native ownership cell for LazySeq memo state.
//!
//! Resource terms are version-local: hot upgrades must drain all cells before
//! unloading this NIF. Rustler resource types from different module versions
//! are intentionally not treated as interchangeable.

use rustler::env::SavedTerm;
use rustler::{Atom, Env, Encoder, LocalPid, NifMap, NifResult, OwnedEnv, ResourceArc, Term};
use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::collections::{HashMap, HashSet};
use std::mem::size_of;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{mpsc, Mutex, MutexGuard, OnceLock};

rustler::atoms! { ok, retry, cycle, fast, dirty, reroute, keep }

mod collector;
mod seen;
use collector::{register, unregister, Key, Node, Traced};

/// Byte ceiling for the fast (regular-scheduler) lane. A regular NIF must
/// return in well under 1 ms or it stalls every process on its scheduler.
/// Copying a term through an OwnedEnv is memcpy-order work; 64 KiB keeps the
/// fast path comfortably sub-100 us on this class of hardware. Larger cells
/// take the dirty lane exactly as before. Tunable via `nif_set_fast_lane_bytes`.
const DEFAULT_FAST_LANE_BYTES: usize = 64 * 1024;
static FAST_LANE_BYTES: AtomicUsize = AtomicUsize::new(DEFAULT_FAST_LANE_BYTES);

fn fast_lane_bytes() -> usize {
    FAST_LANE_BYTES.load(Ordering::Acquire)
}

static NEXT_ID: AtomicU64 = AtomicU64::new(1);
static LIVE_CELLS: AtomicUsize = AtomicUsize::new(0);
static RETAINED_BYTES: AtomicUsize = AtomicUsize::new(0);
static PENDING_RECLAIMS: AtomicUsize = AtomicUsize::new(0);

// ── Phase-0 probes (PLAN-132): boundary crossings per entry point ──────────
// Every BEAM->Rust call bumps exactly one slot. The point is the RATIO:
// `op_lane` is a crossing that exists only to route another crossing (F1),
// `op_dep_resource`/`op_id` are the per-handle tax of the Elixir-side
// dependency walk (F5). A healthy system has op_lane == 0 and read calls
// equal to the number of logical reads.
const OP_NEW: usize = 0;
const OP_NEW_FAST: usize = 1;
const OP_READ: usize = 2;
const OP_READ_FAST: usize = 3;
const OP_LANE: usize = 4;
const OP_CAS: usize = 5;
const OP_CAS_FAST: usize = 6;
const OP_REROUTE: usize = 7;
const OP_RETRY: usize = 8;
const OP_CYCLE: usize = 9;
const OP_DEP_RESOURCE: usize = 10;
const OP_ID: usize = 11;
const OP_CURSOR: usize = 12;
const OP_CURSOR_CHUNK: usize = 13;
const OP_CURSOR_CHUNK_FAST: usize = 14;
const OP_COUNT: usize = 15;
static OPS: [AtomicU64; OP_COUNT] = [const { AtomicU64::new(0) }; OP_COUNT];

fn count(op: usize) {
    OPS[op].fetch_add(1, Ordering::Relaxed);
}
static GRAPH: OnceLock<Mutex<HashMap<u64, Vec<u64>>>> = OnceLock::new();
struct Reclaimer {
    sender: mpsc::Sender<OwnedEnv>,
    worker: std::thread::JoinHandle<()>,
}
static RECLAIMER: Mutex<Option<Reclaimer>> = Mutex::new(None);
thread_local! {
    static LOCAL_RECLAIMS: RefCell<VecDeque<OwnedEnv>> = const { RefCell::new(VecDeque::new()) };
    static DRAINING: Cell<bool> = const { Cell::new(false) };
}

struct State {
    // Declaration order matters: SavedTerm must disappear before its backing
    // environment. Rust drops fields in declaration order.
    term: SavedTerm,
    env: OwnedEnv,
    retained_bytes: usize,
    /// The references this term holds, as the cycle collector's ETF census
    /// found them — computed at most once per state (None: unreadable).
    census: OnceLock<Option<Vec<Key>>>,
}

impl State {
    fn census(&self) -> Option<&[Key]> {
        self.census
            .get_or_init(|| {
                self.env
                    .run(|env| collector::etf_keys(self.term.load(env).to_binary().as_slice()))
            })
            .as_deref()
    }
}

/// The cell's publication counter (PLAN-151 W5). Every successful replace
/// bumps it, so a claim can be a pure integer compare: no term is loaded and no
/// term is compared. A plain `AtomicU64` — all ordering is provided by the
/// state mutex, which every reader and writer holds across the read/write of
/// both the counter and the term.
struct Version(AtomicU64);

impl Version {
    fn new() -> Self {
        Version(AtomicU64::new(0))
    }

    fn get(&self) -> u64 {
        self.0.load(Ordering::Relaxed)
    }

    /// O(1) compare-and-swap precondition: has the cell moved since the caller
    /// read it?
    fn matches(&self, expected: u64) -> bool {
        self.get() == expected
    }

    fn bump(&self) -> u64 {
        self.0.fetch_add(1, Ordering::Relaxed) + 1
    }
}

struct MemoCell {
    id: u64,
    read_only: bool,
    version: Version,
    /// Set by every read that hands this cell's term to a process (`export`).
    /// The cycle collector clears it when it traces the cell and refuses to
    /// reclaim a cell it then finds set.
    touched: AtomicBool,
    state: Mutex<Option<State>>,
}

impl MemoCell {
    /// Copy the state out into `env`. EVERY path that returns a cell's term to
    /// a process goes through here — the collector's soundness rests on it.
    fn export<'a>(&self, state: &State, env: Env<'a>) -> Term<'a> {
        self.touched.store(true, Ordering::Release);
        state.env.run(|owned| state.term.load(owned).in_env(env))
    }
}

impl Node for MemoCell {
    fn trace(&self, visit: &mut dyn FnMut(&Key)) -> Traced {
        let guard = lock(&self.state);
        self.touched.store(false, Ordering::Release);
        let Some(state) = guard.as_ref() else { return Traced::Vacant };
        match state.census() {
            Some(keys) => {
                keys.iter().for_each(|k| visit(k));
                Traced::At(self.version.get())
            }
            None => Traced::Opaque,
        }
    }

    fn quiet(&self, version: u64) -> bool {
        let _guard = lock(&self.state);
        !self.touched.load(Ordering::Acquire) && self.version.matches(version)
    }

    fn detach(&self) -> Option<Box<dyn Send>> {
        let state = lock(&self.state).take()?;
        saturating_sub(&RETAINED_BYTES, state.retained_bytes);
        Some(Box::new(state))
    }
}

/// How a versioned exchange treats the cell's dependency EDGES.
///
/// `Keep` leaves them exactly as they are: a claim, a waiter registration or a
/// terminal transition changes no reachable resource, so there is nothing to
/// walk and nothing to check — no graph lock work at all.
///
/// `Union` adds the ids of the caller's term. Only genuinely NEW ids are
/// cycle-checked (`added`); the rest were already accepted by an earlier
/// transition of this same cell, and re-walking them would make a chain
/// quadratic (the walk is unbounded in the reachable set).
///
/// EDGES NEVER SHRINK while a cell is alive. They exist for one question —
/// `would_cycle` — and a retained stale edge can only reject a publication that
/// would close a cycle through an edge the cell really did hold at some point.
/// The alternative (replacing them with each state's own walk) is what made the
/// abandoned design quadratic: a claim that drops an edge forces the next
/// publish to re-add it, and every re-add pays a full reachable-set walk.
enum Deps {
    Keep,
    Union(Vec<ResourceArc<MemoCell>>),
}

impl Deps {
    fn decode(term: Term<'_>) -> NifResult<Deps> {
        if term.decode::<Atom>().ok() == Some(keep()) {
            return Ok(Deps::Keep);
        }
        term.decode::<Vec<ResourceArc<MemoCell>>>()
            .map(Deps::Union)
            .map_err(|_| rustler::Error::BadArg)
    }

    /// The dependency ids to union in, or `None` for `Keep`.
    fn ids(self) -> Option<Vec<u64>> {
        match self {
            Deps::Keep => None,
            Deps::Union(resources) => Some(dependency_ids(resources)),
        }
    }
}

/// `(added, merged)`: the ids the cycle walk must consider (those not already
/// an edge) and the union to publish (never smaller than `previous`).
fn edge_plan(previous: &[u64], new_ids: &[u64]) -> (Vec<u64>, Vec<u64>) {
    let mut merged = previous.to_vec();
    let mut added = Vec::new();
    for id in new_ids {
        if !merged.contains(id) {
            added.push(*id);
            merged.push(*id);
        }
    }
    (added, merged)
}

#[rustler::resource_impl]
impl rustler::Resource for MemoCell {
    fn destructor(self, _env: Env<'_>) {
        let state = mutex_value(self.state).take();

        // Never drop a SavedTerm environment while graph/cell locks are held:
        // embedded resource releases can invoke more MemoCell destructors.
        unregister(self.id);
        lock(graph()).remove(&self.id);
        LIVE_CELLS.fetch_sub(1, Ordering::AcqRel);

        if let Some(state) = state {
            saturating_sub(&RETAINED_BYTES, state.retained_bytes);
            reclaim_state(state);
        }
    }
}

#[derive(NifMap)]
struct MemoStats {
    live_cells: usize,
    retained_bytes: usize,
    pending_reclaims: usize,
    // Phase-0 probes (PLAN-132): BEAM<->Rust crossings per entry point.
    // `op_lane` should trend to 0 once reads self-guard (F1);
    // `op_dep_resource` + `op_id` price the Elixir-side dependency walk (F5).
    op_new: u64,
    op_new_fast: u64,
    op_read: u64,
    op_read_fast: u64,
    op_lane: u64,
    op_cas: u64,
    op_cas_fast: u64,
    op_reroute: u64,
    op_retry: u64,
    op_cycle: u64,
    op_dep_resource: u64,
    op_id: u64,
    op_cursor: u64,
    op_cursor_chunk: u64,
    op_cursor_chunk_fast: u64,
    // The cycle collector: whether the calibration passed on this emulator,
    // rounds run / abandoned (a validated set changed under it), cells freed.
    cycle_enabled: bool,
    cycle_runs: u64,
    cycle_aborts: u64,
    cycle_collected: u64,
    // Rounds that panicked (a bug; the round is dropped, nothing is freed).
    cycle_anomalies: u64,
}

fn graph() -> &'static Mutex<HashMap<u64, Vec<u64>>> {
    GRAPH.get_or_init(|| Mutex::new(HashMap::new()))
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn mutex_value<T>(mutex: Mutex<T>) -> T {
    mutex
        .into_inner()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn accounted_bytes(estimate: u64) -> NifResult<usize> {
    let estimate = usize::try_from(estimate).map_err(|_| rustler::Error::BadArg)?;
    Ok(size_of::<MemoCell>().saturating_add(estimate))
}

fn save(term: Term<'_>, retained_bytes: usize) -> State {
    let env = OwnedEnv::new();
    let saved = env.save(term);
    State {
        term: saved,
        env,
        retained_bytes,
        census: OnceLock::new(),
    }
}

fn dependency_ids(dependencies: Vec<ResourceArc<MemoCell>>) -> Vec<u64> {
    let mut seen = HashSet::with_capacity(dependencies.len());
    dependencies
        .into_iter()
        .filter_map(|resource| seen.insert(resource.id).then_some(resource.id))
        .collect()
}

fn would_cycle(edges: &HashMap<u64, Vec<u64>>, source: u64, dependencies: &[u64]) -> bool {
    let mut pending = dependencies.to_vec();
    let mut seen = HashSet::new();
    while let Some(id) = pending.pop() {
        if id == source {
            return true;
        }
        if seen.insert(id) {
            if let Some(next) = edges.get(&id) {
                pending.extend_from_slice(next);
            }
        }
    }
    false
}

fn saturating_add(counter: &AtomicUsize, amount: usize) {
    let _ = counter.fetch_update(Ordering::AcqRel, Ordering::Acquire, |old| {
        Some(old.saturating_add(amount))
    });
}

fn saturating_sub(counter: &AtomicUsize, amount: usize) {
    let _ = counter.fetch_update(Ordering::AcqRel, Ordering::Acquire, |old| {
        Some(old.saturating_sub(amount))
    });
}

fn start_reclaimer() -> std::io::Result<()> {
    let (sender, receiver) = mpsc::channel::<OwnedEnv>();
    let worker = std::thread::Builder::new()
        .name("beam-lisp-lazy-reclaimer".into())
        .spawn(move || {
            while let Ok(env) = receiver.recv() {
                drop(env);
                PENDING_RECLAIMS.fetch_sub(1, Ordering::AcqRel);
            }
        })?;
    *lock(&RECLAIMER) = Some(Reclaimer { sender, worker });
    Ok(())
}

fn reclaim_inline(env: OwnedEnv) {
    LOCAL_RECLAIMS.with(|queue| queue.borrow_mut().push_back(env));
    if DRAINING.with(|flag| flag.replace(true)) {
        return;
    }
    loop {
        let next = LOCAL_RECLAIMS.with(|queue| queue.borrow_mut().pop_front());
        match next {
            Some(env) => drop(env),
            None => break,
        }
    }
    DRAINING.with(|flag| flag.set(false));
}

fn enqueue_reclaim(env: OwnedEnv) {
    let sender = lock(&RECLAIMER)
        .as_ref()
        .map(|worker| worker.sender.clone());
    if let Some(sender) = sender {
        PENDING_RECLAIMS.fetch_add(1, Ordering::AcqRel);
        if let Err(error) = sender.send(env) {
            PENDING_RECLAIMS.fetch_sub(1, Ordering::AcqRel);
            reclaim_inline(error.0);
        }
    } else {
        // During unload descendants release iteratively on the draining thread.
        // Never recurse down an arbitrarily long chain on a native stack.
        reclaim_inline(env);
    }
}

fn reclaim_state(state: State) {
    let State { term, env, .. } = state;
    drop(term);
    enqueue_reclaim(env);
}

/// Fast-lane reclaim. The reclaimer thread exists so that freeing a LARGE
/// term never stalls a scheduler; for a term under the fast-lane ceiling the
/// free is memcpy-order and the channel hop is pure overhead. Drop it here.
fn reclaim_state_small(state: State) {
    let State { term, env, .. } = state;
    drop(term);
    drop(env);
}

/// Dirty lane: a large initial value copies megabytes into the cell.
#[rustler::nif(name = "nif_new", schedule = "DirtyCpu")]
fn new(
    state: Term<'_>,
    dependencies: Vec<ResourceArc<MemoCell>>,
    estimate: u64,
) -> NifResult<ResourceArc<MemoCell>> {
    count(OP_NEW);
    allocate(state, dependencies, estimate, false)
}

/// Fast lane: regular scheduler. `LazyMemo.create` routes here only when the
/// estimate is under the fast-lane ceiling, so the initial copy is bounded.
#[rustler::nif(name = "nif_new_fast")]
fn new_fast(
    state: Term<'_>,
    dependencies: Vec<ResourceArc<MemoCell>>,
    estimate: u64,
) -> NifResult<ResourceArc<MemoCell>> {
    count(OP_NEW_FAST);
    allocate(state, dependencies, estimate, false)
}

fn allocate(
    state: Term<'_>,
    dependencies: Vec<ResourceArc<MemoCell>>,
    estimate: u64,
    read_only: bool,
) -> NifResult<ResourceArc<MemoCell>> {
    let retained_bytes = accounted_bytes(estimate)?;
    let dependencies = dependency_ids(dependencies);
    let id = next_id()?;
    let saved = save(state, retained_bytes);

    // A fresh ID cannot occur in any existing path, but publish its edges
    // before exposing the resource so graph membership matches cell lifetime.
    lock(graph()).insert(id, dependencies);
    LIVE_CELLS.fetch_add(1, Ordering::AcqRel);
    saturating_add(&RETAINED_BYTES, retained_bytes);

    let cell = ResourceArc::new(MemoCell {
        id,
        read_only,
        version: Version::new(),
        touched: AtomicBool::new(false),
        state: Mutex::new(Some(saved)),
    });
    register(id, &cell);
    Ok(cell)
}

fn next_id() -> NifResult<u64> {
    NEXT_ID
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |id| id.checked_add(1))
        .map_err(|_| rustler::Error::BadArg)
}

struct Cursor {
    id: u64,
    position: Mutex<SavedTerm>,
    source: ResourceArc<MemoCell>,
    // Whether pulling a chunk must take the dirty lane. Decided ONCE, at cursor
    // creation, from the source's average element size: a chunk copies at most
    // 32 heads, so `32 * avg_bytes <= ceiling` keeps a chunk within the
    // fast-lane budget. Immutable, and cloned onto every sub-cursor so the
    // decision holds for the whole walk. Residual: a list whose bytes are
    // concentrated in a few giant elements has a small average yet a large
    // chunk; such lists are rare, and lowering the ceiling forces them dirty.
    dirty_chunks: bool,
}
#[rustler::resource_impl]
impl rustler::Resource for Cursor {
    fn destructor(self, _env: Env<'_>) {
        unregister(self.id);
    }
}

impl Cursor {
    fn arc(position: SavedTerm, source: ResourceArc<MemoCell>, dirty_chunks: bool) -> NifResult<ResourceArc<Cursor>> {
        let id = next_id()?;
        let cursor = ResourceArc::new(Cursor { id, position: Mutex::new(position), source, dirty_chunks });
        register(id, &cursor);
        Ok(cursor)
    }
}

/// A cursor is immutable and holds exactly one count the ETF cannot show: its
/// Rust handle on the source cell. Its position lives in the source's own
/// environment, so the source's census already covers it. It never detaches —
/// every cycle through a cursor also runs through its source, a cell.
impl Node for Cursor {
    fn trace(&self, visit: &mut dyn FnMut(&Key)) -> Traced {
        visit(&collector::key_of(&self.source));
        Traced::At(0)
    }
    fn quiet(&self, _version: u64) -> bool {
        true
    }
    fn detach(&self) -> Option<Box<dyn Send>> {
        None
    }
}

#[rustler::nif(name = "nif_cursor", schedule = "DirtyCpu")]
fn cursor(
    list: Term<'_>,
    dependencies: Vec<ResourceArc<MemoCell>>,
    estimate: u64,
) -> NifResult<ResourceArc<Cursor>> {
    count(OP_CURSOR);
    let len = list.list_length()?;
    let source = allocate(list, dependencies, estimate, true)?;
    let retained = lock(&source.state)
        .as_ref()
        .ok_or(rustler::Error::BadArg)?
        .retained_bytes;
    // 32 * (retained / len) > ceiling  ⇔  a chunk may exceed the budget.
    let avg = if len > 0 { retained / len } else { retained };
    let dirty_chunks = avg.saturating_mul(32) > fast_lane_bytes();
    let position = lock(&source.state)
        .as_ref()
        .ok_or(rustler::Error::BadArg)?
        .term
        .clone();
    Cursor::arc(position, source, dirty_chunks)
}

/// Whether this cursor's chunks must take the dirty lane. `SeqCursor` reads it
/// ONCE at creation and threads the answer, so no per-chunk NIF is needed.
#[rustler::nif(name = "nif_cursor_dirty_chunks")]
fn cursor_dirty_chunks(cursor: ResourceArc<Cursor>) -> bool {
    cursor.dirty_chunks
}

fn cursor_chunk_impl<'a>(
    env: Env<'a>,
    cursor: ResourceArc<Cursor>,
) -> NifResult<(Vec<Term<'a>>, Option<ResourceArc<Cursor>>)> {
    let position = lock(&cursor.position);
    let guard = lock(&cursor.source.state);
    let state = guard.as_ref().ok_or(rustler::Error::BadArg)?;
    cursor.source.touched.store(true, Ordering::Release);
    state.env.run(|owned| {
        let mut remaining = position.load(owned);
        let mut chunk = Vec::with_capacity(32);
        for _ in 0..32 {
            if remaining.is_empty_list() {
                break;
            }
            let (head, tail) = remaining.list_get_cell()?;
            chunk.push(head.in_env(env));
            remaining = tail;
        }
        let tail = if remaining.is_empty_list() {
            None
        } else {
            Some(Cursor::arc(state.env.save(remaining), cursor.source.clone(), cursor.dirty_chunks)?)
        };
        Ok((chunk, tail))
    })
}

/// Fast lane: regular scheduler. A chunk is at most 32 heads and the cursor's
/// `dirty_chunks` flag (set at creation) guarantees that stays within the
/// fast-lane byte budget; `SeqCursor` calls this entry for a normal cursor.
#[rustler::nif(name = "nif_cursor_chunk_fast")]
fn cursor_chunk_fast<'a>(
    env: Env<'a>,
    cursor: ResourceArc<Cursor>,
) -> NifResult<(Vec<Term<'a>>, Option<ResourceArc<Cursor>>)> {
    count(OP_CURSOR_CHUNK_FAST);
    cursor_chunk_impl(env, cursor)
}

/// Dirty lane: for a cursor whose elements are large enough that a 32-head
/// chunk may copy more than the ceiling.
#[rustler::nif(name = "nif_cursor_chunk", schedule = "DirtyCpu")]
fn cursor_chunk<'a>(
    env: Env<'a>,
    cursor: ResourceArc<Cursor>,
) -> NifResult<(Vec<Term<'a>>, Option<ResourceArc<Cursor>>)> {
    count(OP_CURSOR_CHUNK);
    cursor_chunk_impl(env, cursor)
}

#[rustler::nif(name = "nif_dependency_resource")]
fn dependency_resource(term: Term<'_>) -> Option<ResourceArc<MemoCell>> {
    count(OP_DEP_RESOURCE);
    term.decode::<ResourceArc<MemoCell>>().ok().or_else(|| {
        term.decode::<ResourceArc<Cursor>>().ok().map(|cursor| {
            // Hands the caller a reference it did not hold: a read, for the
            // cycle collector's purposes (see `MemoCell::touched`).
            cursor.source.touched.store(true, Ordering::Release);
            cursor.source.clone()
        })
    })
}

/// (PLAN-132 Phase 1) `nif_lane` is GONE: reads self-guard in `nif_read_fast`,
/// so no separate routing crossing exists. `op_lane` remains in `nif_stats` as
/// a regression sentinel — it must read 0 forever.
#[rustler::nif(name = "nif_fast_lane_bytes")]
fn get_fast_lane_bytes() -> u64 {
    fast_lane_bytes() as u64
}

#[rustler::nif(name = "nif_set_fast_lane_bytes")]
fn set_fast_lane_bytes(bytes: u64) -> NifResult<u64> {
    let bytes = usize::try_from(bytes).map_err(|_| rustler::Error::BadArg)?;
    FAST_LANE_BYTES.store(bytes, Ordering::Release);
    Ok(bytes as u64)
}

fn read_impl<'a>(env: Env<'a>, resource: ResourceArc<MemoCell>) -> NifResult<Term<'a>> {
    let guard = lock(&resource.state);
    let state = guard.as_ref().ok_or(rustler::Error::BadArg)?;
    Ok(resource.export(state, env))
}

/// Fast lane: regular scheduler. SELF-GUARDING (PLAN-132 Phase 1, fixes F1):
/// for an over-ceiling cell it returns the bare `:reroute` atom WITHOUT loading
/// the term (loading a multi-megabyte value here is the very stall the lanes
/// exist to prevent), and `LazyMemo.read/1` retries on the dirty `nif_read`.
/// The only ambiguity — a small cell whose value IS the atom `:reroute` — is
/// benign: it is under the ceiling, so it loads and returns `:reroute`, the
/// caller retries dirty, and `nif_read` returns `:reroute` again (the true
/// value). One wasted crossing for that lone pathological cell; never wrong.
#[rustler::nif(name = "nif_read_fast")]
fn read_fast<'a>(env: Env<'a>, resource: ResourceArc<MemoCell>) -> NifResult<Term<'a>> {
    count(OP_READ_FAST);
    let guard = lock(&resource.state);
    let state = guard.as_ref().ok_or(rustler::Error::BadArg)?;
    if state.retained_bytes > fast_lane_bytes() {
        return Ok(reroute().to_term(env));
    }
    Ok(resource.export(state, env))
}

/// Dirty lane: unchanged behaviour for large values.
#[rustler::nif(name = "nif_read", schedule = "DirtyCpu")]
fn read<'a>(env: Env<'a>, resource: ResourceArc<MemoCell>) -> NifResult<Term<'a>> {
    count(OP_READ);
    read_impl(env, resource)
}

fn read_versioned_impl<'a>(
    env: Env<'a>,
    resource: ResourceArc<MemoCell>,
) -> NifResult<Term<'a>> {
    let guard = lock(&resource.state);
    let state = guard.as_ref().ok_or(rustler::Error::BadArg)?;
    let version = resource.version.get();
    Ok((version, resource.export(state, env)).encode(env))
}

/// The cell's `{version, state}`, where `version` is the publication counter a
/// caller hands back to `nif_exchange_version`. Read under the same state lock
/// the exchange takes, so the pair is consistent: an exchange that bumps the
/// version does so while holding it.
#[rustler::nif(name = "nif_read_versioned", schedule = "DirtyCpu")]
fn read_versioned<'a>(env: Env<'a>, resource: ResourceArc<MemoCell>) -> NifResult<Term<'a>> {
    count(OP_READ);
    read_versioned_impl(env, resource)
}

/// Fast lane, self-guarding exactly like `nif_read_fast`: an over-ceiling cell
/// answers the bare `:reroute` atom WITHOUT loading the term, and the caller
/// retries on the dirty lane. The answer here is a 2-tuple, never a bare atom,
/// so — unlike `nif_read_fast` — there is no ambiguity to reason about at all.
#[rustler::nif(name = "nif_read_versioned_fast")]
fn read_versioned_fast<'a>(env: Env<'a>, resource: ResourceArc<MemoCell>) -> NifResult<Term<'a>> {
    count(OP_READ_FAST);
    let guard = lock(&resource.state);
    let state = guard.as_ref().ok_or(rustler::Error::BadArg)?;
    if state.retained_bytes > fast_lane_bytes() {
        return Ok(reroute().to_term(env));
    }
    let version = resource.version.get();
    Ok((version, resource.export(state, env)).encode(env))
}

/// Shared body of the versioned exchange. The version compare is O(1) — no term
/// is loaded, no term is compared — so unlike `compare_exchange_impl` a retry
/// costs nothing but a lock. `deps` selects the edge policy: `Keep` does no
/// graph work, `Union` cycle-checks only the NEW ids and never shrinks the
/// edge set.
#[allow(clippy::too_many_arguments)]
fn exchange_version_impl<'a>(
    env: Env<'a>,
    resource: ResourceArc<MemoCell>,
    expected_version: u64,
    replacement: Term<'a>,
    deps: Deps,
    estimate: u64,
    notifications: Vec<(LocalPid, Term<'a>)>,
    fast_lane: bool,
) -> NifResult<Atom> {
    count(if fast_lane { OP_CAS_FAST } else { OP_CAS });
    if resource.read_only {
        return Err(rustler::Error::BadArg);
    }
    let retained_bytes = accounted_bytes(estimate)?;
    let new_ids = deps.ids();
    let mut cell = lock(&resource.state);
    let current = cell.as_ref().ok_or(rustler::Error::BadArg)?;
    if fast_lane {
        let ceiling = fast_lane_bytes();
        if current.retained_bytes > ceiling || retained_bytes > ceiling {
            drop(cell);
            count(OP_REROUTE);
            return Ok(reroute());
        }
    }
    if !resource.version.matches(expected_version) {
        drop(cell);
        count(OP_RETRY);
        return Ok(retry());
    }

    // Decide the cycle question BEFORE copying the replacement term: a rejected
    // attempt then costs no term copy and no deferred reclaim. The graph lock is
    // held until the state is replaced, so the edge set and the state it
    // describes become visible together.
    let mut edges = None;
    if let Some(new_ids) = new_ids {
        let mut graph_lock = lock(graph());
        let previous: Vec<u64> = graph_lock.get(&resource.id).cloned().unwrap_or_default();
        let (added, merged) = edge_plan(&previous, &new_ids);
        if fast_lane && !added.is_empty() {
            // New edges mean an unbounded cycle walk: not fast-lane work.
            drop(graph_lock);
            drop(cell);
            count(OP_REROUTE);
            return Ok(reroute());
        }
        if would_cycle(&graph_lock, resource.id, &added) {
            drop(graph_lock);
            drop(cell);
            count(OP_CYCLE);
            return Ok(cycle());
        }
        graph_lock.insert(resource.id, merged);
        edges = Some(graph_lock);
    }

    let replacement = save(replacement, retained_bytes);
    let old = cell.replace(replacement).ok_or(rustler::Error::BadArg)?;
    resource.version.bump();
    saturating_sub(&RETAINED_BYTES, old.retained_bytes);
    saturating_add(&RETAINED_BYTES, retained_bytes);
    drop(edges);
    drop(cell);

    // An evaluator cannot be interrupted between publication and notification:
    // both happen in this NIF call. A dead recipient simply discards its reply.
    for (pid, message) in notifications {
        let _ = env.send(&pid, message);
    }
    if fast_lane {
        reclaim_state_small(old);
    } else {
        reclaim_state(old);
    }
    Ok(ok())
}

/// Fast lane: regular scheduler. Self-guarding like the term CAS — a large
/// current value, a large replacement or a NEW dependency edge answers
/// `:reroute` and changes nothing; the caller retries on the dirty lane.
#[rustler::nif(name = "nif_exchange_version_fast")]
fn exchange_version_fast<'a>(
    env: Env<'a>,
    resource: ResourceArc<MemoCell>,
    expected_version: u64,
    replacement: Term<'a>,
    deps: Term<'a>,
    estimate: u64,
    notifications: Vec<(LocalPid, Term<'a>)>,
) -> NifResult<Atom> {
    let deps = Deps::decode(deps)?;
    exchange_version_impl(env, resource, expected_version, replacement, deps, estimate, notifications, true)
}

/// Dirty lane: for a value past the fast-lane ceiling or a dependency set that
/// adds an edge.
#[rustler::nif(name = "nif_exchange_version", schedule = "DirtyCpu")]
fn exchange_version<'a>(
    env: Env<'a>,
    resource: ResourceArc<MemoCell>,
    expected_version: u64,
    replacement: Term<'a>,
    deps: Term<'a>,
    estimate: u64,
    notifications: Vec<(LocalPid, Term<'a>)>,
) -> NifResult<Atom> {
    let deps = Deps::decode(deps)?;
    exchange_version_impl(env, resource, expected_version, replacement, deps, estimate, notifications, false)
}

/// Shared CAS body. `fast_lane` makes the call refuse (with `reroute`) any
/// work that could not be bounded: a large current or replacement term, or a
/// dependency set that adds NEW edges (whose cycle walk is unbounded). The
/// caller then retries on the dirty lane. Everything the fast lane does accept
/// is O(1) plus a small-term copy, which is what a regular-scheduler NIF may do.
fn compare_exchange_impl<'a>(
    env: Env<'a>,
    resource: ResourceArc<MemoCell>,
    expected: Term<'_>,
    replacement: Term<'a>,
    dependencies: Vec<ResourceArc<MemoCell>>,
    estimate: u64,
    notifications: Vec<(LocalPid, Term<'a>)>,
    fast_lane: bool,
) -> NifResult<Atom> {
    count(if fast_lane { OP_CAS_FAST } else { OP_CAS });
    if resource.read_only {
        return Err(rustler::Error::BadArg);
    }
    let retained_bytes = accounted_bytes(estimate)?;
    let dependencies = dependency_ids(dependencies);
    let mut cell = lock(&resource.state);
    let current = cell.as_ref().ok_or(rustler::Error::BadArg)?;
    if fast_lane {
        let ceiling = fast_lane_bytes();
        if current.retained_bytes > ceiling || retained_bytes > ceiling {
            drop(cell);
            count(OP_REROUTE);
            return Ok(reroute());
        }
    }
    let identical = current
        .env
        .run(|owned| current.term.load(owned) == expected);
    if !identical {
        drop(cell);
        count(OP_RETRY);
        return Ok(retry());
    }

    // Decide the cycle question BEFORE copying the replacement term: a
    // rejected attempt then costs no term copy and no deferred reclaim.
    let mut edges = lock(graph());
    // Existing edges cannot introduce a new cycle. Claims and waiter updates
    // normally retain exactly the same dependencies as the previous state.
    let previous = edges.get(&resource.id);
    let added: Vec<u64> = dependencies
        .iter()
        .copied()
        .filter(|id| !previous.is_some_and(|old| old.contains(id)))
        .collect();
    if fast_lane && !added.is_empty() {
        // New edges mean an unbounded cycle walk: not fast-lane work.
        drop(edges);
        drop(cell);
        count(OP_REROUTE);
        return Ok(reroute());
    }
    if would_cycle(&edges, resource.id, &added) {
        drop(edges);
        drop(cell);
        count(OP_CYCLE);
        return Ok(cycle());
    }

    let replacement = save(replacement, retained_bytes);
    edges.insert(resource.id, dependencies);
    let old = cell.replace(replacement).ok_or(rustler::Error::BadArg)?;
    resource.version.bump();
    saturating_sub(&RETAINED_BYTES, old.retained_bytes);
    saturating_add(&RETAINED_BYTES, retained_bytes);
    drop(edges);
    drop(cell);

    // An evaluator cannot be interrupted between publication and notification:
    // both happen in this NIF call. A dead recipient simply discards its reply.
    for (pid, message) in notifications {
        let _ = env.send(&pid, message);
    }
    if fast_lane {
        reclaim_state_small(old);
    } else {
        reclaim_state(old);
    }
    Ok(ok())
}

/// Fast lane: regular scheduler. Self-guarding: it answers `reroute` (and
/// changes nothing) for a large current value, a large replacement, or any
/// NEW dependency edge, so it can never be tricked into unbounded work. The
/// caller retries `nif_compare_exchange` on `reroute`.
#[rustler::nif(name = "nif_compare_exchange_fast")]
fn compare_exchange_fast<'a>(
    env: Env<'a>,
    resource: ResourceArc<MemoCell>,
    expected: Term<'_>,
    replacement: Term<'a>,
    dependencies: Vec<ResourceArc<MemoCell>>,
    estimate: u64,
    notifications: Vec<(LocalPid, Term<'a>)>,
) -> NifResult<Atom> {
    compare_exchange_impl(env, resource, expected, replacement, dependencies, estimate, notifications, true)
}

/// Dirty lane: unchanged behaviour for large values or new dependency edges.
#[rustler::nif(name = "nif_compare_exchange", schedule = "DirtyCpu")]
fn compare_exchange<'a>(
    env: Env<'a>,
    resource: ResourceArc<MemoCell>,
    expected: Term<'_>,
    replacement: Term<'a>,
    dependencies: Vec<ResourceArc<MemoCell>>,
    estimate: u64,
    notifications: Vec<(LocalPid, Term<'a>)>,
) -> NifResult<Atom> {
    compare_exchange_impl(env, resource, expected, replacement, dependencies, estimate, notifications, false)
}

#[rustler::nif(name = "nif_id")]
fn id(resource: ResourceArc<MemoCell>) -> u64 {
    count(OP_ID);
    resource.id
}

#[rustler::nif(name = "nif_resource_id")]
fn resource_id(term: Term<'_>) -> Option<u64> {
    count(OP_ID);
    term.decode::<ResourceArc<MemoCell>>()
        .ok()
        .map(|cell| cell.id)
}

#[rustler::nif(name = "nif_stats")]
fn stats() -> MemoStats {
    let op = |i: usize| OPS[i].load(Ordering::Relaxed);
    MemoStats {
        live_cells: LIVE_CELLS.load(Ordering::Acquire),
        retained_bytes: RETAINED_BYTES.load(Ordering::Acquire),
        pending_reclaims: PENDING_RECLAIMS.load(Ordering::Acquire),
        op_new: op(OP_NEW),
        op_new_fast: op(OP_NEW_FAST),
        op_read: op(OP_READ),
        op_read_fast: op(OP_READ_FAST),
        op_lane: op(OP_LANE),
        op_cas: op(OP_CAS),
        op_cas_fast: op(OP_CAS_FAST),
        op_reroute: op(OP_REROUTE),
        op_retry: op(OP_RETRY),
        op_cycle: op(OP_CYCLE),
        op_dep_resource: op(OP_DEP_RESOURCE),
        op_id: op(OP_ID),
        op_cursor: op(OP_CURSOR),
        op_cursor_chunk: op(OP_CURSOR_CHUNK),
        op_cursor_chunk_fast: op(OP_CURSOR_CHUNK_FAST),
        cycle_enabled: collector::enabled(),
        cycle_runs: collector::RUNS.load(Ordering::Relaxed),
        cycle_aborts: collector::ABORTS.load(Ordering::Relaxed),
        cycle_collected: collector::COLLECTED.load(Ordering::Relaxed),
        cycle_anomalies: collector::ANOMALIES.load(Ordering::Relaxed),
    }
}

/// Unconditional replace — a volatile's `vreset!`. No version compare, no
/// edges (`:keep`): the last writer wins, which is the volatile contract. The
/// fast lane answers `:reroute` for a large current or new value.
fn put_impl(resource: ResourceArc<MemoCell>, value: Term<'_>, estimate: u64, fast_lane: bool) -> NifResult<Atom> {
    if resource.read_only {
        return Err(rustler::Error::BadArg);
    }
    let retained_bytes = accounted_bytes(estimate)?;
    let mut cell = lock(&resource.state);
    let current = cell.as_ref().ok_or(rustler::Error::BadArg)?;
    if fast_lane && (current.retained_bytes > fast_lane_bytes() || retained_bytes > fast_lane_bytes()) {
        return Ok(reroute());
    }
    let old = cell.replace(save(value, retained_bytes)).ok_or(rustler::Error::BadArg)?;
    resource.version.bump();
    saturating_sub(&RETAINED_BYTES, old.retained_bytes);
    saturating_add(&RETAINED_BYTES, retained_bytes);
    drop(cell);
    if fast_lane {
        reclaim_state_small(old);
    } else {
        reclaim_state(old);
    }
    Ok(ok())
}

#[rustler::nif(name = "nif_put_fast")]
fn put_fast(resource: ResourceArc<MemoCell>, value: Term<'_>, estimate: u64) -> NifResult<Atom> {
    put_impl(resource, value, estimate, true)
}

#[rustler::nif(name = "nif_put", schedule = "DirtyCpu")]
fn put(resource: ResourceArc<MemoCell>, value: Term<'_>, estimate: u64) -> NifResult<Atom> {
    put_impl(resource, value, estimate, false)
}

/// A fresh, empty `Seen` set (see seen.rs) — `distinct`'s memory.
#[rustler::nif(name = "nif_seen_new")]
fn seen_new() -> NifResult<ResourceArc<seen::Seen>> {
    Ok(seen::Seen::arc(next_id()?))
}

/// Admit a chunk's keys; answers one boolean per key, true where it was new.
/// A chunk is at most 32 keys, but keys can be large terms: dirty lane.
#[rustler::nif(name = "nif_seen_admit", schedule = "DirtyCpu")]
fn seen_admit(seen: ResourceArc<seen::Seen>, keys: Vec<Term<'_>>) -> Vec<bool> {
    seen.admit(&keys)
}

/// Run one cycle-collection round now; answers the cells it freed. Rounds
/// also run on their own, on a background thread, as allocation grows.
#[rustler::nif(name = "nif_collect_cycles", schedule = "DirtyCpu")]
fn collect_cycles() -> u64 {
    collector::collect() as u64
}

/// Empty when the collector calibrated; else why it is off.
#[rustler::nif(name = "nif_collector_status")]
fn collector_status() -> &'static str {
    collector::calibration_error()
}

#[rustler::nif(name = "nif_loaded?")]
fn loaded() -> bool {
    true
}

// Rustler's init macro currently supplies no unload hook. This entry follows
// its resource/inventory registration but joins our worker before dlclose.
extern "C" fn load_native(
    raw_env: rustler::codegen_runtime::NIF_ENV,
    _private: *mut *mut rustler::codegen_runtime::c_void,
    _info: rustler::codegen_runtime::NIF_TERM,
) -> rustler::codegen_runtime::c_int {
    if lock(&RECLAIMER).is_some() {
        return 1;
    }
    unsafe {
        let env = Env::new_init_env(&raw_env, raw_env);
        if rustler::codegen_runtime::ResourceRegistration::register_all_collected(env).is_err() {
            return 1;
        }
    }
    if start_reclaimer().is_err() {
        return 1;
    }
    if collector::start().is_err() {
        return 1;
    }
    0
}

extern "C" fn unload_native(
    _env: rustler::codegen_runtime::NIF_ENV,
    _private: *mut rustler::codegen_runtime::c_void,
) {
    collector::stop();
    let worker = lock(&RECLAIMER).take();
    if let Some(Reclaimer { sender, worker }) = worker {
        drop(sender);
        let _ = worker.join();
    }
}

#[cfg(not(windows))]
#[no_mangle]
extern "C" fn nif_init() -> *const rustler::codegen_runtime::DEF_NIF_ENTRY {
    use rustler::codegen_runtime as rt;
    static ENTRY: OnceLock<usize> = OnceLock::new();
    let entry = ENTRY.get_or_init(|| {
        unsafe {
            rt::internal_write_symbols();
        }
        let functions: Box<[_]> = rt::inventory::iter::<rustler::Nif>()
            .map(rustler::Nif::get_def)
            .collect();
        let entry = rt::DEF_NIF_ENTRY {
            major: rt::NIF_MAJOR_VERSION,
            minor: rt::NIF_MINOR_VERSION,
            name: c"Elixir.BeamLisp.LazyMemo".as_ptr(),
            num_of_funcs: functions.len() as rt::c_int,
            funcs: functions.as_ptr(),
            load: Some(load_native),
            reload: None,
            upgrade: None,
            unload: Some(unload_native),
            vm_variant: c"beam.vanilla".as_ptr(),
            options: 0,
            sizeof_ErlNifResourceTypeInit: rt::get_nif_resource_type_init_size(),
            min_erts: rt::min_erts().as_ptr() as *const rt::c_char,
        };
        std::mem::forget(functions);
        Box::into_raw(Box::new(entry)) as usize
    });
    *entry as *const rt::DEF_NIF_ENTRY
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cycle_search_handles_direct_indirect_and_unrelated_edges() {
        let mut graph = HashMap::new();
        graph.insert(2, vec![3]);
        graph.insert(3, vec![4]);
        assert!(would_cycle(&graph, 4, &[2]));
        assert!(would_cycle(&graph, 2, &[2]));
        assert!(!would_cycle(&graph, 9, &[2]));
    }

    #[test]
    fn cycle_search_terminates_on_preexisting_cycle() {
        let mut graph = HashMap::new();
        graph.insert(2, vec![3]);
        graph.insert(3, vec![2]);
        assert!(!would_cycle(&graph, 9, &[2]));
    }

    #[test]
    fn version_is_a_cas_precondition_and_bumps_on_commit() {
        let version = Version::new();
        assert!(version.matches(0), "a fresh cell is at version 0");
        assert_eq!(version.bump(), 1);
        assert!(!version.matches(0), "a stale reader must be told to retry");
        assert!(version.matches(1));
        assert_eq!(version.bump(), 2);
        assert_eq!(version.get(), 2);
    }

    #[test]
    fn edge_plan_unions_and_names_only_new_edges() {
        // A genuinely new id is the only thing the cycle walk must consider.
        let (added, merged) = edge_plan(&[1, 2], &[2, 3, 3]);
        assert_eq!(added, vec![3]);
        assert_eq!(merged, vec![1, 2, 3]);

        // Re-asserting edges the cell already holds is free: nothing added, so
        // no cycle walk at all.
        let (added, merged) = edge_plan(&[1, 2], &[2, 1]);
        assert!(added.is_empty());
        assert_eq!(merged, vec![1, 2]);

        // Never shrinks: a new set that mentions nothing keeps every retained
        // edge, which is what makes a `:keep`-then-`union` sequence monotone.
        let (added, merged) = edge_plan(&[7], &[]);
        assert!(added.is_empty());
        assert_eq!(merged, vec![7]);

        let (added, merged) = edge_plan(&[], &[5]);
        assert_eq!(added, vec![5]);
        assert_eq!(merged, vec![5]);
    }

    #[test]
    fn keep_is_the_mode_that_does_no_graph_work() {
        // `Deps::ids()` is what decides whether the exchange takes the graph
        // lock and runs `would_cycle` at all.
        assert!(Deps::Keep.ids().is_none());
    }

    #[test]
    fn accounting_never_wraps() {
        let counter = AtomicUsize::new(usize::MAX - 1);
        saturating_add(&counter, 10);
        assert_eq!(counter.load(Ordering::Relaxed), usize::MAX);
        saturating_sub(&counter, usize::MAX);
        saturating_sub(&counter, 1);
        assert_eq!(counter.load(Ordering::Relaxed), 0);
    }
}
