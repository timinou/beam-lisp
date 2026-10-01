//! Native ownership cell for LazySeq memo state.
//!
//! Resource terms are version-local: hot upgrades must drain all cells before
//! unloading this NIF. Rustler resource types from different module versions
//! are intentionally not treated as interchangeable.

use rustler::env::SavedTerm;
use rustler::{Atom, Encoder, Env, LocalPid, NifMap, NifResult, OwnedEnv, ResourceArc, Term};
use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::collections::{HashMap, HashSet};
use std::mem::size_of;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{mpsc, Mutex, MutexGuard, OnceLock};

rustler::atoms! { ok, retry, cycle, fast, dirty, reroute, keep, other, over_budget }

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

/// SavedTerm positions held by live cursor roots (PLAN-155). The chunk index
/// is one entry per 32-head boundary, built once per walk and released with the
/// root; this counter makes that cost exact instead of invisible.
static CURSOR_POSITIONS: AtomicUsize = AtomicUsize::new(0);

/// The byte ledger (PLAN-154 B). `occupied` is the ONE authoritative word that
/// admission reads and CASes; `retained` and `reserved` are DIAGNOSTICS that
/// answer `nif_retained_bytes`/`nif_reserved_bytes`/`stats` and are never read
/// by an admission decision.
///
/// Why one word. The rejected protocol kept two counters and tested
/// `retained + reserved` before CASing only `reserved`. That snapshot is TORN:
/// a commit can raise `retained` and drop `reserved` back to the value the
/// publisher read, so the CAS wins against a retained total the publisher never
/// observed — and two publishers then jointly exceed the ceiling (ABA). With one
/// word the guard and the CAS see the same value, and a word returned to an old
/// value still describes the CURRENT occupancy: a reservation that fits at the
/// CAS instant is sound, and a commit that consumed the room makes the CAS fail.
///
/// `occupied == retained + reserved` holds at quiescence. Every transition below
/// ADDS before it SUBTRACTS, so a concurrent admission can only ever read a total
/// that is too LARGE (refuse early), never too small (overadmit).
///
/// Admission holds NO lock: one CAS on `occupied`, so the fast lane stays
/// bounded and publishers on different cells never serialize on a global mutex.
/// A credit (`reserve` → `Ok`) is created under the target cell's state mutex and
/// consumed by exactly one of `release`/commit inside the same call; no other
/// publisher can hold or release it.
struct Ledger {
    occupied: AtomicUsize,
    retained: AtomicUsize,
    reserved: AtomicUsize,
}

impl Ledger {
    const fn new() -> Self {
        Ledger {
            occupied: AtomicUsize::new(0),
            retained: AtomicUsize::new(0),
            reserved: AtomicUsize::new(0),
        }
    }

    /// Take one admission against `budget`: a single CAS on the authoritative
    /// quota. `Ok` means `delta` bytes are spoken for; the caller MUST either
    /// commit (which consumes the credit) or `release` it. A growth of 0 takes no
    /// CAS and touches no counter, so control transitions stay free.
    fn reserve(&self, delta: usize, budget: usize, fast_lane: bool) -> Reserve {
        let verdict = if fast_lane {
            reserve_once(&self.occupied, delta, budget)
        } else {
            reserve_loop(&self.occupied, delta, budget)
        };
        if delta > 0 && verdict == Reserve::Ok {
            saturating_add(&self.reserved, delta); // diagnostic mirror only
        }
        verdict
    }

    /// Give back the credit a successful `reserve` took: the exclusive right of
    /// the one call that took it. The commit calls this as its last step, and
    /// every path that abandons the attempt (a cycle, a fast reroute) calls it
    /// instead. Exactly once per credit.
    fn release(&self, delta: usize) {
        if delta > 0 {
            saturating_sub(&self.occupied, delta);
            saturating_sub(&self.reserved, delta);
        }
    }

    /// A state ENTERS the live set: a fresh cell's initial value, or the
    /// replacement a publication commits. Never subtracts, so the total is only
    /// ever transiently high.
    fn enter(&self, bytes: usize) {
        saturating_add(&self.occupied, bytes);
        saturating_add(&self.retained, bytes);
    }

    /// A state LEAVES the live set: the state a publication replaced, the state
    /// a destructor drops, or the state the collector detached from a dead
    /// cycle. A state leaves exactly once — `Mutex<Option<State>>::take` is what
    /// guarantees it — so this is that state's only debit.
    fn leave(&self, bytes: usize) {
        saturating_sub(&self.occupied, bytes);
        saturating_sub(&self.retained, bytes);
    }
}

static LEDGER: Ledger = Ledger::new();
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
/// A CONSTANT-SIZE `{tag, version}` state peek (PLAN-154 D): a state decision
/// that must not export the term the state holds.
const OP_PEEK: usize = 15;
/// A publication the byte budget REFUSED (PLAN-154 B).
const OP_BUDGET: usize = 16;
/// Cursor ROOT resources created (PLAN-155): ONE per walk. A walk's tail is a
/// `{root, index}` token, never another resource, so this stays O(1) while the
/// OLD shape paid one allocation + one registry insert per 32-head chunk.
const OP_CURSOR_NEW: usize = 17;
const OP_COUNT: usize = 18;
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
    /// The references this term holds, ONCE PER OCCURRENCE, as the cycle
    /// collector's census found them — computed at most once per state (None:
    /// unreadable, so the node is an opaque root).
    census: OnceLock<Option<Vec<Key>>>,
}

/// The key of the collector node a subterm IS, or None for anything else (a
/// plain reference, a resource of another type, a scalar). Handed to the
/// census walk as a resolver so the walk lives in `collector` without
/// depending on the cell types.
///
/// EVERY resource type the collector can PIN is answered here — the memo cell,
/// the cursor root, and the `distinct` Seen set. That is what makes the walk
/// exactly graph-equivalent to the ETF census it replaces: a term that IS a
/// collector node contributes its key wherever it appears, and a resource of
/// any other type could never be found in the collector's index anyway. (A
/// resource inside a CLOSURE is still read by the ETF fallback, which reports
/// every reference the closure captures.)
fn resource_key<'a>(term: Term<'a>) -> Option<Key> {
    term.decode::<ResourceArc<MemoCell>>()
        .ok()
        .map(|cell| collector::key_of(&cell))
        .or_else(|| {
            term.decode::<ResourceArc<Cursor>>()
                .ok()
                .map(|cursor| collector::key_of(&cursor))
        })
        .or_else(|| {
            term.decode::<ResourceArc<seen::Seen>>()
                .ok()
                .map(|seen| collector::key_of(&seen))
        })
}

impl State {
    fn census(&self) -> Option<&[Key]> {
        self.census
            .get_or_init(|| {
                self.env
                    .run(|env| collector::census_keys(self.term.load(env), resource_key))
            })
            .as_deref()
    }

    /// The state's leading tag atom — read IN PLACE inside the cell's own
    /// environment, so the value the state holds is never exported. Answers the
    /// tagged tuple's first atom (`:pending`, `:completed`, `:failed`,
    /// `:running`, `:terminal`), an untagged atom state's own atom, and `:other`
    /// otherwise. Constant size whatever the payload (PLAN-154 D).
    fn tag(&self) -> Atom {
        self.env.run(|env| tag_of(self.term.load(env)))
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
        let Some(state) = guard.as_ref() else {
            return Traced::Vacant;
        };
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
        LEDGER.leave(state.retained_bytes);
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
            LEDGER.leave(state.retained_bytes);
            reclaim_state(state);
        }
    }
}

#[derive(NifMap)]
struct MemoStats {
    live_cells: usize,
    retained_bytes: usize,
    /// Bytes admitted but not yet committed (PLAN-154 B).
    /// `retained_bytes + reserved_bytes` is what admission is checked against.
    reserved_bytes: usize,
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
    /// Constant-size state peeks (PLAN-154 D).
    op_peek: u64,
    /// Publications refused by the byte budget (PLAN-154 B).
    op_budget: u64,
    op_dep_resource: u64,
    op_id: u64,
    op_cursor: u64,
    op_cursor_chunk: u64,
    op_cursor_chunk_fast: u64,
    /// Cursor ROOTS created (PLAN-155) — one per walk, whatever its length.
    /// The old shape's `n/32` sub-cursors made this O(n/32); it must stay O(1).
    op_cursor_new: u64,
    /// SavedTerm positions held by live cursor roots: the chunk index's exact
    /// memory, one entry per chunk boundary (the index ALIASES the source's own
    /// env, so it adds no term payload and no reference of its own).
    cursor_positions: usize,
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
    size_of::<MemoCell>()
        .checked_add(estimate)
        .ok_or(rustler::Error::BadArg)
}

/// (PLAN-154 B) The bytes a publication ADDS to the retained set: the
/// replacement's accounted size minus the size of the state it replaces.
/// Replacing a state with a smaller one grows nothing — such a transition cannot
/// raise the ceiling and so is never refused. That is what keeps CONTROL
/// transitions (a claim, a waiter registration, a terminal un-strand)
/// admissible at any budget, and so keeps a refused value publication from
/// stranding the attempt that produced it. The counted overheads are exactly
/// `accounted_bytes/1`'s: one `size_of::<MemoCell>()` per live state, plus the
/// measured payload — `estimate_bytes/1` charges a running/terminal state a
/// constant 64 and measures `:pending`/`:completed`/`:failed` exactly.
fn growth_of(retained_bytes: usize, replaced_bytes: usize) -> usize {
    retained_bytes.saturating_sub(replaced_bytes)
}

/// (PLAN-154 B) One admission attempt's verdict.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Reserve {
    /// The credit is held: `delta` bytes are in the ledger's `occupied`.
    Ok,
    /// The ceiling cannot absorb the growth.
    Over,
    /// Another reserving publisher won the CAS; retry on the dirty lane.
    Contended,
}

/// (PLAN-154 B) The linearizable admission primitive: reserve `delta` bytes of
/// growth iff `occupied + delta <= budget`, by ONE CAS on `occupied`.
///
/// The guard reads `occupied`; the CAS expects THAT SAME WORD. So the value the
/// publisher tests and the value it swaps cannot diverge — no torn
/// `(retained, reserved)` pair, and no ABA hazard: if a concurrent commit and a
/// release return the word to the value the publisher read, that value is again
/// the CURRENT occupancy, so `occupied + delta <= budget` is still the true test.
/// The successful CAS IS the linearization point; every later admission observes
/// the reservation, so two publishers that each start below the ceiling cannot
/// both win the room for the same byte twice.
/// A growth of 0 reserves nothing and takes no CAS, so a non-growing publication
/// never contends. An overflowing sum is a ceiling verdict, never a wrap.
fn reserve_loop(occupied: &AtomicUsize, delta: usize, budget: usize) -> Reserve {
    if delta == 0 {
        return Reserve::Ok;
    }
    loop {
        let held = occupied.load(Ordering::Acquire);
        let Some(target) = held.checked_add(delta) else {
            // No `usize` holds the sum: no ceiling can absorb it.
            return Reserve::Over;
        };
        if target > budget {
            return Reserve::Over;
        }
        if occupied
            .compare_exchange_weak(held, target, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            return Reserve::Ok;
        }
    }
}

/// (PLAN-154 B) The fast lane's single-attempt admission: a reservation CAS it
/// cannot win answers `Contended` instead of spinning under a regular
/// scheduler. `Over` is a real ceiling verdict, not a lane verdict.
fn reserve_once(occupied: &AtomicUsize, delta: usize, budget: usize) -> Reserve {
    if delta == 0 {
        return Reserve::Ok;
    }
    let held = occupied.load(Ordering::Acquire);
    let Some(target) = held.checked_add(delta) else {
        return Reserve::Over;
    };
    if target > budget {
        return Reserve::Over;
    }
    if occupied
        .compare_exchange(held, target, Ordering::AcqRel, Ordering::Acquire)
        .is_ok()
    {
        Reserve::Ok
    } else {
        Reserve::Contended
    }
}

/// (PLAN-154 D) The leading tag of a cell state, read in place: the tuple's
/// first element when that element is an atom, a bare atom state's own atom,
/// else `:other`. Only an atom crosses back out, so the answer is constant size
/// however large the state's payload is.
fn tag_of(term: Term<'_>) -> Atom {
    if let Ok(elements) = rustler::types::tuple::get_tuple(term) {
        return elements
            .first()
            .and_then(|first| first.decode::<Atom>().ok())
            .unwrap_or_else(other);
    }
    term.decode::<Atom>().unwrap_or_else(|_| other())
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
    if amount == 0 {
        return;
    }
    let _ = counter.fetch_update(Ordering::AcqRel, Ordering::Acquire, |old| {
        Some(old.saturating_add(amount))
    });
}

fn saturating_sub(counter: &AtomicUsize, amount: usize) {
    if amount == 0 {
        return;
    }
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
    LEDGER.enter(retained_bytes);

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

/// How many list heads one chunk pull copies. The chunk index and the lane
/// decision both count in these, and `LazySeq/chunk_size/0` is the same 32.
const CHUNK: usize = 32;

/// Positions a walk needs: one per 32-head boundary PLUS the empty terminator
/// that ends it, i.e. `ceil(len / CHUNK) + 1`. `len = 0` still needs that one
/// entry — the empty list is a position, and pulling it is how a fresh empty
/// cursor answers `{[], nil}`. Only a size hint for the index; the walk reads
/// the real length from the built vector.
fn position_count(len: usize) -> usize {
    len.div_ceil(CHUNK) + 1
}

/// Whether the position AFTER `index` holds elements, i.e. whether pulling
/// chunk `index` yields a tail token. `positions` always ends with the empty
/// list, so the entry at `index + 1` is empty exactly when `index + 2` is the
/// length — that entry is never itself pulled.
fn has_tail(index: usize, positions: usize) -> bool {
    index + 2 < positions
}

/// The immutable state of a chunk walk: ONE root resource per walk, shared by
/// every position token.
///
/// A walk used to mint a fresh native resource per 32-head chunk — one
/// `next_id` plus a registry insert and a destructor-time removal under the
/// collector's global mutex, `n/32` times for an `n`-element list, with the
/// same churn in the collector's scheduling counter. The positions themselves
/// were never the cost (`state.env.save(remaining)` in the source's own
/// environment copies nothing); the RESOURCE was.
///
/// So the walk allocates exactly one: this root. It owns
///   * the source cell (kept alive for the walk, and the owner of the env the
///     positions live in — the source is `read_only`, so that env never moves), and
///   * `positions`, one saved position per chunk boundary, BUILT ONCE at
///     creation by walking the source's already-saved list inside its own
///     environment. Every boundary is an O(1) `save` in that environment, so
///     the build is O(len) — never a tail copy, and never a scan from the
///     head of a chunk pull.
///
/// A pull answers the chunk AND the NEXT position as a `{root, index}` token.
/// The token is an ordinary BEAM term (a 2-tuple) referencing this same
/// resource, so a tail costs no allocation and no registration, and the walk's
/// own consumed tokens are ordinary garbage. Because a pull only READS,
/// `{root, k}` replays: the same token always yields the same chunk and the
/// same tail, for one consumer or many, however they are interleaved.
///
/// A `Vec<SavedTerm>` is not `Sync`, so it sits behind a mutex that is written
/// once, at construction, and only ever READ after — only the saved HANDLES are
/// shared (the index aliases the source's terms), so there is no lock held
/// across a copy and no lock ordered against the source's `state`.
struct Cursor {
    id: u64,
    // Declaration order matters: the saved positions must disappear before the
    // `source` that owns their backing environment. Rust drops fields in
    // declaration order.
    positions: Mutex<Vec<SavedTerm>>,
    source: ResourceArc<MemoCell>,
    // Whether pulling a chunk must take the dirty lane. Decided ONCE, at cursor
    // creation, from the source's average element size: a chunk copies at most
    // 32 heads, so `32 * avg_bytes <= ceiling` keeps a chunk within the
    // fast-lane budget. Immutable, so it rides the root for the whole walk.
    // Residual: a list whose bytes are concentrated in a few giant elements has
    // a small average yet a large chunk; such lists are rare, and lowering the
    // ceiling forces them dirty.
    dirty_chunks: bool,
}
#[rustler::resource_impl]
impl rustler::Resource for Cursor {
    fn destructor(self, _env: Env<'_>) {
        unregister(self.id);
        saturating_sub(&CURSOR_POSITIONS, lock(&self.positions).len());
    }
}

impl Cursor {
    fn arc(
        source: ResourceArc<MemoCell>,
        positions: Vec<SavedTerm>,
        dirty_chunks: bool,
    ) -> NifResult<ResourceArc<Cursor>> {
        let id = next_id()?;
        count(OP_CURSOR_NEW);
        saturating_add(&CURSOR_POSITIONS, positions.len());
        let cursor = ResourceArc::new(Cursor {
            id,
            positions: Mutex::new(positions),
            source,
            dirty_chunks,
        });
        register(id, &cursor);
        Ok(cursor)
    }
}

/// Resolve a cursor HANDLE to `{root, index}`.
///
/// A walk threads one of two spellings of the same position: the root resource
/// itself, which is chunk 0 and is exactly what `nif_cursor` answers, or the
/// `{root, index}` token a pull answers for the following chunk. Both decode
/// here, so there is ONE walker and every entry point agrees on the form.
fn token(term: Term<'_>) -> NifResult<(ResourceArc<Cursor>, usize)> {
    if let Ok(root) = term.decode::<ResourceArc<Cursor>>() {
        return Ok((root, 0));
    }
    if let Ok((root, index)) = term.decode::<(ResourceArc<Cursor>, u64)>() {
        return usize::try_from(index)
            .map(|index| (root, index))
            .map_err(|_| rustler::Error::BadArg);
    }
    Err(rustler::Error::BadArg)
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

/// A cursor over `list`: the ROOT resource of the walk, naming chunk 0.
///
/// Creation is where the whole walk's cost is paid, and it is O(len) exactly
/// once: `allocate` copies the list into the source's own environment, and the
/// position index is then built by walking THAT copy in that same environment.
/// Each 32-head step is a pointer read and each boundary is an O(1) `save`
/// (the term is already in the saving environment, so nothing is copied) — no
/// tail is ever re-copied, and no chunk pull need scan from the head.
#[rustler::nif(name = "nif_cursor", schedule = "DirtyCpu")]
fn cursor(
    list: Term<'_>,
    dependencies: Vec<ResourceArc<MemoCell>>,
    estimate: u64,
) -> NifResult<ResourceArc<Cursor>> {
    count(OP_CURSOR);
    let len = list.list_length()?;
    let source = allocate(list, dependencies, estimate, true)?;
    let guard = lock(&source.state);
    let state = guard.as_ref().ok_or(rustler::Error::BadArg)?;
    let retained = state.retained_bytes;
    // 32 * (retained / len) > ceiling  ⇔  a chunk may exceed the budget.
    let avg = if len > 0 { retained / len } else { retained };
    let dirty_chunks = avg.saturating_mul(CHUNK) > fast_lane_bytes();
    let positions = state.env.run(|owned| -> NifResult<Vec<SavedTerm>> {
        let mut positions = Vec::with_capacity(position_count(len));
        // The list is ALREADY saved in this environment: one O(1) load, not a copy.
        let mut remaining = state.term.load(owned);
        loop {
            positions.push(state.env.save(remaining)); // same env: O(1), no copy
            if remaining.is_empty_list() {
                break;
            }
            let mut step = remaining;
            for _ in 0..CHUNK {
                if step.is_empty_list() {
                    break;
                }
                let (_, tail) = step.list_get_cell()?;
                step = tail;
            }
            remaining = step;
        }
        Ok(positions)
    })?;
    drop(guard);
    Cursor::arc(source, positions, dirty_chunks)
}

/// Whether this cursor's chunks must take the dirty lane. `SeqCursor` reads it
/// ONCE at creation and threads the answer, so no per-chunk NIF is needed. It
/// accepts the root resource or a `{root, index}` token, so a consumer holding
/// either can ask.
#[rustler::nif(name = "nif_cursor_dirty_chunks")]
fn cursor_dirty_chunks(handle: Term<'_>) -> NifResult<bool> {
    Ok(token(handle)?.0.dirty_chunks)
}

fn cursor_chunk_impl<'a>(
    env: Env<'a>,
    handle: Term<'a>,
) -> NifResult<(Vec<Term<'a>>, Option<Term<'a>>)> {
    let (root, index) = token(handle)?;
    // Copy the saved HANDLE out and drop the index lock before touching the
    // source: no lock is held across a term copy, and none is ordered against it.
    let (position, positions) = {
        let guard = lock(&root.positions);
        let position = guard.get(index).ok_or(rustler::Error::BadArg)?.clone();
        (position, guard.len())
    };
    let state_guard = lock(&root.source.state);
    let state = state_guard.as_ref().ok_or(rustler::Error::BadArg)?;
    root.source.touched.store(true, Ordering::Release);
    // A pull only READS the position: the chunk and the tail are a function of
    // `{root, index}` alone, so the same token replays identically.
    let chunk = state.env.run(|owned| -> NifResult<Vec<Term<'a>>> {
        let mut remaining = position.load(owned);
        let mut chunk = Vec::with_capacity(CHUNK);
        for _ in 0..CHUNK {
            if remaining.is_empty_list() {
                break;
            }
            let (head, tail) = remaining.list_get_cell()?;
            chunk.push(head.in_env(env));
            remaining = tail;
        }
        Ok(chunk)
    })?;
    drop(state_guard);
    let tail = if has_tail(index, positions) {
        Some((root, (index + 1) as u64).encode(env))
    } else {
        None
    };
    Ok((chunk, tail))
}

/// Fast lane: regular scheduler. A chunk is at most 32 heads and the cursor's
/// `dirty_chunks` flag (set at creation) guarantees that stays within the
/// fast-lane byte budget; `SeqCursor` calls this entry for a normal cursor.
/// `handle` is the root resource or a `{root, index}` token — one walker.
#[rustler::nif(name = "nif_cursor_chunk_fast")]
fn cursor_chunk_fast<'a>(
    env: Env<'a>,
    handle: Term<'a>,
) -> NifResult<(Vec<Term<'a>>, Option<Term<'a>>)> {
    count(OP_CURSOR_CHUNK_FAST);
    cursor_chunk_impl(env, handle)
}

/// Dirty lane: for a cursor whose elements are large enough that a 32-head
/// chunk may copy more than the ceiling.
#[rustler::nif(name = "nif_cursor_chunk", schedule = "DirtyCpu")]
fn cursor_chunk<'a>(
    env: Env<'a>,
    handle: Term<'a>,
) -> NifResult<(Vec<Term<'a>>, Option<Term<'a>>)> {
    count(OP_CURSOR_CHUNK);
    cursor_chunk_impl(env, handle)
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

fn read_versioned_impl<'a>(env: Env<'a>, resource: ResourceArc<MemoCell>) -> NifResult<Term<'a>> {
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
    // `Some(ceiling)` admits a GROWING publication against the byte budget;
    // `None` (the unadmitted entry points) leaves the accounting as it was.
    budget: Option<u64>,
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

    // ── byte-budget admission (PLAN-154 B) ────────────────────────────────
    // The bytes this publication ADDS: the replacement's accounted size minus
    // the size of the state it replaces. A publication that grows nothing is
    // never refused (it cannot raise the ceiling), which is exactly what lets a
    // control transition commit at any budget and so never strands an owner or
    // its waiters. A growing publication takes a credit for its growth with ONE
    // CAS on the ledger's authoritative `occupied` word, so concurrent
    // publishers that each start below the ceiling cannot jointly exceed it.
    // The credit is released on every path that does not commit (a cycle, a fast
    // reroute) and CONSUMED by the commit below.
    let reserved = budget.is_some();
    let delta = growth_of(retained_bytes, current.retained_bytes);
    if let Some(ceiling) = budget {
        let ceiling = usize::try_from(ceiling).unwrap_or(usize::MAX);
        match LEDGER.reserve(delta, ceiling, fast_lane) {
            Reserve::Ok => {}
            Reserve::Over => {
                drop(cell);
                count(OP_BUDGET);
                return Ok(over_budget());
            }
            Reserve::Contended => {
                drop(cell);
                count(OP_REROUTE);
                return Ok(reroute());
            }
        }
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
            if reserved {
                LEDGER.release(delta);
            }
            count(OP_REROUTE);
            return Ok(reroute());
        }
        if would_cycle(&graph_lock, resource.id, &added) {
            drop(graph_lock);
            drop(cell);
            if reserved {
                LEDGER.release(delta);
            }
            count(OP_CYCLE);
            return Ok(cycle());
        }
        graph_lock.insert(resource.id, merged);
        edges = Some(graph_lock);
    }

    let replacement = save(replacement, retained_bytes);
    let old = match cell.replace(replacement) {
        Some(old) => old,
        // Unreachable: the state lock is held and `current` was checked above,
        // so the cell cannot have been emptied. A credit must still not leak.
        None => {
            drop(edges);
            drop(cell);
            if reserved {
                LEDGER.release(delta);
            }
            return Err(rustler::Error::BadArg);
        }
    };
    resource.version.bump();
    // Account the replacement BEFORE releasing the credit, and add before
    // subtracting: an admission that races this window then sees the total too
    // LARGE rather than too small. Releasing first (or subtracting first) could
    // let two publishers each pass the check and jointly overshoot. Net effect
    // on `occupied`: `+new −old −delta == −shrink`, so a GROWING publication
    // leaves the word exactly where its credit already put it (the credit became
    // retained) and a shrinking one lowers it by the shrink. No hole either way:
    // the word never dips below the truth at any instant.
    LEDGER.enter(retained_bytes);
    LEDGER.leave(old.retained_bytes);
    if reserved {
        LEDGER.release(delta);
    }
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
    exchange_version_impl(
        env,
        resource,
        expected_version,
        replacement,
        deps,
        estimate,
        notifications,
        true,
        None,
    )
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
    exchange_version_impl(
        env,
        resource,
        expected_version,
        replacement,
        deps,
        estimate,
        notifications,
        false,
        None,
    )
}

/// (PLAN-154 B) The ADMITTED versioned exchange, fast lane: identical to
/// `nif_exchange_version_fast` except that a publication which GROWS the
/// retained set must first reserve that growth atomically against `budget`. A
/// reservation it cannot win answers `:reroute` (the dirty lane retries it); a
/// growth the ceiling cannot absorb answers `:over_budget` and changes nothing.
#[rustler::nif(name = "nif_exchange_version_admitted_fast")]
fn exchange_version_admitted_fast<'a>(
    env: Env<'a>,
    resource: ResourceArc<MemoCell>,
    expected_version: u64,
    replacement: Term<'a>,
    deps: Term<'a>,
    estimate: u64,
    notifications: Vec<(LocalPid, Term<'a>)>,
    budget: u64,
) -> NifResult<Atom> {
    let deps = Deps::decode(deps)?;
    exchange_version_impl(
        env,
        resource,
        expected_version,
        replacement,
        deps,
        estimate,
        notifications,
        true,
        Some(budget),
    )
}

/// (PLAN-154 B) The ADMITTED versioned exchange, dirty lane — the lane the
/// LazySeq publication paths use. Answers `ok`, `retry`, `cycle` or
/// `over_budget`; the caller turns `over_budget` into its own refusal and must
/// never retry it blindly (the ceiling is a resource verdict, not a race).
#[rustler::nif(name = "nif_exchange_version_admitted", schedule = "DirtyCpu")]
fn exchange_version_admitted<'a>(
    env: Env<'a>,
    resource: ResourceArc<MemoCell>,
    expected_version: u64,
    replacement: Term<'a>,
    deps: Term<'a>,
    estimate: u64,
    notifications: Vec<(LocalPid, Term<'a>)>,
    budget: u64,
) -> NifResult<Atom> {
    let deps = Deps::decode(deps)?;
    exchange_version_impl(
        env,
        resource,
        expected_version,
        replacement,
        deps,
        estimate,
        notifications,
        false,
        Some(budget),
    )
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
    // UNADMITTED path: no credit, no cost — this is the policy-exempt ref write.
    // It still keeps the ledger exact, and it enters before it leaves so a
    // concurrent ADMITTED admission can never read a transiently low total.
    LEDGER.enter(retained_bytes);
    LEDGER.leave(old.retained_bytes);
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
    compare_exchange_impl(
        env,
        resource,
        expected,
        replacement,
        dependencies,
        estimate,
        notifications,
        true,
    )
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
    compare_exchange_impl(
        env,
        resource,
        expected,
        replacement,
        dependencies,
        estimate,
        notifications,
        false,
    )
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

/// (PLAN-154 B) One atomic load of the RETAINED diagnostic — the committed half
/// of the ledger. Admission itself CASes the ledger's authoritative `occupied`
/// word (see `reserve_loop`); this read is a cheap OBSERVATION for callers, and
/// `retained_bytes + reserved_bytes` is the total the cache occupies.
#[rustler::nif(name = "nif_retained_bytes")]
fn retained_bytes() -> u64 {
    LEDGER.retained.load(Ordering::Acquire) as u64
}

/// (PLAN-154 B) One atomic load of the RESERVED diagnostic: the bytes an
/// admitted publication has spoken for but not committed yet. Diagnostic only —
/// admission never reads it (a decision built from this plus a separate
/// retained load is the torn snapshot the ledger replaced).
#[rustler::nif(name = "nif_reserved_bytes")]
fn reserved_bytes() -> u64 {
    LEDGER.reserved.load(Ordering::Acquire) as u64
}

/// (PLAN-154 D) A CONSTANT-SIZE peek at a cell's state: `{tag, version}` taken
/// under the state lock WITHOUT exporting the term. `tag` is the state tuple's
/// leading atom (`:pending`, `:completed`, `:failed`, `:running`, `:terminal`),
/// a bare atom state's own atom, or `:other`. Both elements are immediate, so
/// the cost is O(1) however large the value the cell holds — which is the whole
/// point: a dispatch that needs only the tag must not copy a published n-element
/// list onto the caller's heap to learn it is not `:pending`.
///
/// The answer is NOT a durable snapshot. Another process can publish between
/// this peek and any later read, so a caller that ACTS on the tag must either
/// read the versioned state and compare versions, or hand the version back to
/// `nif_exchange_version*` (whose CAS rejects a moved cell). The public
/// full-state API — `nif_read`, `nif_read_versioned`, `memo_state/1` — is
/// deliberately unchanged: the peek is an ADDITION, not a narrowing.
#[rustler::nif(name = "nif_peek")]
fn peek<'a>(env: Env<'a>, resource: ResourceArc<MemoCell>) -> NifResult<Term<'a>> {
    count(OP_PEEK);
    let guard = lock(&resource.state);
    let state = guard.as_ref().ok_or(rustler::Error::BadArg)?;
    let version = resource.version.get();
    let tag = state.tag();
    Ok((tag, version).encode(env))
}

#[rustler::nif(name = "nif_stats")]
fn stats() -> MemoStats {
    let op = |i: usize| OPS[i].load(Ordering::Relaxed);
    MemoStats {
        live_cells: LIVE_CELLS.load(Ordering::Acquire),
        retained_bytes: LEDGER.retained.load(Ordering::Acquire),
        reserved_bytes: LEDGER.reserved.load(Ordering::Acquire),
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
        op_peek: op(OP_PEEK),
        op_budget: op(OP_BUDGET),
        op_dep_resource: op(OP_DEP_RESOURCE),
        op_id: op(OP_ID),
        op_cursor: op(OP_CURSOR),
        op_cursor_chunk: op(OP_CURSOR_CHUNK),
        op_cursor_chunk_fast: op(OP_CURSOR_CHUNK_FAST),
        op_cursor_new: op(OP_CURSOR_NEW),
        cursor_positions: CURSOR_POSITIONS.load(Ordering::Acquire),
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
fn put_impl(
    resource: ResourceArc<MemoCell>,
    value: Term<'_>,
    estimate: u64,
    fast_lane: bool,
) -> NifResult<Atom> {
    if resource.read_only {
        return Err(rustler::Error::BadArg);
    }
    let retained_bytes = accounted_bytes(estimate)?;
    let mut cell = lock(&resource.state);
    let current = cell.as_ref().ok_or(rustler::Error::BadArg)?;
    if fast_lane
        && (current.retained_bytes > fast_lane_bytes() || retained_bytes > fast_lane_bytes())
    {
        return Ok(reroute());
    }
    let old = cell
        .replace(save(value, retained_bytes))
        .ok_or(rustler::Error::BadArg)?;
    resource.version.bump();
    // UNADMITTED path (a volatile `vreset!`): no credit, but the same ledger
    // discipline — enter before leave, so no reader sees a transiently low total.
    LEDGER.enter(retained_bytes);
    LEDGER.leave(old.retained_bytes);
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

    #[test]
    fn the_cell_overhead_is_charged_with_the_payload() {
        assert_eq!(accounted_bytes(0).unwrap(), size_of::<MemoCell>());
        assert_eq!(
            accounted_bytes(40).unwrap(),
            size_of::<MemoCell>() + 40,
            "every publication carries one cell's fixed overhead"
        );
    }

    #[test]
    fn growth_is_only_the_excess_over_the_state_replaced() {
        assert_eq!(growth_of(544, 64), 480);
        assert_eq!(
            growth_of(64, 544),
            0,
            "a shrinking replacement grows nothing"
        );
        assert_eq!(growth_of(88, 88), 0, "a control transition grows nothing");
    }

    /// The ledger's whole contract in one assertion: the authoritative word is
    /// exactly the committed bytes plus the bytes in flight.
    fn assert_ledger_exact(ledger: &Ledger) {
        assert_eq!(
            ledger.occupied.load(Ordering::Acquire),
            ledger.retained.load(Ordering::Acquire) + ledger.reserved.load(Ordering::Acquire),
            "occupied must be retained + reserved"
        );
    }

    #[test]
    fn a_non_growing_publication_is_never_refused() {
        // The cache can be AT or OVER the ceiling and the terminal/waiter/claim
        // transition must still commit — otherwise a refused publication would
        // strand the attempt that produced it. A growth of 0 takes no CAS and
        // touches no counter at all.
        let occupied = AtomicUsize::new(9_000);
        assert_eq!(reserve_loop(&occupied, 0, 100), Reserve::Ok);
        assert_eq!(
            occupied.load(Ordering::Relaxed),
            9_000,
            "nothing was reserved"
        );

        let ledger = Ledger::new();
        ledger.enter(9_000);
        assert_eq!(ledger.reserve(0, 100, true), Reserve::Ok);
        assert_eq!(ledger.reserve(0, 100, false), Reserve::Ok);
        assert_eq!(ledger.occupied.load(Ordering::Acquire), 9_000);
        assert_eq!(ledger.reserved.load(Ordering::Acquire), 0);
    }

    #[test]
    fn admission_reserves_only_while_the_total_fits_the_budget() {
        let occupied = AtomicUsize::new(100);
        assert_eq!(reserve_loop(&occupied, 50, 150), Reserve::Ok);
        assert_eq!(occupied.load(Ordering::Relaxed), 150);
        // 150 + 50 > 150: refused, and a refusal must not leave a reservation
        // behind.
        assert_eq!(reserve_loop(&occupied, 50, 150), Reserve::Over);
        assert_eq!(occupied.load(Ordering::Relaxed), 150);
    }

    #[test]
    fn a_released_reservation_returns_the_room_it_held() {
        let ledger = Ledger::new();
        assert_eq!(ledger.reserve(100, 100, false), Reserve::Ok);
        assert_eq!(
            ledger.reserve(1, 100, false),
            Reserve::Over,
            "the whole ceiling is already spoken for"
        );
        // A cycle or a fast reroute abandons the attempt: the credit returns and
        // the room is available again.
        ledger.release(100);
        assert_eq!(ledger.occupied.load(Ordering::Acquire), 0);
        assert_eq!(ledger.reserved.load(Ordering::Acquire), 0);
        assert_eq!(ledger.reserve(100, 100, false), Reserve::Ok);
        assert_ledger_exact(&ledger);
    }

    #[test]
    fn the_fast_lane_answers_over_rather_than_contending() {
        let occupied = AtomicUsize::new(80);
        // 80 + 100 > 150: a real ceiling verdict, not a lane verdict.
        assert_eq!(reserve_once(&occupied, 100, 150), Reserve::Over);
        assert_eq!(occupied.load(Ordering::Relaxed), 80);
        // Exactly the free 70 is admissible.
        assert_eq!(reserve_once(&occupied, 70, 150), Reserve::Ok);
        assert_eq!(occupied.load(Ordering::Relaxed), 150);
    }

    #[test]
    fn a_lost_cas_leaves_the_ledger_where_the_winner_put_it() {
        // The fast lane's `Contended` arm, modelled exactly: the CAS expects the
        // value the attempt loaded, so a concurrent reservation makes it fail.
        // A failed CAS is a no-op — no credit, no counter change — which is what
        // makes `Contended` safe to reroute to the dirty lane.
        let ledger = Ledger::new();
        assert_eq!(ledger.reserve(60, 100, false), Reserve::Ok); // the winner
        let after_winner = ledger.occupied.load(Ordering::Acquire);
        assert!(
            ledger
                .occupied
                .compare_exchange(0, 60, Ordering::AcqRel, Ordering::Acquire)
                .is_err(),
            "the loser's expected value is gone"
        );
        assert_eq!(ledger.occupied.load(Ordering::Acquire), after_winner);
        assert_eq!(
            ledger.reserved.load(Ordering::Acquire),
            60,
            "the loser took no credit"
        );
        assert_ledger_exact(&ledger);
    }

    #[test]
    fn the_fast_lane_admits_at_most_one_growth_that_fits_once() {
        // Eight fast attempts race for one 60-byte growth under a 100-byte
        // ceiling. Whatever the scheduler does, the outcome is forced: exactly
        // one CAS can move the word 0 -> 60, and once it has, 60 + 60 > 100, so
        // no second attempt — winning a CAS or merely guarding — can add another.
        const BUDGET: usize = 100;
        let occupied = AtomicUsize::new(0);
        let outcomes: Vec<Reserve> = std::thread::scope(|scope| {
            let handles: Vec<_> = (0..8)
                .map(|_| scope.spawn(|| reserve_once(&occupied, 60, BUDGET)))
                .collect();
            handles
                .into_iter()
                .map(|handle| handle.join().unwrap())
                .collect()
        });
        assert_eq!(
            outcomes.iter().filter(|r| **r == Reserve::Ok).count(),
            1,
            "the ceiling admits exactly one of the eight"
        );
        assert_eq!(occupied.load(Ordering::Relaxed), 60);
    }

    #[test]
    fn concurrent_reservations_never_jointly_exceed_the_budget() {
        // The ceiling property, exercised by real contention: sixteen publishers
        // each want a tenth of the budget, so at most ten CASes may win.
        const BUDGET: usize = 1000;
        let ledger = Ledger::new();
        std::thread::scope(|scope| {
            for _ in 0..16 {
                scope.spawn(|| {
                    let _ = ledger.reserve(100, BUDGET, false);
                });
            }
        });
        let held = ledger.occupied.load(Ordering::Acquire);
        assert!(
            held <= BUDGET,
            "reservations jointly exceed the ceiling: {held} > {BUDGET}"
        );
        assert!(held > 0, "the exercise reserved nothing at all");
        assert_ledger_exact(&ledger);
    }

    /// The REJECTED two-counter admission, copied step for step: guard on
    /// `(retained, reserved)`, then CAS ONLY `reserved`. `torn_guard` hands back
    /// the token it guarded on, so a caller can replay JUST the CAS — and that is
    /// exactly what makes the torn snapshot exploitable.
    fn torn_guard(
        retained: &AtomicUsize,
        reserved: &AtomicUsize,
        delta: usize,
        budget: usize,
    ) -> Option<usize> {
        let held = reserved.load(Ordering::Acquire);
        if retained.load(Ordering::Acquire) + held + delta > budget {
            return None;
        }
        Some(held)
    }

    fn torn_cas(reserved: &AtomicUsize, held: usize, delta: usize) -> bool {
        reserved
            .compare_exchange(held, held + delta, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }

    #[test]
    fn the_torn_two_counter_snapshot_overadmits_the_rejected_protocol() {
        // Deterministic scripted interleaving of the race the ledger removes.
        const BUDGET: usize = 100;
        const DELTA: usize = 60;
        let retained = AtomicUsize::new(0);
        let reserved = AtomicUsize::new(0);

        // B's guard runs first and passes on the pair it reads: (0, 0).
        let b_held = torn_guard(&retained, &reserved, DELTA, BUDGET).expect("B's guard passes");
        assert_eq!(b_held, 0);

        // A's whole admission + commit lands in B's window: retained rises by the
        // growth, and the reserved half B holds a token for comes back to 0.
        let a_held = torn_guard(&retained, &reserved, DELTA, BUDGET).expect("A's guard passes");
        assert!(torn_cas(&reserved, a_held, DELTA), "A reserves");
        retained.fetch_add(DELTA, Ordering::AcqRel);
        reserved.fetch_sub(DELTA, Ordering::AcqRel);
        assert_eq!(
            reserved.load(Ordering::Acquire),
            0,
            "the ABA token came back"
        );

        // B's CAS on the half that moved BACK still wins — against a retained
        // total B never observed.
        assert!(torn_cas(&reserved, b_held, DELTA), "B reserves");
        let total = retained.load(Ordering::Acquire) + reserved.load(Ordering::Acquire);
        assert_eq!(total, 120, "two publishers jointly exceeded the ceiling");
        assert!(total > BUDGET);
    }

    #[test]
    fn the_single_quota_guards_and_cas_the_same_word() {
        const BUDGET: usize = 100;
        let ledger = Ledger::new();

        // A RESTORING interleaving — the ABA that stays benign: a reservation
        // that is CANCELLED returns the word to the value B read, with nothing
        // committed, so B's CAS landing on it is genuinely sound.
        let observed = ledger.occupied.load(Ordering::Acquire);
        assert!(observed + 60 <= BUDGET, "B's guard passes");
        assert_eq!(ledger.reserve(60, BUDGET, false), Reserve::Ok); // A
        ledger.release(60); // A's cycle: nothing committed
        assert_eq!(ledger.occupied.load(Ordering::Acquire), observed);
        assert_eq!(
            ledger.reserve(60, BUDGET, false),
            Reserve::Ok,
            "B wins soundly"
        );
        assert_ledger_exact(&ledger);
        ledger.release(60);

        // The COMMITTING interleaving — the ABA that is malignant under two
        // counters is caught here, because the commit moves the very word the
        // guard read: the second publisher cannot reserve room the first one has
        // already retained.
        ledger.enter(60); // A's committed publication
        assert_eq!(ledger.reserve(60, BUDGET, false), Reserve::Over);
        assert_eq!(ledger.occupied.load(Ordering::Acquire), 60);
        assert!(ledger.occupied.load(Ordering::Acquire) <= BUDGET);
        assert_ledger_exact(&ledger);
    }

    #[test]
    fn a_commit_consumes_its_credit_without_a_hole_in_the_ledger() {
        const BUDGET: usize = 200;
        let ledger = Ledger::new();
        ledger.enter(100); // a cell that already holds 100 bytes

        // A grows the set 100 -> 160: the credit is the growth, 60.
        let delta = growth_of(160, 100);
        assert_eq!(delta, 60);
        assert_eq!(ledger.reserve(delta, BUDGET, false), Reserve::Ok);
        assert_eq!(ledger.occupied.load(Ordering::Acquire), 160);
        assert_ledger_exact(&ledger);

        // A second publisher wanting 50 bytes sees the reservation; 160 + 50 >
        // 200, so it is refused while A's bytes are still in flight.
        assert_eq!(ledger.reserve(50, BUDGET, false), Reserve::Over);

        // The commit: enter the replacement, leave the replaced state, release
        // the credit. The word never dips below the truth at any instant, so
        // there is no hole between "reserved" and "retained" for a racing
        // admission to slip through — and for a GROWING publication it ends up
        // exactly where the credit already put it.
        ledger.enter(160);
        assert!(
            ledger.occupied.load(Ordering::Acquire) >= 160,
            "never transiently low"
        );
        ledger.leave(100);
        assert!(ledger.occupied.load(Ordering::Acquire) >= 160);
        ledger.release(delta);
        assert_eq!(ledger.occupied.load(Ordering::Acquire), 160);
        assert_eq!(ledger.reserved.load(Ordering::Acquire), 0, "no leak");
        assert_ledger_exact(&ledger);

        // A SHRINKING publication takes no credit and lowers the word by exactly
        // the shrink: 160 -> 60 gives 100 bytes back.
        assert_eq!(growth_of(60, 160), 0);
        ledger.enter(60);
        ledger.leave(160);
        assert_eq!(ledger.occupied.load(Ordering::Acquire), 60);
        assert_ledger_exact(&ledger);
        assert_eq!(ledger.reserve(100, BUDGET, false), Reserve::Ok);
        assert_ledger_exact(&ledger);
    }

    #[test]
    fn two_publishers_that_do_not_jointly_fit_the_ceiling() {
        const BUDGET: usize = 100;
        let ledger = Ledger::new();

        // Each publication wants to grow the set by 60; only one fits.
        assert_eq!(ledger.reserve(60, BUDGET, false), Reserve::Ok);
        assert_eq!(ledger.reserve(60, BUDGET, false), Reserve::Over);
        assert_eq!(
            ledger.occupied.load(Ordering::Acquire),
            60,
            "a refusal reserves nothing"
        );
        assert_eq!(ledger.reserved.load(Ordering::Acquire), 60);
        assert_ledger_exact(&ledger);

        // The winner commits its growth: the credit becomes retained, so the
        // loser STILL does not fit — the bytes are committed, not free.
        ledger.enter(60);
        ledger.leave(0);
        ledger.release(60);
        assert_eq!(ledger.occupied.load(Ordering::Acquire), 60);
        assert_eq!(ledger.reserve(60, BUDGET, false), Reserve::Over);
        assert_eq!(ledger.occupied.load(Ordering::Acquire), 60);
        assert!(ledger.occupied.load(Ordering::Acquire) <= BUDGET);
        assert_ledger_exact(&ledger);
    }

    #[test]
    fn a_credit_is_released_exactly_once_and_only_by_its_holder() {
        const BUDGET: usize = 100;
        let ledger = Ledger::new();
        ledger.enter(40);

        // Two publishers take 30 bytes each; both fit (40 + 60 == 100).
        assert_eq!(ledger.reserve(30, BUDGET, false), Reserve::Ok); // A
        assert_eq!(ledger.reserve(30, BUDGET, false), Reserve::Ok); // B
        assert_eq!(ledger.occupied.load(Ordering::Acquire), 100);
        assert_eq!(ledger.reserved.load(Ordering::Acquire), 60);

        // A abandons its attempt (a cycle) and gives back ITS 30 — no more.
        ledger.release(30);
        assert_eq!(
            ledger.occupied.load(Ordering::Acquire),
            70,
            "B's credit is untouched by A's release"
        );
        assert_eq!(ledger.reserved.load(Ordering::Acquire), 30);
        assert_eq!(ledger.reserve(40, BUDGET, false), Reserve::Over);
        assert_eq!(
            ledger.reserve(30, BUDGET, false),
            Reserve::Ok,
            "exactly A's credit came back"
        );
        assert_ledger_exact(&ledger);

        // B commits its own growth: its credit becomes retained, and the third
        // reservation is released in turn. Every credit is accounted for exactly
        // once, so the word lands on the committed total and nothing else.
        ledger.enter(30);
        ledger.leave(0);
        ledger.release(30);
        ledger.release(30);
        assert_eq!(
            ledger.reserved.load(Ordering::Acquire),
            0,
            "no credit leaked"
        );
        assert_eq!(ledger.retained.load(Ordering::Acquire), 70);
        assert_eq!(ledger.occupied.load(Ordering::Acquire), 70);
        assert_ledger_exact(&ledger);
    }

    #[test]
    fn an_unadmitted_write_never_understates_the_ledger() {
        // The policy-exempt ref write takes no credit, but it still moves the
        // ledger — and it enters BEFORE it leaves, so an admitted reservation
        // racing it can never observe room that is about to vanish.
        let ledger = Ledger::new();
        ledger.enter(100);
        ledger.enter(400); // the replacement is installed first
        assert!(
            ledger.occupied.load(Ordering::Acquire) >= 400,
            "enter-before-leave keeps the total above the truth"
        );
        ledger.leave(100); // ...and only then is the replaced state debited
        assert_eq!(ledger.occupied.load(Ordering::Acquire), 400);
        assert_ledger_exact(&ledger);
    }

    #[test]
    fn an_unrepresentable_growth_is_refused_not_wrapped() {
        // A ceiling cannot absorb a sum no `usize` can hold: a ceiling verdict,
        // never a wrap into a small number that would admit anything.
        let occupied = AtomicUsize::new(usize::MAX - 10);
        assert_eq!(reserve_loop(&occupied, 100, usize::MAX), Reserve::Over);
        assert_eq!(reserve_once(&occupied, 100, usize::MAX), Reserve::Over);
        assert_eq!(occupied.load(Ordering::Relaxed), usize::MAX - 10);

        // A hostile estimate is `badarg`, not a saturated ledger that would wedge
        // every later admission.
        assert!(accounted_bytes(u64::MAX).is_err());
    }

    // ── the cursor position index (PLAN-155) ────────────────────────────────

    #[test]
    fn the_position_index_has_one_entry_per_chunk_boundary() {
        // One entry per 32-head chunk boundary, PLUS the empty terminator that
        // ends the index — so an empty walk still has a position to pull.
        assert_eq!(position_count(0), 1);
        assert_eq!(position_count(1), 2);
        assert_eq!(position_count(31), 2);
        assert_eq!(position_count(32), 2);
        assert_eq!(position_count(33), 3);
        assert_eq!(position_count(63), 3);
        assert_eq!(position_count(64), 3);
        assert_eq!(position_count(65), 4);
        assert_eq!(position_count(100), 5);
        // The 16k walk pays 512 chunk entries + 1, NOT 512 sub-cursors.
        assert_eq!(position_count(16_384), 513);
        assert_eq!(position_count(16_384), 16_384 / CHUNK + 1);
    }

    #[test]
    fn a_tail_exists_for_every_index_but_the_last_real_chunk() {
        // `positions` always ends with the empty list, and that entry is never
        // itself pulled: the tail that names it is the one the pull that
        // consumes the last elements answers `nil` for.
        assert!(!has_tail(0, 1), "the empty walk: one position, no tail");
        assert!(!has_tail(0, 2), "one full chunk, then the empty terminator");
        assert!(has_tail(0, 3), "33 elements: 32 + 1");
        assert!(!has_tail(1, 3));
        assert!(has_tail(0, 4));
        assert!(has_tail(1, 4));
        assert!(!has_tail(2, 4));
        // The 16k walk answers a tail at every index but the last chunk.
        let positions = position_count(16_384);
        assert_eq!(
            (0..positions).filter(|&i| has_tail(i, positions)).count(),
            511
        );
    }

    #[test]
    fn the_index_and_the_tail_rule_agree_on_every_boundary() {
        // The pull sequence for a list of `len`: positions 0..chunks are pulled,
        // each but the LAST answering a tail token. That is exactly what the
        // index size and `has_tail` must agree on, for every boundary.
        for len in [0usize, 1, 2, 31, 32, 33, 40, 63, 64, 65, 100, 16_384] {
            let positions = position_count(len);
            let chunks = len.div_ceil(CHUNK);
            assert_eq!(positions, chunks + 1, "len={len}");
            for index in 0..chunks {
                assert_eq!(
                    has_tail(index, positions),
                    index + 1 < chunks,
                    "len={len} index={index}"
                );
            }
            // A full walk pulls every chunk and stops at nil.
            let pulls: Vec<usize> = (0..chunks).filter(|&i| has_tail(i, positions)).collect();
            assert_eq!(pulls.len(), chunks.saturating_sub(1), "len={len}");
        }
    }
}
