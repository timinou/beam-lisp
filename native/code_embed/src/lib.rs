//! `code_embed` — static code embeddings (Model2Vec) behind a NIF resource.
//!
//! # What this is
//!
//! A static embedding model turns text into a vector by LOOKING UP each
//! token's row in a learned matrix and pooling the rows. There is no
//! transformer forward pass, no attention, no KV cache — inference is a hash
//! lookup plus a mean. That is why it fits here: `potion-code-16M-v2` (16M
//! params, 256-d, distilled from `nomic-ai/CodeRankEmbed`) costs ~32 MB on
//! disk and ~64 MB resident as f32, against ~600 MB for a code transformer of
//! comparable retrieval quality (`jina-embeddings-v2-base-code`, 161M params).
//!
//! # Why a resource, and why a separate crate
//!
//! The embedding matrix is the one part of this system that must NOT be a
//! BEAM term: 16M floats as a bl vector is 16M boxed floats plus list
//! overhead, and every embed would cross the boundary twice. Behind a
//! `ResourceArc` the weights live in Rust's heap for the lifetime of the
//! handle, the tokenizer is built once, and a batch crosses exactly once — as
//! packed f32 bytes, which is already the shape `datom.vector`'s `DVec` wants.
//!
//! It is its own crate for the same reason `datom_vector` is: rustler binds
//! every `#[nif]` in a crate to ONE Erlang module, so a second capability
//! built on the same math would have to share this `init!`. The boundary is
//! the partition.
//!
//! # What it does NOT know
//!
//! Nothing about datoms, entities, attributes or storage. It is text →
//! packed f32. The `code.embed` namespace owns availability and caching; the
//! datom layer owns where a vector lives. Same split as the vector kernel.

use model2vec::Model2Vec;
use rustler::{Binary, Env, Error, NifResult, OwnedBinary, ResourceArc};
use std::io::Write;

/// Wrap a message as a BEAM-raisable error term.
fn err(msg: impl std::fmt::Display) -> Error {
    Error::Term(Box::new(format!("{}", msg)))
}

/// A loaded static model. `Model2Vec` is `Send + Sync` (a `Tokenizer` and an
/// `Array2<f32>`); the handle is shared across schedulers, so a batch never
/// needs a lock — `encode` takes `&self`.
pub struct Embedder {
    model: Model2Vec,
}

// `resource_impl` (not a bare `impl rustler::Resource`): the attribute submits
// this type to rustler's `inventory`, and `init!`'s load callback registers
// every submitted type before the first NIF call. A bare impl compiles, and
// then `ResourceArc::new` panics at the first call with an unwrap on None —
// the resource type was never opened on the BEAM side. datom_vector pays for
// this with an explicit `load = hnsw::load`; here the attribute is enough.
#[rustler::resource_impl]
impl rustler::Resource for Embedder {}

// NIF returns cross a catch_unwind boundary, which demands RefUnwindSafe.
// `Model2Vec`'s interior is immutable after construction (the tokenizer's own
// interior mutability is a `Mutex`, which is unwind-safe), so the assertion
// is sound and no panic can observe a torn state.
impl std::panic::RefUnwindSafe for Embedder {}

/// `embedder_open(path)` → a model handle, or an error naming what is missing.
///
/// `path` is a LOCAL DIRECTORY holding `tokenizer.json`, `model.safetensors`
/// and `config.json` — the three files a Model2Vec model is. Nothing here
/// downloads: fetching is a separate, explicit, offline-after-first-run step
/// (`mix beam_lisp.embed.fetch`), so a call can never block on the network by
/// accident.
#[rustler::nif(schedule = "DirtyIo")]
pub fn embedder_open(path: String) -> NifResult<ResourceArc<Embedder>> {
    let dir = std::path::Path::new(&path);
    for f in ["tokenizer.json", "model.safetensors", "config.json"] {
        if !dir.join(f).exists() {
            return Err(err(format!("{}/{} is missing", path, f)));
        }
    }
    let model = Model2Vec::from_pretrained(dir, None, None)
        .map_err(|e| err(format!("could not load a static model from {path}: {e}")))?;
    Ok(ResourceArc::new(Embedder { model }))
}

/// `embedder_dim(handle)` → the embedding width (256 for potion-code-16M-v2).
#[rustler::nif]
pub fn embedder_dim(handle: ResourceArc<Embedder>) -> usize {
    handle.model.embedding_dim()
}

/// `embedder_encode(handle, texts, max_length)` → one packed little-endian f32
/// binary holding `count * dim` floats, row-major, ALREADY L2-normalised
/// (the model's `normalize: true`).
///
/// One binary rather than a list of lists: the caller slices row `i` out with
/// `binary_part` and hands it straight to a `DVec` body, so a batch of N
/// documents costs one BEAM crossing instead of N, and no float ever crosses
/// as a boxed term.
///
/// `max_length` is the token budget per text (0 = the model's own default,
/// 512). It bounds work on the pathological case — a 4 000-line file — without
/// silently truncating ordinary inputs.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn embedder_encode<'a>(
    env: Env<'a>,
    handle: ResourceArc<Embedder>,
    texts: Vec<String>,
    max_length: usize,
) -> NifResult<Binary<'a>> {
    let dim = handle.model.embedding_dim();
    let budget = if max_length == 0 { None } else { Some(max_length) };
    let rows = handle
        .model
        .encode_with_args(&texts, budget, texts.len().max(1))
        .map_err(err)?;
    if rows.ncols() != dim {
        return Err(err("encoder returned an unexpected dimensionality"));
    }
    let bytes = rows.as_slice().ok_or_else(|| err("encoder result is not contiguous"))?;
    let packed = pack_f32(bytes);
    let mut owned = OwnedBinary::new(packed.len()).ok_or_else(|| err("alloc"))?;
    owned.as_mut_slice().write_all(&packed).map_err(err)?;
    Ok(Binary::from_owned(owned, env))
}

fn pack_f32(v: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(v.len() * 4);
    for &x in v {
        out.extend_from_slice(&x.to_le_bytes());
    }
    out
}

/// The marker `BeamLisp.Native.available?/1` calls to tell a loaded NIF from the
/// unloaded stub. A `defnative` host module always DEFINES `__nif_loaded__/0` —
/// with a body that raises — and only `load_nif` replaces it. So a crate that
/// does not export it leaves every availability check answering false while
/// every real call works: the capability reads as absent while being present.
/// datom_vector exports the same marker for the same reason.
#[rustler::nif]
fn __nif_loaded__() -> bool {
    true
}

rustler::init!("Elixir.BeamLisp.Native.Code.Embed");
