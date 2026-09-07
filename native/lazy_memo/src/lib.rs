//! Native ownership cell for LazySeq memo state.
//!
//! Resource terms are version-local: hot upgrades must drain all cells before
//! unloading this NIF. Rustler resource types from different module versions
//! are intentionally not treated as interchangeable.

use rustler::env::SavedTerm;
use rustler::{Atom, Env, LocalPid, NifMap, NifResult, OwnedEnv, ResourceArc, Term};
use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::collections::{HashMap, HashSet};
use std::mem::size_of;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{mpsc, Mutex, MutexGuard, OnceLock};

rustler::atoms! { ok, retry, cycle }

static NEXT_ID: AtomicU64 = AtomicU64::new(1);
static LIVE_CELLS: AtomicUsize = AtomicUsize::new(0);
static RETAINED_BYTES: AtomicUsize = AtomicUsize::new(0);
static PENDING_RECLAIMS: AtomicUsize = AtomicUsize::new(0);
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
}

struct MemoCell {
    id: u64,
    read_only: bool,
    state: Mutex<Option<State>>,
}

#[rustler::resource_impl]
impl rustler::Resource for MemoCell {
    fn destructor(self, _env: Env<'_>) {
        let state = mutex_value(self.state).take();

        // Never drop a SavedTerm environment while graph/cell locks are held:
        // embedded resource releases can invoke more MemoCell destructors.
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

#[rustler::nif(name = "nif_new", schedule = "DirtyCpu")]
fn new(
    state: Term<'_>,
    dependencies: Vec<ResourceArc<MemoCell>>,
    estimate: u64,
) -> NifResult<ResourceArc<MemoCell>> {
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
    let id = NEXT_ID
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |id| id.checked_add(1))
        .map_err(|_| rustler::Error::BadArg)?;
    let saved = save(state, retained_bytes);

    // A fresh ID cannot occur in any existing path, but publish its edges
    // before exposing the resource so graph membership matches cell lifetime.
    lock(graph()).insert(id, dependencies);
    LIVE_CELLS.fetch_add(1, Ordering::AcqRel);
    saturating_add(&RETAINED_BYTES, retained_bytes);

    Ok(ResourceArc::new(MemoCell {
        id,
        read_only,
        state: Mutex::new(Some(saved)),
    }))
}

struct Cursor {
    position: Mutex<SavedTerm>,
    source: ResourceArc<MemoCell>,
}
#[rustler::resource_impl]
impl rustler::Resource for Cursor {}

#[rustler::nif(name = "nif_cursor", schedule = "DirtyCpu")]
fn cursor(
    list: Term<'_>,
    dependencies: Vec<ResourceArc<MemoCell>>,
    estimate: u64,
) -> NifResult<ResourceArc<Cursor>> {
    list.list_length()?;
    let source = allocate(list, dependencies, estimate, true)?;
    let position = lock(&source.state)
        .as_ref()
        .ok_or(rustler::Error::BadArg)?
        .term
        .clone();
    Ok(ResourceArc::new(Cursor {
        position: Mutex::new(position),
        source,
    }))
}

#[rustler::nif(name = "nif_cursor_chunk", schedule = "DirtyCpu")]
fn cursor_chunk<'a>(
    env: Env<'a>,
    cursor: ResourceArc<Cursor>,
) -> NifResult<(Vec<Term<'a>>, Option<ResourceArc<Cursor>>)> {
    let position = lock(&cursor.position);
    let guard = lock(&cursor.source.state);
    let state = guard.as_ref().ok_or(rustler::Error::BadArg)?;
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
            Some(ResourceArc::new(Cursor {
                position: Mutex::new(state.env.save(remaining)),
                source: cursor.source.clone(),
            }))
        };
        Ok((chunk, tail))
    })
}

#[rustler::nif(name = "nif_dependency_resource")]
fn dependency_resource(term: Term<'_>) -> Option<ResourceArc<MemoCell>> {
    term.decode::<ResourceArc<MemoCell>>().ok().or_else(|| {
        term.decode::<ResourceArc<Cursor>>()
            .ok()
            .map(|cursor| cursor.source.clone())
    })
}

#[rustler::nif(name = "nif_read", schedule = "DirtyCpu")]
fn read<'a>(env: Env<'a>, resource: ResourceArc<MemoCell>) -> NifResult<Term<'a>> {
    let guard = lock(&resource.state);
    let state = guard.as_ref().ok_or(rustler::Error::BadArg)?;
    Ok(state.env.run(|owned| state.term.load(owned).in_env(env)))
}

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
    if resource.read_only {
        return Err(rustler::Error::BadArg);
    }
    let retained_bytes = accounted_bytes(estimate)?;
    let dependencies = dependency_ids(dependencies);
    let mut cell = lock(&resource.state);
    let current = cell.as_ref().ok_or(rustler::Error::BadArg)?;
    let identical = current
        .env
        .run(|owned| current.term.load(owned) == expected);
    if !identical {
        drop(cell);
        return Ok(retry());
    }

    let replacement = save(replacement, retained_bytes);
    let mut edges = lock(graph());
    // Existing edges cannot introduce a new cycle. Claims and waiter updates
    // normally retain exactly the same dependencies as the previous state.
    let previous = edges.get(&resource.id);
    let added: Vec<u64> = dependencies
        .iter()
        .copied()
        .filter(|id| !previous.is_some_and(|old| old.contains(id)))
        .collect();
    if would_cycle(&edges, resource.id, &added) {
        drop(edges);
        drop(cell);
        reclaim_state(replacement);
        return Ok(cycle());
    }

    edges.insert(resource.id, dependencies);
    let old = cell.replace(replacement).ok_or(rustler::Error::BadArg)?;
    saturating_sub(&RETAINED_BYTES, old.retained_bytes);
    saturating_add(&RETAINED_BYTES, retained_bytes);
    drop(edges);
    drop(cell);

    // An evaluator cannot be interrupted between publication and notification:
    // both happen in this NIF call. A dead recipient simply discards its reply.
    for (pid, message) in notifications {
        let _ = env.send(&pid, message);
    }
    reclaim_state(old);
    Ok(ok())
}

#[rustler::nif(name = "nif_id")]
fn id(resource: ResourceArc<MemoCell>) -> u64 {
    resource.id
}

#[rustler::nif(name = "nif_resource_id")]
fn resource_id(term: Term<'_>) -> Option<u64> {
    term.decode::<ResourceArc<MemoCell>>()
        .ok()
        .map(|cell| cell.id)
}

#[rustler::nif(name = "nif_stats")]
fn stats() -> MemoStats {
    MemoStats {
        live_cells: LIVE_CELLS.load(Ordering::Acquire),
        retained_bytes: RETAINED_BYTES.load(Ordering::Acquire),
        pending_reclaims: PENDING_RECLAIMS.load(Ordering::Acquire),
    }
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
    0
}

extern "C" fn unload_native(
    _env: rustler::codegen_runtime::NIF_ENV,
    _private: *mut rustler::codegen_runtime::c_void,
) {
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
    fn accounting_never_wraps() {
        let counter = AtomicUsize::new(usize::MAX - 1);
        saturating_add(&counter, 10);
        assert_eq!(counter.load(Ordering::Relaxed), usize::MAX);
        saturating_sub(&counter, usize::MAX);
        saturating_sub(&counter, 1);
        assert_eq!(counter.load(Ordering::Relaxed), 0);
    }
}
