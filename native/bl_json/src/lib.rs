//! `bl_json` — the native half of `bl.json`, at SPIKE stage.
//!
//! FEAT-043's v2 design rests on three load-bearing assumptions. This file
//! exists to turn them from arguments into observations. Two are already
//! settled by reading rustler 0.38:
//!
//! 1. **A NIF cannot read `:persistent_term`.** `rustler::Env` exposes
//!    `whereis_pid`, `send` and `binary_to_term` and no MFA call, so the record
//!    registry has to arrive as an ARGUMENT. That is the better shape anyway:
//!    the registry is bl's policy, and `persistent_term:get` returns a shared
//!    term, so passing it costs nothing. Not a NIF's business to reach for.
//! 2. **A NIF can build a bl struct term** — `%BeamLisp.Vector{items: {…}}` is a
//!    map with a `__struct__` key, and `Env::map_new` + `Term::map_put` are
//!    enough. `spike_vector/1` is that claim, executed.
//! 3. **serde_json over an Erlang term walk is fast enough to matter.**
//!    `spike_encode/1` and `spike_decode/1` are the measurement.
//!
//! The term walk here converts to `serde_json::Value` first — an intermediate
//! tree the real encoder will NOT build, since it will stream through a
//! `Serializer`. So these numbers are an UPPER BOUND on the cost, which is the
//! direction that makes them safe to quote.
//!
//! What this file is NOT: the real encoder. No options, no ordering contract,
//! no error paths with an RFC 6901 pointer, no record handling. Those stay in
//! `bl.json`, which is the whole architecture — bl decides, Rust writes bytes.

use rustler::types::atom::Atom;
use rustler::types::map;
use rustler::types::tuple::make_tuple;
use rustler::{Binary, Env, Error, NifResult, OwnedBinary, Term};
use serde_json::{Map as JsonMap, Number as JsonNumber, Value as Json};
use std::collections::HashMap;

fn err(msg: impl std::fmt::Display) -> Error {
    Error::Term(Box::new(format!("{}", msg)))
}

/// The marker `vm.native/available?` calls to tell a loaded NIF from the
/// unloaded stub. Without it every availability check answers false while every
/// real call works — the capability reads as absent while being present.
#[rustler::nif]
fn __nif_loaded__() -> bool {
    true
}

/// Assumption 2: a NIF CAN build a bl struct term.
///
/// `%BeamLisp.Vector{items: {…}, meta: nil}` is an Erlang map with a
/// `__struct__` key holding the module atom; `items` is a TUPLE, not a list, so
/// `make_tuple` is what puts the elements in. If bl then reads this back as a
/// vector — `vector?`, `count`, and `bl.json/encode` giving `[1,2,3]` — the
/// claim holds and a native decoder can build bl values directly instead of
/// handing Elixir a list to wrap.
#[rustler::nif]
fn spike_vector<'a>(env: Env<'a>, items: Vec<Term<'a>>) -> NifResult<Term<'a>> {
    let tuple = make_tuple(env, &items);
    let m = map::map_new(env);
    let m = m.map_put(
        Atom::from_str(env, "__struct__")?,
        Atom::from_str(env, "Elixir.BeamLisp.Vector")?,
    )?;
    m.map_put(Atom::from_str(env, "items")?, tuple)
}

/// Assumption 3, encode direction. A term tree in, JSON bytes out.
#[rustler::nif(schedule = "DirtyCpu")]
fn spike_encode<'a>(env: Env<'a>, term: Term<'a>) -> NifResult<Binary<'a>> {
    let value = to_json(term)?;
    let bytes = serde_json::to_vec(&value).map_err(err)?;
    let mut owned = OwnedBinary::new(bytes.len()).ok_or_else(|| err("alloc"))?;
    owned.as_mut_slice().copy_from_slice(&bytes);
    Ok(Binary::from_owned(owned, env))
}

/// Assumption 3, decode direction. JSON bytes in, bl-shaped term out.
///
/// Arrays come back as LISTS here — the real decoder builds Vectors, and
/// `spike_vector/1` above is the evidence that it can.
#[rustler::nif(schedule = "DirtyIo")]
fn spike_decode<'a>(env: Env<'a>, data: Binary<'a>) -> NifResult<Term<'a>> {
    let value: Json = serde_json::from_slice(data.as_slice()).map_err(err)?;
    from_json(env, value)
}

// ── the term walk (spike: via an intermediate Value) ────────────────────────

fn as_key(term: Term) -> NifResult<String> {
    // `atom_to_string` lives on Term, not on Atom: it answers Ok only when the
    // term IS an atom, which is exactly the discriminator we want.
    if let Ok(name) = term.atom_to_string() {
        return Ok(name);
    }
    if let Ok(b) = term.decode::<Binary>() {
        return Ok(String::from_utf8_lossy(b.as_slice()).into_owned());
    }
    Err(err("object key is not an atom or a string"))
}

fn to_json(term: Term) -> NifResult<Json> {
    // Order matters: a binary must be claimed before the atom check would try
    // it, and integers before floats.
    if let Ok(b) = term.decode::<Binary>() {
        return Ok(Json::String(
            String::from_utf8_lossy(b.as_slice()).into_owned(),
        ));
    }
    if let Ok(name) = term.atom_to_string() {
        return Ok(match name.as_str() {
            "nil" => Json::Null,
            "true" => Json::Bool(true),
            "false" => Json::Bool(false),
            // a bl keyword and a bl symbol both cross as their name
            _ => Json::String(name),
        });
    }
    if let Ok(i) = term.decode::<i64>() {
        return Ok(Json::Number(JsonNumber::from(i)));
    }
    if let Ok(f) = term.decode::<f64>() {
        return JsonNumber::from_f64(f)
            .map(Json::Number)
            .ok_or_else(|| err("non-finite float"));
    }
    if let Ok(items) = term.decode::<Vec<Term>>() {
        let mut out = Vec::with_capacity(items.len());
        for item in items {
            out.push(to_json(item)?);
        }
        return Ok(Json::Array(out));
    }
    if let Ok(entries) = term.decode::<HashMap<Term, Term>>() {
        let mut out = JsonMap::new();
        for (k, v) in entries {
            out.insert(as_key(k)?, to_json(v)?);
        }
        return Ok(Json::Object(out));
    }
    Err(err("term has no JSON representation in the spike walk"))
}

fn from_json<'a>(env: Env<'a>, value: Json) -> NifResult<Term<'a>> {
    Ok(match value {
        Json::Null => Atom::from_str(env, "nil")?.to_term(env),
        Json::Bool(true) => Atom::from_str(env, "true")?.to_term(env),
        Json::Bool(false) => Atom::from_str(env, "false")?.to_term(env),
        Json::Number(n) => match n.as_i64() {
            Some(i) => rustler::Encoder::encode(&i, env),
            None => rustler::Encoder::encode(&n.as_f64().unwrap_or(0.0), env),
        },
        Json::String(s) => rustler::Encoder::encode(&s, env),
        Json::Array(a) => {
            let mut terms = Vec::with_capacity(a.len());
            for item in a {
                terms.push(from_json(env, item)?);
            }
            rustler::Encoder::encode(&terms, env)
        }
        Json::Object(m) => {
            // built with map_put rather than encoded from pairs: a Vec of tuples
            // is a LIST of tuples, which is not an Erlang map.
            let mut map = map::map_new(env);
            for (k, v) in m {
                map = map.map_put(k, from_json(env, v)?)?;
            }
            map
        }
    })
}

rustler::init!("Elixir.BeamLisp.Native.Bl.JsonSpike");
