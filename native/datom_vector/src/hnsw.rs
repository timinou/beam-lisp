// hnsw.rs — a resident approximate-nearest-neighbour index behind a NIF
// resource, plus the batch exact all-pairs k-NN that serves as the exact
// escape hatch.
//
// Why a resource: `vec_search` re-marshals the whole corpus on every call —
// right for a per-query gather, wrong for a relation that is ASKED REPEATEDLY.
// The index pays the build once, then each insert is O(log N) and each search
// is O(log N)-ish, which is what turns the all-pairs semantic graph from
// O(N²) into O(N log N).
//
// What the index does NOT know: bases, retractions, attributes. It holds
// points keyed by entity id and a tombstone set; the beam-lisp side
// (datom.query.relations) owns the cursor/catch-up/rebuild state machine and
// decides what "live" means. Deletion here is tombstone-and-filter — hnsw_rs
// cannot unlink a point from the graph — so tombstones accumulate until the
// bl-side policy rebuilds. That split is deliberate: DB semantics in one
// place (bl), graph arithmetic in one place (here).

use hnsw_rs::prelude::*;
use rustler::{Binary, Env, Error, NifResult, ResourceArc, Term};
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use crate::{err, normalize, pack_f32, unpack_f32};

/// The resident index. `inner` is internally concurrent (insert and search
/// take `&self`); the Mutex guards only the entity↔point bookkeeping, so a
/// search holds the lock for its filter-set lookup, never for graph mutation.
pub struct HnswIndex {
    dim: usize,
    ef_search: usize,
    inner: Hnsw<'static, f32, DistCosine>,
    book: Mutex<Book>,
}

pub struct Book {
    /// entity id → point id (live entries only)
    by_eid: HashMap<i64, usize>,
    /// point id → entity id (append-only; tombstoned entries stay)
    eids: Vec<i64>,
    /// point ids removed from the live set — filtered out of every search
    tombstoned: HashSet<usize>,
}

impl rustler::Resource for HnswIndex {}

// NIF returns cross a catch_unwind boundary, which demands RefUnwindSafe.
// Hnsw's internals don't auto-implement it; every mutation path we expose is
// either internally concurrent (hnsw_rs insert/search take &self) or guarded
// by `book`'s Mutex (whose poisoning we surface as an error, not a state we
// observe), so the assertion is sound.
impl std::panic::RefUnwindSafe for HnswIndex {}

fn err_str(msg: impl std::fmt::Display) -> Error {
    err(msg)
}

/// `hnsw_new(dim, m, ef_construction, ef_search, max_elements)` → index resource.
///
/// `m` is clamped to hnsw_rs's hard ceiling (256) because the library EXITS
/// THE PROCESS over it rather than erroring — an exit inside a NIF takes the
/// whole VM down, so we refuse first.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn hnsw_new(
    dim: usize,
    m: usize,
    ef_construction: usize,
    ef_search: usize,
    max_elements: usize,
) -> NifResult<ResourceArc<HnswIndex>> {
    if dim == 0 {
        return Err(err_str("dim must be positive"));
    }
    if m > 256 {
        return Err(err_str("m must be <= 256 (hnsw_rs process-exits above that)"));
    }
    let inner = Hnsw::new(m, max_elements.max(16), 16, ef_construction.max(m), DistCosine);
    Ok(ResourceArc::new(HnswIndex {
        dim,
        ef_search,
        inner,
        book: Mutex::new(Book {
            by_eid: HashMap::new(),
            eids: Vec::new(),
            tombstoned: HashSet::new(),
        }),
    }))
}

fn insert_f32(index: &HnswIndex, eid: i64, mut v: Vec<f32>) -> NifResult<bool> {
    if v.len() != index.dim {
        return Err(err_str("vector dimension disagrees with index"));
    }
    normalize(&mut v);
    let pid = {
        let mut book = index.book.lock().map_err(|_| err_str("index lock poisoned"))?;
        if let Some(&old) = book.by_eid.get(&eid) {
            book.tombstoned.insert(old);
        }
        let pid = book.eids.len();
        book.eids.push(eid);
        book.by_eid.insert(eid, pid);
        pid
    };
    index.inner.insert((&v, pid));
    Ok(true)
}

/// `hnsw_insert(index, eid, floats)` → :ok. Re-inserting a live eid
/// tombstones its old point first (a re-embed is retract+assert; the old
/// vector must stop surfacing).
#[rustler::nif(schedule = "DirtyCpu")]
pub fn hnsw_insert(index: ResourceArc<HnswIndex>, eid: i64, floats: Vec<f64>) -> NifResult<bool> {
    let v: Vec<f32> = floats.iter().map(|&x| x as f32).collect();
    insert_f32(&index, eid, v)
}

/// `hnsw_insert_packed(index, eid, body)` → :ok, inserting a DVec body
/// (packed LE f32, already normalised at pack time) WITHOUT the f64-list
/// round trip — the hot path, one N crossing per insert.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn hnsw_insert_packed(
    index: ResourceArc<HnswIndex>,
    eid: i64,
    body: Binary,
) -> NifResult<bool> {
    let v = unpack_f32(body.as_slice(), index.dim)
        .ok_or_else(|| err_str("vector body length mismatch"))?;
    insert_f32(&index, eid, v)
}

/// `hnsw_tombstone(index, eid)` → whether the eid was live. The point stays
/// in the graph (hnsw_rs has no unlink) but is filtered from every search
/// until the next rebuild.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn hnsw_tombstone(index: ResourceArc<HnswIndex>, eid: i64) -> NifResult<bool> {
    let mut book = index.book.lock().map_err(|_| err_str("index lock poisoned"))?;
    if let Some(pid) = book.by_eid.remove(&eid) {
        book.tombstoned.insert(pid);
        Ok(true)
    } else {
        Ok(false)
    }
}

fn search_f32(index: &HnswIndex, mut q: Vec<f32>, k: usize) -> NifResult<Vec<(i64, f64)>> {
    if q.len() != index.dim {
        return Err(err_str("query dimension disagrees with index"));
    }
    normalize(&mut q);
    let book = index.book.lock().map_err(|_| err_str("index lock poisoned"))?;
    let total = book.eids.len();
    if total == 0 || k == 0 {
        return Ok(Vec::new());
    }
    let want = (k + book.tombstoned.len() + 1).min(total);
    let ef = index.ef_search.max(want);
    let neighbours = index.inner.search(&q, want, ef);
    let mut out = Vec::with_capacity(k);
    for n in neighbours.iter() {
        let pid = n.d_id;
        if book.tombstoned.contains(&pid) {
            continue;
        }
        out.push((book.eids[pid], (1.0 - n.distance) as f64));
        if out.len() == k {
            break;
        }
    }
    Ok(out)
}

/// `hnsw_search(index, floats, k)` → `[{eid, score}]` descending, tombstoned
/// points excluded. Over-fetches by the tombstone count so filtering does not
/// starve the result; score = 1 - cosine-distance, i.e. cosine similarity.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn hnsw_search(
    index: ResourceArc<HnswIndex>,
    floats: Vec<f64>,
    k: usize,
) -> NifResult<Vec<(i64, f64)>> {
    let q: Vec<f32> = floats.iter().map(|&x| x as f32).collect();
    search_f32(&index, q, k)
}

/// `hnsw_search_packed(index, body, k)` → same, from a packed DVec body.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn hnsw_search_packed(
    index: ResourceArc<HnswIndex>,
    body: Binary,
    k: usize,
) -> NifResult<Vec<(i64, f64)>> {
    let q = unpack_f32(body.as_slice(), index.dim)
        .ok_or_else(|| err_str("query body length mismatch"))?;
    search_f32(&index, q, k)
}

/// `hnsw_stats(index)` → {live, tombstoned, total} for the bl-side policy
/// counters (the ratio trigger reads tombstoned/live from here).
#[rustler::nif]
pub fn hnsw_stats(index: ResourceArc<HnswIndex>) -> NifResult<(usize, usize, usize)> {
    let book = index.book.lock().map_err(|_| err_str("index lock poisoned"))?;
    Ok((book.by_eid.len(), book.tombstoned.len(), book.eids.len()))
}

/// `vec_knn_all(ids, corpus, dim, k, threshold)` → `[{a, b, score}]`, the
/// EXACT all-pairs k-NN edge list: every row's top-k by cosine, self
/// excluded, below-threshold dropped.
///
/// This is the honest O(N²) — but it runs as ONE NIF call over one packed
/// binary, so the constant is the autovectorised `dot`, not N² per-call
/// marshalling. It powers the exact escape hatch (`:strategy :exact`) and the
/// as-of bypass, where correctness must be bit-identical to the oracle, not
/// recall-bounded.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn vec_knn_all(
    ids: Vec<i64>,
    corpus: Binary,
    dim: usize,
    k: usize,
    threshold: f64,
) -> NifResult<Vec<(i64, i64, f64)>> {
    let bytes = corpus.as_slice();
    if dim == 0 || bytes.len() % (dim * 4) != 0 {
        return Err(err_str("corpus length is not a whole number of vectors"));
    }
    let n = bytes.len() / (dim * 4);
    if n != ids.len() {
        return Err(err_str("ids and corpus row count disagree"));
    }
    let mut flat = vec![0.0f32; n * dim];
    for i in 0..n {
        let row = unpack_f32(&bytes[i * dim * 4..(i + 1) * dim * 4], dim)
            .ok_or_else(|| err_str("corpus row length mismatch"))?;
        flat[i * dim..(i + 1) * dim].copy_from_slice(&row);
    }
    let mut edges = Vec::new();
    for i in 0..n {
        let q = &flat[i * dim..(i + 1) * dim];
        let mut taken = 0usize;
        // k+1 so the self-hit can be dropped without starving the row
        for hit in crate::search_flat(q, &flat, dim, n, k + 1) {
            if taken >= k {
                break;
            }
            let j = hit.id as usize;
            if j == i || (hit.score as f64) < threshold {
                continue;
            }
            edges.push((ids[i], ids[j], hit.score as f64));
            taken += 1;
        }
    }
    Ok(edges)
}

/// Pack a corpus of float-lists into one row-major binary (the argument
/// shape `vec_knn_all` wants, built without N crossings per row).
#[rustler::nif(schedule = "DirtyCpu")]
pub fn vec_pack_rows<'a>(env: Env<'a>, rows: Vec<Vec<f64>>) -> NifResult<Binary<'a>> {
    let mut bytes = Vec::new();
    for row in rows.iter() {
        let mut v: Vec<f32> = row.iter().map(|&x| x as f32).collect();
        normalize(&mut v);
        bytes.extend_from_slice(&pack_f32(&v));
    }
    let mut owned = rustler::OwnedBinary::new(bytes.len()).ok_or_else(|| err_str("alloc"))?;
    owned.as_mut_slice().copy_from_slice(&bytes);
    Ok(Binary::from_owned(owned, env))
}

pub fn load(env: Env, _info: Term) -> bool {
    let _ = env.register::<HnswIndex>();
    true
}
