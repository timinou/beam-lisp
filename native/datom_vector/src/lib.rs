//! `vector` — the similarity kernel.
//!
//! # What this is
//!
//! beam-lisp's datom store is an ordered key/value space, and every index it
//! has (EAVT/AEVT/AVET/VAET) is the same datoms under a different *total byte
//! order*. That is the one thing this kernel is NOT: nearest-neighbour in a
//! high-dimensional metric space has no order-preserving 1-D key, so it cannot
//! be a fifth sorted index. It is a different ACCESS METHOD that lives beside
//! the ordered ones — a scan that computes a distance rather than a range.
//!
//! # The design that PLAN-042 made cheap
//!
//! PLAN-042 gave every datom value a packed, typed slot (`value-codec.bl`) and
//! a Rust reader (`resolve.rs`) that decodes a whole range by fixed offset in
//! one BEAM crossing. A vector is just "many f32s", so it is ONE MORE LANE in
//! that format and ONE MORE reader beside `resolve`: instead of returning the
//! floats as columns, this scans them and returns the k nearest. No separate
//! vector database — an extension of the columnar engine that already exists.
//!
//! # Why flat, and why binary-quantized
//!
//! For the corpora consumer apps actually hold — a person's notes, a codebase,
//! one book's passages: thousands to a few million vectors — a *flat* scan
//! (compare against everything) is both simplest and fast enough, and it is the
//! ONLY method that composes with exact pre-filtering (score just the candidate
//! set a datalog clause already narrowed). The graph indexes (HNSW) only earn
//! their complexity past ~10M vectors.
//!
//! Two speed levers, both here so the benchmark can weigh them:
//!
//!   * **f32 dot product.** Vectors are L2-normalised at insert, so cosine
//!     similarity IS the dot product — one multiply-add per dimension.
//!   * **binary quantisation.** Replace each dimension by its SIGN (1 bit).
//!     A 768-d vector becomes 12×u64 = 96 bytes (32× smaller). Distance is then
//!     `XOR + popcount` — a couple of instructions per 64 dims, which the CPU
//!     runs ~10-50× faster than the float path. It loses precision, so we take
//!     the top `rerank` candidates by Hamming and RE-SCORE those few on the
//!     exact f32 vectors. Coarse-and-cheap then fine-and-few: the accuracy of
//!     f32 at close to the speed of bits.
//!
//! The pure kernel (normalize/quantize/hamming/dot/search_*) is plain Rust over
//! slices — no rustler, no BEAM — so the benchmark measures the kernel, not the
//! boundary. The NIF surface at the bottom is the only BEAM-facing part.
//!
//! # Its own crate, on purpose
//!
//! Vector math is backend-agnostic: it works over embeddings held in the
//! in-memory ETS store exactly as over the durable redb one, because it never
//! touches a store at all — the datalog layer hands it packed bytes. So it is
//! NOT part of `datom_redb`; a separate crate gives it its own `init!` module
//! (rustler binds every `#[nif]` in a crate to one Erlang module) and keeps the
//! layering honest: `datom.vector` depends on this, not on the redb store.

use rustler::{Binary, Env, Error, NifResult, OwnedBinary};
use std::io::Write;

/// Wrap a message as a BEAM-raisable error term.
fn err(msg: impl std::fmt::Display) -> Error {
    Error::Term(Box::new(format!("{}", msg)))
}

/// Number of `u64` words needed to hold `dim` sign bits.
#[inline]
pub fn words_for(dim: usize) -> usize {
    dim.div_ceil(64)
}

/// L2-normalise in place. After this, `dot(a, b)` == cosine similarity.
///
/// A zero vector is left as zeros (its norm is 0); it will simply never be
/// anyone's nearest neighbour, which is the right behaviour for "no signal".
pub fn normalize(v: &mut [f32]) {
    let mut sum = 0.0f32;
    for &x in v.iter() {
        sum += x * x;
    }
    // `sum` is finite and > 0 for any real embedding. A non-finite sum (an Inf
    // or NaN slipped in) or a zero sum would make the scale Inf/NaN and poison
    // every later dot product — and `partial_cmp` treats NaN as equal, so the
    // ranking would go arbitrary rather than loud. Guard it: only scale when
    // the norm is a finite positive number.
    if sum.is_finite() && sum > 0.0 {
        let inv = 1.0 / sum.sqrt();
        for x in v.iter_mut() {
            *x *= inv;
        }
    }
}

/// Pack the SIGNS of `v` into a bit string: bit i set iff `v[i] > 0`.
///
/// This is the binary quantisation. The threshold is 0 because a normalised
/// embedding is centred near the origin; a per-dimension mean would be a touch
/// more accurate but would make the code depend on the corpus, and the rerank
/// step recovers the difference anyway.
pub fn quantize(v: &[f32]) -> Vec<u64> {
    let mut bits = vec![0u64; words_for(v.len())];
    for (i, &x) in v.iter().enumerate() {
        if x > 0.0 {
            bits[i >> 6] |= 1u64 << (i & 63);
        }
    }
    bits
}

/// Hamming distance between two packed bit strings: how many dimensions
/// disagree in sign. Smaller = more similar. This is the whole hot loop of the
/// coarse pass — `xor` then `count_ones`, which lowers to a POPCNT.
#[inline]
pub fn hamming(a: &[u64], b: &[u64]) -> u32 {
    let mut d = 0u32;
    for i in 0..a.len() {
        d += (a[i] ^ b[i]).count_ones();
    }
    d
}

/// Exact cosine similarity for normalised vectors (a plain dot product).
/// Larger = more similar — the opposite polarity to Hamming, on purpose: the
/// coarse pass minimises a distance, the fine pass maximises a similarity.
#[inline]
pub fn dot(a: &[f32], b: &[f32]) -> f32 {
    let mut s = 0.0f32;
    for i in 0..a.len() {
        s += a[i] * b[i];
    }
    s
}

/// A scored hit: the row index into the corpus and its similarity.
#[derive(Clone, Copy, Debug)]
pub struct Hit {
    pub id: u32,
    pub score: f32,
}

/// Exact brute-force search: dot the query against every vector, keep the top
/// `k`. This is the correctness ORACLE the quantised path is measured against,
/// and it is itself a perfectly good method up to ~1M vectors.
///
/// `corpus` is row-major: `n` vectors of `dim` f32s laid end to end.
pub fn search_flat(query: &[f32], corpus: &[f32], dim: usize, n: usize, k: usize) -> Vec<Hit> {
    let mut hits: Vec<Hit> = Vec::with_capacity(n);
    for i in 0..n {
        let row = &corpus[i * dim..(i + 1) * dim];
        hits.push(Hit {
            id: i as u32,
            score: dot(query, row),
        });
    }
    top_k_by_score(&mut hits, k);
    hits
}

/// Binary-quantised search with exact rerank: the recommended path.
///
///   1. Hamming-scan the packed codes (cheap) → keep the `rerank` closest.
///   2. Re-score ONLY those on the exact f32 vectors (accurate) → top `k`.
///
/// `rerank` trades accuracy for cost: larger recovers more of brute force's
/// recall at the price of more f32 dots. `rerank == k` is fastest and loosest;
/// `rerank` ≈ 10·k is the usual sweet spot.
pub fn search_quantized(
    query: &[f32],
    query_bits: &[u64],
    corpus: &[f32],
    codes: &[u64],
    dim: usize,
    words: usize,
    n: usize,
    k: usize,
    rerank: usize,
) -> Vec<Hit> {
    if n == 0 {
        return Vec::new();
    }
    // Coarse pass: Hamming against every code. We keep (id, distance) and take
    // the `rerank` smallest distances.
    let mut coarse: Vec<(u32, u32)> = Vec::with_capacity(n);
    for i in 0..n {
        let code = &codes[i * words..(i + 1) * words];
        coarse.push((i as u32, hamming(query_bits, code)));
    }
    // The coarse set must be at least `k` wide or the fine pass cannot return k
    // hits; widen `rerank` up to k, and never exceed n. `m >= 1` here because
    // n > 0 (guarded above), so the `m - 1` select index cannot underflow.
    let m = rerank.max(k).min(n).max(1);
    // partial selection of the m smallest by distance
    coarse.select_nth_unstable_by(m - 1, |a, b| a.1.cmp(&b.1));
    coarse.truncate(m);

    // Fine pass: exact dot on just those m candidates.
    let mut hits: Vec<Hit> = coarse
        .iter()
        .map(|&(id, _)| {
            let row = &corpus[id as usize * dim..(id as usize + 1) * dim];
            Hit {
                id,
                score: dot(query, row),
            }
        })
        .collect();
    top_k_by_score(&mut hits, k);
    hits
}

/// Sort `hits` descending by score and truncate to `k`. A partial select would
/// be marginally faster, but `k` is tiny (≤ a few hundred) so a full sort of
/// the already-small candidate set is not worth the subtlety.
fn top_k_by_score(hits: &mut Vec<Hit>, k: usize) {
    hits.sort_unstable_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    hits.truncate(k);
}

// ─────────────────────────────────────────────────────────────────────────
// NIF surface
//
// These are the BEAM entry points. They are deliberately PURE with respect to
// the database: none of them opens redb or knows a key encoding. The datalog
// layer scans the current embedding datoms (its own basis-aware job) and hands
// the corpus down as packed bytes; the NIF does only vector math and returns
// the k nearest. This is PLAN-039's step-1 rule — the numeric NIF stays
// trivially testable and the DB semantics stay in one place, in beam-lisp.
//
// On-disk vector format (LANE-VECTOR body): each vector is `dim` little-endian
// f32s, and stored NORMALISED so a dot product is a cosine similarity. f32 (not
// f64) because an embedding's precision is far below 23 mantissa bits and half
// the bytes means half the scan — the same reasoning that makes the packed
// value slot fixed-width.

/// Read `dim` little-endian f32s out of a byte slice into an f64 vector (the
/// BEAM's only float type). Returns None if the length is wrong.
fn unpack_f32(bytes: &[u8], dim: usize) -> Option<Vec<f32>> {
    if bytes.len() != dim * 4 {
        return None;
    }
    let mut v = vec![0.0f32; dim];
    for i in 0..dim {
        let mut a = [0u8; 4];
        a.copy_from_slice(&bytes[i * 4..i * 4 + 4]);
        v[i] = f32::from_le_bytes(a);
    }
    Some(v)
}

fn pack_f32(v: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(v.len() * 4);
    for &x in v {
        out.extend_from_slice(&x.to_le_bytes());
    }
    out
}

fn bin<'a>(env: Env<'a>, bytes: &[u8]) -> NifResult<Binary<'a>> {
    let mut owned = OwnedBinary::new(bytes.len()).ok_or_else(|| err("alloc"))?;
    owned.as_mut_slice().write_all(bytes).map_err(err)?;
    Ok(Binary::from_owned(owned, env))
}

/// `vec_pack(floats)` → the normalised LANE-VECTOR body (packed LE f32).
///
/// Normalising here, once, at write time is what lets every later search be a
/// bare dot product. The BEAM hands floats as f64; we narrow to f32 for storage.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn vec_pack<'a>(env: Env<'a>, floats: Vec<f64>) -> NifResult<Binary<'a>> {
    // Reject non-finite inputs at the door. A NaN/Inf component (or a value
    // like 1e308 that overflows f32) would normalise to NaN bytes and silently
    // corrupt every future comparison against this vector; better a loud error
    // at insert than arbitrary rankings at query time.
    for &x in floats.iter() {
        if !x.is_finite() || (x as f32).is_infinite() {
            return Err(err("vector contains a non-finite or out-of-f32-range value"));
        }
    }
    let mut v: Vec<f32> = floats.iter().map(|&x| x as f32).collect();
    normalize(&mut v);
    Ok(bin(env, &pack_f32(&v))?)
}

/// `vec_unpack(body, dim)` → the vector as a list of floats. The inverse of
/// `vec_pack` except for the normalisation, which is not undone (the stored
/// vector IS the unit vector). Used by the value-codec decode path so an
/// embedding round-trips to a readable value.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn vec_unpack(body: Binary, dim: usize) -> NifResult<Vec<f64>> {
    let v = unpack_f32(body.as_slice(), dim).ok_or_else(|| err("vector body length mismatch"))?;
    Ok(v.iter().map(|&x| x as f64).collect())
}

/// `vec_search(query, ids, corpus, dim, k, rerank)` → `[{id, score}]`, the k
/// nearest of `corpus` to `query` by cosine similarity (descending score).
///
/// - `query`  : the query vector as floats (normalised here defensively).
/// - `ids`    : entity ids parallel to the corpus rows — returned, not indexed.
/// - `corpus` : all candidate vectors, packed LE f32, row-major, `dim` each.
/// - `rerank` : binary-quant candidate width; 0 disables quantisation and does
///              an exact f32 flat scan (the precise, slower path).
///
/// The two-pass method (Prototype A): quantise → Hamming coarse pass → exact
/// f32 rerank. For the small corpora a per-query gather produces this is
/// already sub-millisecond; a resident index that avoids re-marshalling the
/// corpus every call is the scale step, not this.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn vec_search(
    query: Vec<f64>,
    ids: Vec<i64>,
    corpus: Binary,
    dim: usize,
    k: usize,
    rerank: usize,
) -> NifResult<Vec<(i64, f64)>> {
    let bytes = corpus.as_slice();
    if dim == 0 || bytes.len() % (dim * 4) != 0 {
        return Err(err("corpus length is not a whole number of vectors"));
    }
    let n = bytes.len() / (dim * 4);
    if n != ids.len() {
        return Err(err("ids and corpus row count disagree"));
    }

    // decode the whole corpus to f32 (row-major, contiguous)
    let mut flat = vec![0.0f32; n * dim];
    for i in 0..n {
        let row = unpack_f32(&bytes[i * dim * 4..(i + 1) * dim * 4], dim)
            .ok_or_else(|| err("corpus row length mismatch"))?;
        flat[i * dim..(i + 1) * dim].copy_from_slice(&row);
    }

    let mut q: Vec<f32> = query.iter().map(|&x| x as f32).collect();
    if q.len() != dim {
        return Err(err("query dimension disagrees with corpus"));
    }
    normalize(&mut q);

    let hits = if rerank == 0 {
        // exact flat: precise, and the right choice for small n or when recall
        // must be perfect.
        search_flat(&q, &flat, dim, n, k)
    } else {
        let words = words_for(dim);
        let mut codes = vec![0u64; n * words];
        for i in 0..n {
            let c = quantize(&flat[i * dim..(i + 1) * dim]);
            codes[i * words..(i + 1) * words].copy_from_slice(&c);
        }
        let qb = quantize(&q);
        search_quantized(&q, &qb, &flat, &codes, dim, words, n, k, rerank)
    };

    Ok(hits
        .iter()
        .map(|h| (ids[h.id as usize], h.score as f64))
        .collect())
}

// ─────────────────────────────────────────────────────────────────────────
// Clustering and dimensionality reduction
//
// Two more things a corpus of embeddings makes possible, both pure numeric
// loops that belong in Rust for the same reason search does. Neither knows the
// database; the datalog layer gathers the vectors and hands them down.

/// Decode a packed corpus binary into a contiguous f32 matrix (row-major).
fn decode_corpus(bytes: &[u8], dim: usize) -> Result<(usize, Vec<f32>), Error> {
    if dim == 0 || bytes.len() % (dim * 4) != 0 {
        return Err(err("corpus length is not a whole number of vectors"));
    }
    let n = bytes.len() / (dim * 4);
    let mut flat = vec![0.0f32; n * dim];
    for i in 0..n {
        let row = unpack_f32(&bytes[i * dim * 4..(i + 1) * dim * 4], dim)
            .ok_or_else(|| err("corpus row length mismatch"))?;
        flat[i * dim..(i + 1) * dim].copy_from_slice(&row);
    }
    Ok((n, flat))
}

/// `vec_kmeans(corpus, dim, k, iters, seed)` → a cluster id (0..k) per row.
///
/// Lloyd's algorithm: assign each point to its nearest centroid, move each
/// centroid to the mean of its points, repeat. Vectors are unit-normalised, so
/// "nearest" by Euclidean distance and by cosine agree, and the mean is
/// re-normalised so centroids stay on the sphere.
///
/// Deterministic given `seed` (k-means++ style spread initialisation over a
/// seeded PRNG), so a demo clusters the same way every run. Empty clusters are
/// left where they are rather than re-seeded — simpler, and harmless at the
/// sizes this serves.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn vec_kmeans(
    corpus: Binary,
    dim: usize,
    k: usize,
    iters: usize,
    seed: u64,
) -> NifResult<Vec<i64>> {
    let (n, flat) = decode_corpus(corpus.as_slice(), dim).map_err(|e| e)?;
    if k == 0 || n == 0 {
        return Ok(vec![0i64; n]);
    }
    let k = k.min(n);

    // k-means++ init: first centroid random, each next chosen with probability
    // proportional to squared distance from the nearest chosen centroid. Spread
    // initialisation is what keeps Lloyd's from collapsing two centroids onto
    // one cluster.
    let mut rng = seed ^ 0x9E3779B97F4A7C15;
    let mut next = || {
        rng ^= rng >> 12;
        rng ^= rng << 25;
        rng ^= rng >> 27;
        (rng.wrapping_mul(0x2545F4914F6CDD1D) >> 11) as f64 / (1u64 << 53) as f64
    };
    let mut centroids = vec![0.0f32; k * dim];
    let first = (next() * n as f64) as usize % n;
    centroids[0..dim].copy_from_slice(&flat[first * dim..(first + 1) * dim]);
    for c in 1..k {
        // distance of each point to its nearest already-chosen centroid
        let mut d2 = vec![0.0f64; n];
        let mut total = 0.0f64;
        for i in 0..n {
            let row = &flat[i * dim..(i + 1) * dim];
            let mut best = f32::INFINITY;
            for cc in 0..c {
                let cen = &centroids[cc * dim..(cc + 1) * dim];
                let mut s = 0.0f32;
                for d in 0..dim {
                    let diff = row[d] - cen[d];
                    s += diff * diff;
                }
                if s < best {
                    best = s;
                }
            }
            d2[i] = best as f64;
            total += best as f64;
        }
        // sample proportional to d2
        let mut target = next() * total;
        let mut chosen = n - 1;
        for i in 0..n {
            target -= d2[i];
            if target <= 0.0 {
                chosen = i;
                break;
            }
        }
        centroids[c * dim..(c + 1) * dim].copy_from_slice(&flat[chosen * dim..(chosen + 1) * dim]);
    }

    let mut assign = vec![0i64; n];
    for _ in 0..iters.max(1) {
        // assignment step
        let mut changed = false;
        for i in 0..n {
            let row = &flat[i * dim..(i + 1) * dim];
            let mut best = 0usize;
            let mut best_d = f32::INFINITY;
            for c in 0..k {
                let cen = &centroids[c * dim..(c + 1) * dim];
                let mut s = 0.0f32;
                for d in 0..dim {
                    let diff = row[d] - cen[d];
                    s += diff * diff;
                }
                if s < best_d {
                    best_d = s;
                    best = c;
                }
            }
            if assign[i] != best as i64 {
                assign[i] = best as i64;
                changed = true;
            }
        }
        // update step: centroid = normalised mean of its members
        let mut sums = vec![0.0f32; k * dim];
        let mut counts = vec![0u32; k];
        for i in 0..n {
            let c = assign[i] as usize;
            counts[c] += 1;
            let row = &flat[i * dim..(i + 1) * dim];
            let cen = &mut sums[c * dim..(c + 1) * dim];
            for d in 0..dim {
                cen[d] += row[d];
            }
        }
        for c in 0..k {
            if counts[c] > 0 {
                let cen = &mut sums[c * dim..(c + 1) * dim];
                for x in cen.iter_mut() {
                    *x /= counts[c] as f32;
                }
                normalize(cen);
                centroids[c * dim..(c + 1) * dim].copy_from_slice(cen);
            }
        }
        if !changed {
            break;
        }
    }
    Ok(assign)
}

/// `vec_pca_2d(corpus, dim)` → `[[x, y], …]`, each row's coordinates on the top
/// two principal components.
///
/// PCA the honest way for two components: centre the data, then find the two
/// directions of greatest variance by POWER ITERATION on the covariance
/// (implicitly, via repeated matrix-vector products against the data), with
/// deflation between them. No linear-algebra dependency — the covariance is
/// never materialised (it would be dim×dim); each iteration is O(n·dim).
///
/// This is what turns "10,000 embeddings" into a scatter plot a human can read:
/// clusters of related items become visible clouds.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn vec_pca_2d(corpus: Binary, dim: usize) -> NifResult<Vec<(f64, f64)>> {
    let (n, mut flat) = decode_corpus(corpus.as_slice(), dim).map_err(|e| e)?;
    if n == 0 {
        return Ok(vec![]);
    }
    // centre: subtract the mean vector
    let mut mean = vec![0.0f32; dim];
    for i in 0..n {
        for d in 0..dim {
            mean[d] += flat[i * dim + d];
        }
    }
    for d in 0..dim {
        mean[d] /= n as f32;
    }
    for i in 0..n {
        for d in 0..dim {
            flat[i * dim + d] -= mean[d];
        }
    }

    // power iteration for the leading eigenvector of X^T X (the covariance,
    // up to a scale): v ← normalise(X^T (X v)).
    let power_iter = |data: &[f32], seed: u64| -> Vec<f32> {
        let mut rng = seed | 1;
        let mut v = vec![0.0f32; dim];
        for x in v.iter_mut() {
            rng ^= rng >> 12;
            rng ^= rng << 25;
            rng ^= rng >> 27;
            *x = ((rng.wrapping_mul(0x2545F4914F6CDD1D) >> 40) as f32 / (1u32 << 24) as f32) - 0.5;
        }
        normalize(&mut v);
        for _ in 0..50 {
            // u = X v   (length n)
            let mut u = vec![0.0f32; n];
            for i in 0..n {
                let row = &data[i * dim..(i + 1) * dim];
                let mut s = 0.0f32;
                for d in 0..dim {
                    s += row[d] * v[d];
                }
                u[i] = s;
            }
            // w = X^T u   (length dim)
            let mut w = vec![0.0f32; dim];
            for i in 0..n {
                let row = &data[i * dim..(i + 1) * dim];
                let ui = u[i];
                for d in 0..dim {
                    w[d] += row[d] * ui;
                }
            }
            normalize(&mut w);
            v = w;
        }
        v
    };

    let pc1 = power_iter(&flat, 0x1234_5678);
    // deflate: remove the pc1 component from every row, then find pc2
    let mut deflated = flat.clone();
    for i in 0..n {
        let row = &mut deflated[i * dim..(i + 1) * dim];
        let mut proj = 0.0f32;
        for d in 0..dim {
            proj += row[d] * pc1[d];
        }
        for d in 0..dim {
            row[d] -= proj * pc1[d];
        }
    }
    let pc2 = power_iter(&deflated, 0x8765_4321);

    // project each centred row onto (pc1, pc2)
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        let row = &flat[i * dim..(i + 1) * dim];
        let mut x = 0.0f32;
        let mut y = 0.0f32;
        for d in 0..dim {
            x += row[d] * pc1[d];
            y += row[d] * pc2[d];
        }
        out.push((x as f64, y as f64));
    }
    Ok(out)
}

/// A marker `BeamLisp.Native.available?/1` calls to tell a loaded NIF from the
/// unloaded stub. Present here for symmetry with `datom_redb`, so a checkout
/// without a Rust toolchain reads the vector backend as ABSENT rather than
/// crashing at require time.
#[rustler::nif]
fn __nif_loaded__() -> bool {
    true
}

// The host module name must match what `BeamLisp.Native.host_module/1` derives
// from the `datom.vector` namespace: `BeamLisp.Native.Datom.Vector`.
rustler::init!("Elixir.BeamLisp.Native.Datom.Vector");

#[cfg(test)]
mod bench {
    use super::*;
    use std::time::Instant;

    struct Rng(u64);
    impl Rng {
        fn next_u64(&mut self) -> u64 {
            let mut x = self.0;
            x ^= x >> 12;
            x ^= x << 25;
            x ^= x >> 27;
            self.0 = x;
            x.wrapping_mul(0x2545F4914F6CDD1D)
        }
        fn unit(&mut self) -> f32 {
            (self.next_u64() as f64 / u64::MAX as f64) as f32
        }
        fn gaussian(&mut self) -> f32 {
            let mut s = 0.0f32;
            for _ in 0..4 {
                s += self.unit();
            }
            s - 2.0
        }
    }

    /// A clustered corpus with MANY small clusters and a continuous spread, so
    /// neighbourhoods have a real distance gradient rather than hundreds of
    /// identical twins. `c` large + moderate noise models a text-embedding
    /// manifold; the earlier 200-balanced-cluster generator produced huge
    /// Hamming tie-bands (every cluster member equidistant) that made recall a
    /// measurement of the GENERATOR, not the method.
    fn build_clustered(n: usize, dim: usize, c: usize, noise: f32, seed: u64) -> (Vec<f32>, Vec<u64>) {
        let words = words_for(dim);
        let mut rng = Rng(seed);
        let mut centroids = vec![0.0f32; c * dim];
        for j in 0..c {
            let row = &mut centroids[j * dim..(j + 1) * dim];
            for x in row.iter_mut() {
                *x = rng.gaussian();
            }
            normalize(row);
        }
        let mut corpus = vec![0.0f32; n * dim];
        let mut codes = vec![0u64; n * words];
        for i in 0..n {
            // pseudo-random cluster assignment + per-vector noise scale, so
            // members spread out at varying radii (a gradient, not a shell).
            let cl = (rng.next_u64() as usize) % c;
            let cen = &centroids[cl * dim..(cl + 1) * dim];
            let scale = noise * (0.3 + rng.unit());
            let row = &mut corpus[i * dim..(i + 1) * dim];
            for (d, x) in row.iter_mut().enumerate() {
                *x = cen[d] + scale * rng.gaussian();
            }
            normalize(row);
            let bits = quantize(row);
            codes[i * words..(i + 1) * words].copy_from_slice(&bits);
        }
        (corpus, codes)
    }

    fn recall(exact: &[Hit], approx: &[Hit]) -> f32 {
        let truth: std::collections::HashSet<u32> = exact.iter().map(|h| h.id).collect();
        let found = approx.iter().filter(|h| truth.contains(&h.id)).count();
        found as f32 / exact.len() as f32
    }

    #[test]
    fn bench_similarity_kernel() {
        let dim = 768usize;
        let words = words_for(dim);
        let k = 10usize;

        println!("\n=== similarity kernel benchmark (dim={dim}, k={k}) ===");
        println!("clustered corpus: c=N/50 centroids, graded noise (continuous manifold)");
        println!("query = held-out corpus vectors (leave-one-out); rerank scales ~N/250\n");
        println!(
            "{:>9} | {:>10} | {:>11} | {:>13} | {:>6}",
            "N", "flat f32", "coarse-only", "quant+rerank", "recall"
        );

        for &n in &[10_000usize, 100_000, 1_000_000] {
            let c = (n / 50).max(1);
            let (corpus, codes) = build_clustered(n, dim, c, 0.6, 0x9E3779B97F4A7C15);

            // TIMING is measured on one representative query, repeated. RECALL is
            // AVERAGED over many distinct leave-one-out queries: at k=10 a single
            // query only resolves recall to 10% steps with large variance, which
            // measures luck, not the method. The mean over 200 queries is the
            // honest accuracy figure.
            let qid = 12345usize % n;
            let query = corpus[qid * dim..(qid + 1) * dim].to_vec();
            let query_bits = quantize(&query);
            // rerank scales with the corpus (~0.4% of N, floor 200): the coarse
            // pass is so cheap that widening the candidate set to HOLD recall as
            // N grows costs almost nothing, which is the whole point of the knob.
            let rerank = (n / 250).max(200);

            let reps = if n >= 1_000_000 { 3 } else { 20 };

            let t0 = Instant::now();
            let mut _exact = Vec::new();
            for _ in 0..reps {
                _exact = search_flat(&query, &corpus, dim, n, k + 1);
            }
            let flat_ms = t0.elapsed().as_secs_f64() * 1000.0 / reps as f64;

            let t1 = Instant::now();
            let mut sink = 0u32;
            for _ in 0..reps {
                for i in 0..n {
                    sink = sink.wrapping_add(hamming(&query_bits, &codes[i * words..(i + 1) * words]));
                }
            }
            let coarse_ms = t1.elapsed().as_secs_f64() * 1000.0 / reps as f64;
            assert!(sink != 0 || n == 0);

            let t2 = Instant::now();
            for _ in 0..reps {
                let _ = search_quantized(&query, &query_bits, &corpus, &codes, dim, words, n, k + 1, rerank);
            }
            let quant_ms = t2.elapsed().as_secs_f64() * 1000.0 / reps as f64;

            // averaged recall over many leave-one-out queries (bounded sample so
            // the 1M oracle sweep stays under a minute)
            let nq = if n >= 1_000_000 { 40 } else { 200 };
            let mut racc = 0.0f32;
            for t in 0..nq {
                let id = (t * 4099 + 17) % n; // stride the corpus deterministically
                let q = corpus[id * dim..(id + 1) * dim].to_vec();
                let qb = quantize(&q);
                let mut ex = search_flat(&q, &corpus, dim, n, k + 1);
                ex.retain(|h| h.id as usize != id);
                ex.truncate(k);
                let mut ap = search_quantized(&q, &qb, &corpus, &codes, dim, words, n, k + 1, rerank);
                ap.retain(|h| h.id as usize != id);
                ap.truncate(k);
                racc += recall(&ex, &ap);
            }
            let r = racc / nq as f32;
            println!(
                "{:>9} | {:>8.3}ms | {:>9.3}ms | {:>11.3}ms | {:>5.0}%",
                n, flat_ms, coarse_ms, quant_ms, r * 100.0
            );
        }

        println!("\nrerank sweep (N=100000): recall vs cost");
        println!("{:>8} | {:>12} | {:>6}", "rerank", "quant+rerank", "recall");
        {
            let n = 100_000usize;
            let c = n / 50;
            let (corpus, codes) = build_clustered(n, dim, c, 0.6, 0x9E3779B97F4A7C15);
            let qid = 12345usize % n;
            let query = corpus[qid * dim..(qid + 1) * dim].to_vec();
            let query_bits = quantize(&query);
            let mut exact = search_flat(&query, &corpus, dim, n, k + 1);
            exact.retain(|h| h.id as usize != qid);
            exact.truncate(k);
            for &rerank in &[50usize, 100, 200, 500, 1000] {
                let t = Instant::now();
                let mut approx = Vec::new();
                for _ in 0..20 {
                    approx = search_quantized(&query, &query_bits, &corpus, &codes, dim, words, n, k + 1, rerank);
                }
                let ms = t.elapsed().as_secs_f64() * 1000.0 / 20.0;
                approx.retain(|h| h.id as usize != qid);
                approx.truncate(k);
                let r = recall(&exact, &approx);
                println!("{:>8} | {:>10.3}ms | {:>5.0}%", rerank, ms, r * 100.0);
            }
        }
        println!("=== end benchmark ===\n");
    }
}
