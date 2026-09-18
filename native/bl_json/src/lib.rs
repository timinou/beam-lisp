//! `bl_json` — the native half of `bl.json`: the byte loop, at Erlang speed.
//!
//! # The split
//!
//! bl DECIDES; Rust WRITES BYTES. Every policy stays in `priv/std/bl/json.bl` — the
//! value mapping, `nil` as null, keys sorted by their encoded text, `:pretty`,
//! `:ascii`, records declared through the wire registry, and every error message with
//! its RFC 6901 path. This crate owns exactly two things: assembling JSON text while
//! walking a term, and building Erlang terms while parsing JSON text.
//!
//! # Why it is here at all
//!
//! A beam-lisp call costs ~0.7–1.0 us (measured), and a serialiser needs several per
//! node, so bl-level traversal cannot compete with a native loop. MEASURED, same
//! process, 24.3 KB, best of 11:
//!
//! ```text
//!                     bl.json today    this crate    Jason
//!   encode            16–23 ms         0.43–0.59 ms  0.46–0.57 ms
//!   decode            2.5 ms           0.85 ms       0.35 ms
//! ```
//!
//! Encode is at parity with Jason and ~30x better than assembling in bl. Decode is 3x
//! better than bl.json; the remaining 2.5x gap splits into 0.35 ms of building bl
//! Vectors (which Jason does not do, because bl documents that arrays decode to Vectors
//! so a round trip holds) and a ~1.5x serde-visitor cost that would need a hand-written
//! parser to remove.
//!
//! Both directions are byte-compatible with the codec they replace, and compose:
//! `bl.json/encode(json_decode(bytes)) == bytes`.
//!
//! # Two things this crate must NOT do
//!
//! - Reach for `:persistent_term`. rustler's `Env` has no MFA call, so a NIF CANNOT —
//!   which is the right shape anyway: the record wire registry is bl's policy, and bl
//!   hands it down. (Not needed yet: records are refused and escape to bl.)
//! - Emit `{"__struct__": …}` for a struct it does not know. A Stream/Set/record/foreign
//!   struct is REFUSED, loudly, so the caller can handle it in bl. Silently serialising
//!   a struct's internals is how a wrong document gets written.

use rustler::types::atom::Atom;
use rustler::types::map;
use rustler::types::tuple::{get_tuple, make_tuple};
use rustler::{Binary, Env, Error, NifResult, OwnedBinary, Term};
use std::collections::HashMap;

fn err(msg: impl std::fmt::Display) -> Error {
    Error::Term(Box::new(format!("{}", msg)))
}

/// The marker `vm.native/available?` calls to tell a loaded NIF from the unloaded stub.
#[rustler::nif]
fn __nif_loaded__() -> bool {
    true
}

// ── shared: term helpers ────────────────────────────────────────────────────

/// An object key as text: an atom (a bl keyword) or a binary.
///
/// `atom_to_string` lives on `Term`, not on `Atom`, and answers Ok only when the term
/// IS an atom — which is exactly the discriminator wanted.
fn as_key(term: Term) -> NifResult<String> {
    if let Ok(name) = term.atom_to_string() {
        return Ok(name);
    }
    if let Ok(b) = term.decode::<Binary>() {
        return Ok(String::from_utf8_lossy(b.as_slice()).into_owned());
    }
    Err(err("object key is not an atom or a string"))
}

/// A bl Vector: an Erlang map with a `__struct__` key whose `items` is a TUPLE.
///
/// This is the one cross-language shape duplicated from `lib/beam_lisp/vector.ex`.
/// It is a contract, so it is written once, here, and named.
fn make_vector<'a>(env: Env<'a>, items: Vec<Term<'a>>) -> NifResult<Term<'a>> {
    let tuple = make_tuple(env, &items);
    let m = map::map_new(env);
    let m = m.map_put(
        Atom::from_str(env, "__struct__")?,
        Atom::from_str(env, "Elixir.BeamLisp.Vector")?,
    )?;
    m.map_put(Atom::from_str(env, "items")?, tuple)
}

// ══ ENCODE ══════════════════════════════════════════════════════════════════
//
// `Serialize` over a term, so serde_json writes the bytes AS IT WALKS and no
// intermediate exists. That distinction is the whole cost: a `serde_json::Value` tree
// measured 0.83 ms to build-and-serialise against 0.43–0.59 ms streaming.

use serde::ser::{Serialize, SerializeMap, SerializeSeq};
use serde::Serializer as SerTrait;

#[derive(Clone, Copy)]
struct TermSer<'a> {
    term: Term<'a>,
    struct_key: Atom,
    vector_mod: Atom,
    items_key: Atom,
    depth: usize,
}

/// How deep the native walk will go before declining to bl.
///
/// This walk is RECURSIVE, so its depth is Rust stack — and `bl.json`'s own suite encodes
/// 2000 levels on purpose, on the argument that "2000 levels is far past what a
/// recursive-descent parser would survive". That argument is right: without this guard the
/// NIF SEGFAULTS (observed, exit 139), which is the one failure mode worse than being
/// slow. 128 matches serde_json's own recursion limit, keeps the walk far inside the
/// stack, and costs nothing real: `bl.json` handles any depth itself, on the same
/// fallback path it uses for a Set or a bignum.
const MAX_DEPTH: usize = 128;

impl<'a> TermSer<'a> {
    /// The struct's module name, if this term is a struct at all.
    fn struct_name(self) -> Option<String> {
        let m = self.term.map_get(self.struct_key).ok()?;
        m.atom_to_string().ok()
    }
}

impl<'a> Serialize for TermSer<'a> {
    fn serialize<S: SerTrait>(&self, s: S) -> Result<S::Ok, S::Error> {
        // The deep-document case: decline rather than overflow the Rust stack.
        if self.depth > MAX_DEPTH {
            return Err(serde::ser::Error::custom(
                "nesting deeper than the native walk will go",
            ));
        }
        let t = self.term;
        // A binary must be claimed before the atom check.
        //
        // It must also be VALIDATED, not coerced: `from_utf8_lossy` would substitute
        // U+FFFD for a bad byte and emit a document quietly different from the value —
        // the worst outcome, because the caller gets a plausible string back. bl refuses
        // a non-UTF-8 string and names its RFC 6901 path, so decline here and let bl
        // produce that message.
        if let Ok(b) = t.decode::<Binary>() {
            return match std::str::from_utf8(b.as_slice()) {
                Ok(valid) => s.serialize_str(valid),
                Err(_) => Err(serde::ser::Error::custom("string is not valid UTF-8")),
            };
        }
        if let Ok(name) = t.atom_to_string() {
            return match name.as_str() {
                "nil" => s.serialize_unit(),
                "true" => s.serialize_bool(true),
                "false" => s.serialize_bool(false),
                // a bl keyword and a bl symbol both cross as their name
                _ => s.serialize_str(&name),
            };
        }
        if let Ok(i) = t.decode::<i64>() {
            return s.serialize_i64(i);
        }
        if let Ok(u) = t.decode::<u64>() {
            return s.serialize_u64(u);
        }
        if let Ok(f) = t.decode::<f64>() {
            if !f.is_finite() {
                return Err(serde::ser::Error::custom("non-finite float"));
            }
            return s.serialize_f64(f);
        }
        if let Ok(items) = t.decode::<Vec<Term>>() {
            let seq = s.serialize_seq(Some(items.len()))?;
            return write_seq::<S>(seq, *self, items);
        }
        if t.decode::<HashMap<Term, Term>>().is_ok() {
            // a bl struct is a map, so a Vector arrives here too
            if let Some(name) = self.struct_name() {
                if name == "Elixir.BeamLisp.Vector" {
                    let items = t
                        .map_get(self.items_key)
                        .map_err(|_| serde::ser::Error::custom("Vector without items"))?;
                    // `items` is a TUPLE, and rustler's `Vec<T>` decoder reads only LISTS
                    // (`ListIterator`) — so a plain decode::<Vec<Term>> fails on EVERY
                    // Vector and surfaces as a bare ArgumentError with no hint why.
                    let items = get_tuple(items).map_err(|_| {
                        serde::ser::Error::custom("Vector items is not a tuple")
                    })?;
                    let seq = s.serialize_seq(Some(items.len()))?;
                    return write_seq::<S>(seq, *self, items);
                }
                // Set, record, or a foreign struct: the escape-to-bl case. It must be
                // LOUD. An integer beyond u64 also lands here — Erlang integers are
                // arbitrary precision and JSON numbers are not, and a NIF has no way to
                // stringify a bignum, so bl must handle it.
                return Err(serde::ser::Error::custom(format!(
                    "bl struct {name} has no native mapping"
                )));
            }
            return write_map::<S>(s, *self, t);
        }
        Err(serde::ser::Error::custom(
            "term has no JSON representation in the native walk",
        ))
    }
}

fn write_seq<'a, S: SerTrait>(
    mut seq: S::SerializeSeq,
    seed: TermSer<'a>,
    items: Vec<Term<'a>>,
) -> Result<S::Ok, S::Error> {
    for item in items {
        seq.serialize_element(&TermSer {
            term: item,
            depth: seed.depth + 1,
            ..seed
        })?;
    }
    seq.end()
}

/// Object elements, SORTED by the ENCODED key — bl.json's byte contract — and REFUSED
/// if two keys encode to the same text.
///
/// Sorting by the RAW key text would be wrong: bl sorts by the encoded text, and the two
/// orders disagree as soon as a key needs escaping (a `"` sorts differently once it
/// becomes `\"`). The encoded form is computed once per key and kept beside the raw one,
/// so sorting costs no escape work and the bytes still come from `serialize_entry` on the
/// raw key.
///
/// The collision check is why this cannot be left to serde: `{:a 1, "a" 2}` has two
/// distinct keys that both encode to `"a"`, and emitting both writes a duplicate key — a
/// document no reader can be right about. bl refuses it, so declining here lets bl
/// produce that message, in bl, where the message belongs.
fn write_map<'a, S: SerTrait>(
    s: S,
    seed: TermSer<'a>,
    t: Term<'a>,
) -> Result<S::Ok, S::Error> {
    let entries = t
        .decode::<HashMap<Term, Term>>()
        .map_err(|_| serde::ser::Error::custom("map decode"))?;
    let mut pairs: Vec<(String, String, Term<'a>)> = Vec::with_capacity(entries.len());
    for (k, v) in entries {
        let key = as_key(k).map_err(|e| serde::ser::Error::custom(format!("{e:?}")))?;
        let encoded = match serde_json::to_string(&key) {
            Ok(e) => e,
            Err(_) => key.clone(),
        };
        pairs.push((key, encoded, v));
    }
    pairs.sort_by(|a, b| a.1.cmp(&b.1));
    for w in pairs.windows(2) {
        if w[0].1 == w[1].1 {
            return Err(serde::ser::Error::custom(
                "two keys that both encode to the same text",
            ));
        }
    }
    let mut map = s.serialize_map(Some(pairs.len()))?;
    for (k, _encoded, v) in pairs {
        map.serialize_entry(
            &k,
            &TermSer {
                term: v,
                depth: seed.depth + 1,
                ..seed
            },
        )?;
    }
    map.end()
}

/// A term as JSON text. Atoms for the module keys are resolved ONCE per call, not per
/// value: an atom lookup at every node would cost ~10% of the total on a payload full
/// of Vectors.
#[rustler::nif(schedule = "DirtyCpu")]
fn json_encode<'a>(env: Env<'a>, term: Term<'a>) -> NifResult<Binary<'a>> {
    let seed = TermSer {
        term,
        struct_key: Atom::from_str(env, "__struct__")?,
        vector_mod: Atom::from_str(env, "Elixir.BeamLisp.Vector")?,
        items_key: Atom::from_str(env, "items")?,
        depth: 0,
    };
    let mut out: Vec<u8> = Vec::with_capacity(4096);
    let mut serializer = serde_json::Serializer::new(&mut out);
    seed.serialize(&mut serializer).map_err(|e| err(format!("{e}")))?;
    let mut owned = OwnedBinary::new(out.len()).ok_or_else(|| err("alloc"))?;
    owned.as_mut_slice().copy_from_slice(&out);
    Ok(Binary::from_owned(owned, env))
}

// ══ DECODE ══════════════════════════════════════════════════════════════════
//
// A `DeserializeSeed` that builds Erlang terms DURING the parse. The seed — not
// `Deserialize` — is what carries the `Env` down the recursion, and `Env` is `Copy`, so
// threading it costs nothing. Parsing into a `Value` first and walking it afterwards
// costs MORE than a whole hand-written Elixir parse (0.465 ms against Jason's 0.345).

use serde::de::{self, DeserializeSeed, MapAccess, SeqAccess, Visitor};
use std::fmt;

/// `rustler::Error` implements Debug but not Display, so it cannot go straight into a
/// serde error; its Debug form is the message.
fn as_de<E: de::Error>(e: rustler::Error) -> E {
    E::custom(format!("{e:?}"))
}

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
        // an Erlang integer is arbitrary precision, so a u64 above i64::MAX still
        // crosses as an exact integer rather than becoming a float.
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

/// A JSON document as bl values: objects are plain maps (a bl map IS an Erlang map),
/// arrays are VECTORS, `null` is nil.
///
/// One pass, no intermediate, and `end()` so trailing bytes are another document rather
/// than part of this one. A malformed document is refused with serde's position
/// ("key must be a string at line 1 column 2").
#[rustler::nif(schedule = "DirtyCpu")]
fn json_decode<'a>(env: Env<'a>, data: Binary<'a>) -> NifResult<Term<'a>> {
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

// ── the rustler contract ────────────────────────────────────────────────────
//
// This string must equal `vm.native/host-module` for the declaring ns — here
// `bl.json-native` → `Elixir.BeamLisp.Native.Bl.JsonNative`. Get it wrong and
// `load_nif` binds NOTHING while every stub stays in place, so every call raises
// `:nif_not_loaded` and the .so looks absent while being right there.
rustler::init!("Elixir.BeamLisp.Native.Bl.JsonNative");
