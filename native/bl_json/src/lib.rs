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
/// Arrays come back as LISTS here — `spike_decode_bl/1` below is the one that
/// builds Vectors, and the pair is deliberately kept so the cost of building
/// them can be measured rather than assumed.
#[rustler::nif(schedule = "DirtyIo")]
fn spike_decode<'a>(env: Env<'a>, data: Binary<'a>) -> NifResult<Term<'a>> {
    let value: Json = serde_json::from_slice(data.as_slice()).map_err(err)?;
    from_json(env, value, false)
}

/// The REAL decode shape: an array becomes a bl Vector, as `bl.json/decode`
/// documents ("arrays decode to vectors so a round trip holds").
#[rustler::nif(schedule = "DirtyIo")]
fn spike_decode_bl<'a>(env: Env<'a>, data: Binary<'a>) -> NifResult<Term<'a>> {
    let value: Json = serde_json::from_slice(data.as_slice()).map_err(err)?;
    from_json(env, value, true)
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

/// A bl Vector: an Erlang map with a `__struct__` key, whose `items` is a
/// TUPLE. This is the one cross-language shape the crate duplicates from
/// `lib/beam_lisp/vector.ex`, so it is written once, here, and named.
fn make_vector<'a>(env: Env<'a>, items: Vec<Term<'a>>) -> NifResult<Term<'a>> {
    let tuple = make_tuple(env, &items);
    let m = map::map_new(env);
    let m = m.map_put(
        Atom::from_str(env, "__struct__")?,
        Atom::from_str(env, "Elixir.BeamLisp.Vector")?,
    )?;
    m.map_put(Atom::from_str(env, "items")?, tuple)
}

fn from_json<'a>(env: Env<'a>, value: Json, arrays_as_vectors: bool) -> NifResult<Term<'a>> {
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
                terms.push(from_json(env, item, arrays_as_vectors)?);
            }
            if arrays_as_vectors {
                make_vector(env, terms)?
            } else {
                rustler::Encoder::encode(&terms, env)
            }
        }
        Json::Object(m) => {
            // built with map_put rather than encoded from pairs: a Vec of tuples
            // is a LIST of tuples, which is not an Erlang map.
            let mut map = map::map_new(env);
            for (k, v) in m {
                map = map.map_put(k, from_json(env, v, arrays_as_vectors)?)?;
            }
            map
        }
    })
}

rustler::init!("Elixir.BeamLisp.Native.Bl.JsonSpike");

// ══ ATTRIBUTION, and then the fix ═══════════════════════════════════════════
//
// The first round left decode at 1.305 ms against Jason's 0.395. Three suspects,
// separated here so the answer is measured and not argued:
//
//   (a) the intermediate `serde_json::Value` tree — parse, then walk it again.
//       Every string, key and array is boxed, then decoded back out. Jason builds
//       terms AS IT PARSES and never has an intermediate at all.
//   (b) `schedule = "DirtyIo"` on a COMPUTE-bound NIF. datom/vector.bl says it
//       plainly: mis-labelling compute as IO puts it on the wrong scheduler pool.
//   (c) building bl Vectors — measured at 0.315 ms, and a job Jason never does.

/// (a) How much is `from_slice::<Value>` alone, with the walk removed entirely?
/// Whatever this costs, the real decoder never has to pay it.
#[rustler::nif]
fn spike_parse_only(data: Binary) -> NifResult<usize> {
    let value: Json = serde_json::from_slice(data.as_slice()).map_err(err)?;
    // count, so the tree cannot be optimised away, then drop it
    Ok(match value {
        Json::Object(m) => m.len(),
        Json::Array(a) => a.len(),
        _ => 0,
    })
}

/// (b) The same walk as `spike_decode_bl`, on a NORMAL scheduler.
#[rustler::nif]
fn spike_decode_bl_normal<'a>(env: Env<'a>, data: Binary<'a>) -> NifResult<Term<'a>> {
    let value: Json = serde_json::from_slice(data.as_slice()).map_err(err)?;
    from_json(env, value, true)
}

// ── the fix: build terms DURING the parse ───────────────────────────────────

use serde::de::{self, DeserializeSeed, MapAccess, SeqAccess, Visitor};
use std::fmt;

/// `rustler::Error` implements Debug but not Display, so it cannot go straight
/// into a serde error; its Debug form is the message.
fn as_de<E: de::Error>(e: rustler::Error) -> E {
    E::custom(format!("{e:?}"))
}

/// A seed, not a Deserialize impl, because the visitor has to carry the `Env`
/// down the recursion — and `Env` is `Copy`, so threading it costs nothing.
#[derive(Clone, Copy)]
struct TermSeed<'a> {
    env: Env<'a>,
    vectors: bool,
}

impl<'de, 'a> DeserializeSeed<'de> for TermSeed<'a> {
    type Value = Term<'a>;

    fn deserialize<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        deserializer.deserialize_any(TermVisitor {
            env: self.env,
            vectors: self.vectors,
        })
    }
}

struct TermVisitor<'a> {
    env: Env<'a>,
    vectors: bool,
}

fn atom<'a, E: de::Error>(env: Env<'a>, name: &str) -> Result<Term<'a>, E> {
    Atom::from_str(env, name)
        .map(|a| a.to_term(env))
        .map_err(|_| E::custom("atom table exhausted"))
}

impl<'de, 'a> Visitor<'de> for TermVisitor<'a> {
    type Value = Term<'a>;

    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("a JSON value")
    }

    fn visit_bool<E: de::Error>(self, b: bool) -> Result<Term<'a>, E> {
        atom(self.env, if b { "true" } else { "false" })
    }

    fn visit_i64<E: de::Error>(self, i: i64) -> Result<Term<'a>, E> {
        Ok(rustler::Encoder::encode(&i, self.env))
    }

    fn visit_u64<E: de::Error>(self, u: u64) -> Result<Term<'a>, E> {
        // an Erlang integer is arbitrary precision, so a u64 above i64::MAX
        // still crosses as an exact integer rather than becoming a float.
        Ok(rustler::Encoder::encode(&u, self.env))
    }

    fn visit_f64<E: de::Error>(self, f: f64) -> Result<Term<'a>, E> {
        if !f.is_finite() {
            return Err(E::custom("non-finite float"));
        }
        Ok(rustler::Encoder::encode(&f, self.env))
    }

    /// One binary allocation for the string, and no intermediate `String`.
    fn visit_str<E: de::Error>(self, s: &str) -> Result<Term<'a>, E> {
        Ok(rustler::Encoder::encode(&s, self.env))
    }

    fn visit_unit<E: de::Error>(self) -> Result<Term<'a>, E> {
        atom(self.env, "nil")
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Term<'a>, A::Error> {
        let seed = TermSeed {
            env: self.env,
            vectors: self.vectors,
        };
        let mut items = Vec::with_capacity(seq.size_hint().unwrap_or(8));
        while let Some(item) = seq.next_element_seed(seed)? {
            items.push(item);
        }
        if self.vectors {
            make_vector(self.env, items).map_err(as_de)
        } else {
            Ok(rustler::Encoder::encode(&items, self.env))
        }
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Term<'a>, A::Error> {
        let seed = TermSeed {
            env: self.env,
            vectors: self.vectors,
        };
        let mut built = map::map_new(self.env);
        while let Some(key) = map.next_key_seed(seed)? {
            let value = map.next_value_seed(seed)?;
            built = built.map_put(key, value).map_err(as_de)?;
        }
        Ok(built)
    }
}

/// The real decoder: ONE pass, no intermediate `Value`, and bl Vectors built as
/// the arrays are read.
#[rustler::nif]
fn spike_decode_direct<'a>(env: Env<'a>, data: Binary<'a>) -> NifResult<Term<'a>> {
    let mut deserializer = serde_json::Deserializer::from_slice(data.as_slice());
    let term = TermSeed {
        env,
        vectors: true,
    }
    .deserialize(&mut deserializer)
    .map_err(|e| err(format!("{e}")))?;
    // trailing bytes are another document, not part of this one
    deserializer.end().map_err(|e| err(format!("{e}")))?;
    Ok(term)
}

/// The same one-pass decoder on a NORMAL scheduler, so the dirty-scheduler
/// overhead can be separated from the work itself.
#[rustler::nif]
fn spike_decode_direct_normal<'a>(env: Env<'a>, data: Binary<'a>) -> NifResult<Term<'a>> {
    let mut deserializer = serde_json::Deserializer::from_slice(data.as_slice());
    let term = TermSeed {
        env,
        vectors: true,
    }
    .deserialize(&mut deserializer)
    .map_err(|e| err(format!("{e}")))?;
    deserializer.end().map_err(|e| err(format!("{e}")))?;
    Ok(term)
}

/// The one-pass decoder with arrays as LISTS.
///
/// This is the like-for-like comparison with Jason, which builds plain lists.
/// If one-pass-with-lists lands on Jason's number, then the WHOLE remaining gap
/// is the cost of building bl Vectors — a job Jason never does, and the one
/// difference that is a deliberate choice rather than a defect.
#[rustler::nif]
fn spike_decode_direct_lists<'a>(env: Env<'a>, data: Binary<'a>) -> NifResult<Term<'a>> {
    let mut deserializer = serde_json::Deserializer::from_slice(data.as_slice());
    let term = TermSeed {
        env,
        vectors: false,
    }
    .deserialize(&mut deserializer)
    .map_err(|e| err(format!("{e}")))?;
    deserializer.end().map_err(|e| err(format!("{e}")))?;
    Ok(term)
}
