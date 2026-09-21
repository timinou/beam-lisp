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

/// A BEAM binary in ONE call: `enif_make_new_binary` returns the term AND a pointer to its
/// payload, so the bytes are written straight in.
///
/// The safe path this replaces (`Encoder for str`) allocates an `OwnedBinary`, copies into
/// it, then releases and wraps it — three crossings of the same boundary for one string, and
/// strings are the most numerous value in any document. Measured, they cost ~231 ns per value
/// where BEAM's own builder spends ~23, and the boundary is 92% of a decode (0.81 of 0.88 ms
/// on 24 KB). rustler's own wrapper module takes exactly this shortcut; this is that idiom,
/// named, so the reason survives.
///
/// Unsafe by necessity: the returned pointer is valid only until the next allocation, so it
/// must be filled immediately — which is what happens here and nothing else.
fn make_binary<'a>(env: Env<'a>, bytes: &[u8]) -> NifResult<Term<'a>> {
    let mut term = std::mem::MaybeUninit::uninit();
    let buf = unsafe {
        rustler::sys::enif_make_new_binary(env.as_c_arg(), bytes.len(), term.as_mut_ptr())
    };
    if buf.is_null() {
        return Err(err("binary allocation failed"));
    }
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf, bytes.len()) };
    // `Term::new` is unsafe too: the caller asserts the term belongs to `env`.
    Ok(unsafe { Term::new(env, term.assume_init()) })
}

/// A bl Vector: an Erlang map with a `__struct__` key whose `items` is a TUPLE.
///
/// This is the one cross-language shape duplicated from `lib/beam_lisp/vector.ex`.
/// It is a contract, so it is written once, here, and named.
fn make_vector<'a>(
    env: Env<'a>,
    items: Vec<Term<'a>>,
    struct_k: Atom,
    items_k: Atom,
    vec_mod: Atom,
) -> NifResult<Term<'a>> {
    let tuple = make_tuple(env, &items);
    let keys = [struct_k.to_term(env), items_k.to_term(env)];
    let vals = [vec_mod.to_term(env), tuple];
    // ONE call for the whole struct, instead of two `map_put`s that each copy the map.
    Term::map_from_term_arrays(env, &keys, &vals)
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
//
// It is TOTAL: the answer is always `{:ok, value}` or `{:error, message}`, never an
// exception and never a silent substitute. That matters because a decoded document can be
// ANY beam-lisp value, a string included — so "did I get a string back?" cannot be the
// success test the way it is for the encoder. And a NIF failure does not reliably arrive
// as a raised exception (observed), so the outcome has to be in the value.
//
// Two things it REFUSES to guess at, both handed back to `bl.json`:
//   · nesting past serde_json's own 128-level limit — `bl.json` decodes any depth, and its
//     suite encodes 2000 levels on purpose;
//   · `:existing-atom` meeting a key that is not interned — `bl.json` owns the message for
//     that, and it is a refusal, not a fallback to a string.

use serde::de::{self, DeserializeSeed, MapAccess, SeqAccess, Visitor};
use std::fmt;

/// How an object key becomes a beam-lisp key. `:string` is the default because it is the
/// only TOTAL one: `:keyword` interns an atom per key, and the atom table is a bounded,
/// never-collected resource, so a document from a peer is a way to exhaust it.
#[derive(Clone, Copy)]
enum KeyMode {
    String,
    Keyword,
    ExistingAtom,
}

/// `rustler::Error` implements Debug but not Display, so it cannot go straight into a
/// serde error; its Debug form is the message.
fn as_de<E: de::Error>(e: rustler::Error) -> E {
    E::custom(format!("{e:?}"))
}

#[derive(Clone, Copy)]
struct TermSeed<'a> {
    env: Env<'a>,
    mode: KeyMode,
    // Resolved ONCE per call, not once per Vector. A Vector is a map with a struct tag and
    // an items tuple, so building one costs three `Atom::from_str` lookups — and a document
    // of 500 arrays paid 1500 lookups for three atoms that never change. Measured: 446 ns
    // per Vector, which made arrays the most expensive value type in the whole decoder and
    // left `make_vector` as the biggest single cost after the boundary itself.
    struct_k: Atom,
    items_k: Atom,
    vec_mod: Atom,
}

impl<'de, 'a> DeserializeSeed<'de> for TermSeed<'a> {
    type Value = Term<'a>;

    fn deserialize<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        deserializer.deserialize_any(TermVisitor {
            env: self.env,
            mode: self.mode,
            struct_k: self.struct_k,
            items_k: self.items_k,
            vec_mod: self.vec_mod,
        })
    }
}

struct TermVisitor<'a> {
    env: Env<'a>,
    mode: KeyMode,
    struct_k: Atom,
    items_k: Atom,
    vec_mod: Atom,
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

    /// One BEAM allocation, written in place — see `make_binary` for why this is not
    /// `Encoder::encode`.
    fn visit_str<E: de::Error>(self, s: &str) -> Result<Term<'a>, E> {
        make_binary(self.env, s.as_bytes()).map_err(as_de)
    }

    fn visit_unit<E: de::Error>(self) -> Result<Term<'a>, E> {
        atom(self.env, "nil")
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Term<'a>, A::Error> {
        let seed = TermSeed {
            env: self.env,
            mode: self.mode,
            struct_k: self.struct_k,
            items_k: self.items_k,
            vec_mod: self.vec_mod,
        };
        let mut items = Vec::with_capacity(seq.size_hint().unwrap_or(8));
        while let Some(item) = seq.next_element_seed(seed)? {
            items.push(item);
        }
        // arrays become VECTORS: bl's documented mapping, so a round trip holds
        make_vector(self.env, items, self.struct_k, self.items_k, self.vec_mod).map_err(as_de)
    }

    /// Objects AND numbers arrive here.
    ///
    /// With `arbitrary_precision`, serde_json presents a number as a one-entry map under
    /// `$serde_json::private::Number` holding the EXACT text — which is the only way to
    /// tell `123456789012345678901234567890` from `1.2345678901234568e29`. Without it,
    /// serde_json hands that integer to `visit_f64` and the value silently becomes a
    /// float: the suite caught exactly that (`integers-are-exact`), and a decoder that
    /// quietly changes a number is worse than a slow one.
    ///
    /// A rustler NIF CANNOT build an Erlang integer wider than u64 (`enif_make_int64`),
    /// so an integer whose text does not fit must DECLINE — which sends the document to
    /// `bl.json`, whose own decoder is exact. Passing it through as f64 would be the
    /// silent corruption this whole arrangement exists to avoid.
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Term<'a>, A::Error> {
        // Pairs are COLLECTED and the map built in ONE call rather than inserted one at a
        // time. `map_put` is an `enif_make_map_put`, which COPIES the map on every insert —
        // so a 500-key object is quadratic in the number of keys, which is exactly why the
        // flat 500-key decode measured 0.03 ms parsing against 0.21 with terms built.
        // bl's duplicate-key rule (LAST wins) is preserved: a map built from arrays keeps
        // the last value for a repeated key, and `bl.json`'s suite pins that.
        let hint = map.size_hint().unwrap_or(8);
        let mut keys: Vec<Term<'a>> = Vec::with_capacity(hint);
        let mut values: Vec<Term<'a>> = Vec::with_capacity(hint);
        loop {
            let key_text: String = match map.next_key::<String>()? {
                Some(k) => k,
                None => break,
            };
            if key_text == NUMBER_TOKEN {
                let text: String = map.next_value()?;
                return number_term(self.env, &text).map_err(as_de);
            }
            let key = key_term(self.env, self.mode, &key_text).map_err(as_de)?;
            let value = map.next_value_seed(TermSeed {
                env: self.env,
                mode: self.mode,
                struct_k: self.struct_k,
                items_k: self.items_k,
                vec_mod: self.vec_mod,
            })?;
            keys.push(key);
            values.push(value);
        }
        if keys.is_empty() {
            return Ok(map::map_new(self.env));
        }
        Term::map_from_term_arrays(self.env, &keys, &values).map_err(as_de)
    }
}

/// The marker serde_json uses to hand over a number's exact text under
/// `arbitrary_precision`.
const NUMBER_TOKEN: &str = "$serde_json::private::Number";

/// An object key as beam-lisp wants it: a string, or an atom under `:keyword` /
/// `:existing-atom`. The one place an atom is built at all.
fn key_term<'a>(env: Env<'a>, mode: KeyMode, s: &str) -> NifResult<Term<'a>> {
    Ok(match mode {
        KeyMode::String => make_binary(env, s.as_bytes())?,
        KeyMode::Keyword => Atom::from_str(env, s)?.to_term(env),
        // `existing_from_str` asks WITHOUT creating, and a miss is an error — which is the
        // decline bl.json needs, so it can say why rather than intern an atom a peer chose.
        KeyMode::ExistingAtom => Atom::existing_from_str(env, s)?.to_term(env),
    })
}

/// A JSON number, from its exact text. Integers that fit cross exactly; anything with a
/// fraction or an exponent becomes the double bl's own decoder would produce; an integer
/// too wide for a NIF DECLINES rather than rounding.
fn number_term<'a>(env: Env<'a>, text: &str) -> NifResult<Term<'a>> {
    if !text.contains(['.', 'e', 'E']) {
        if let Ok(u) = text.parse::<u64>() {
            return Ok(rustler::Encoder::encode(&u, env));
        }
        if let Ok(i) = text.parse::<i64>() {
            return Ok(rustler::Encoder::encode(&i, env));
        }
        return Err(err("integer wider than u64"));
    }
    match text.parse::<f64>() {
        Ok(f) if f.is_finite() => Ok(rustler::Encoder::encode(&f, env)),
        Ok(_) => Err(err("non-finite float")),
        Err(_) => Err(err("number is not parseable")),
    }
}

/// A JSON document as beam-lisp values: objects are plain maps (a bl map IS an Erlang
/// map), arrays are VECTORS, `null` is nil.
///
/// TOTAL: always `{:ok, value}` or `{:error, message}`. One pass, no intermediate, and
/// `end()` so trailing bytes are another document rather than part of this one.
#[rustler::nif(schedule = "DirtyCpu")]
fn json_decode<'a>(env: Env<'a>, data: Binary<'a>, keys: Atom) -> NifResult<Term<'a>> {
    // `atom_to_string` is a method on Term, not on Atom (a lesson already recorded in
    // this crate's own docs, and still mis-applied once) — so go through the term.
    let mode = match keys.to_term(env).atom_to_string()?.as_str() {
        "keyword" => KeyMode::Keyword,
        "existing-atom" => KeyMode::ExistingAtom,
        _ => KeyMode::String,
    };
    // Atom lookups happen HERE, once per call — see `TermSeed`. They sit outside the
    // closure below because that closure's error type is `String` and these return
    // `rustler::Error`.
    let struct_k = Atom::from_str(env, "__struct__")?;
    let items_k = Atom::from_str(env, "items")?;
    let vec_mod = Atom::from_str(env, "Elixir.BeamLisp.Vector")?;
    let outcome: Result<Term<'a>, String> = (|| {
        let mut deserializer = serde_json::Deserializer::from_slice(data.as_slice());
        let seed = TermSeed {
            env,
            mode,
            struct_k,
            items_k,
            vec_mod,
        };
        let term = seed
            .deserialize(&mut deserializer)
            .map_err(|e| e.to_string())?;
        deserializer.end().map_err(|e| e.to_string())?;
        Ok(term)
    })();
    // A tuple is not `encode`-able by method: the trait has to be named.
    Ok(match outcome {
        Ok(term) => rustler::Encoder::encode(&(Atom::from_str(env, "ok")?, term), env),
        Err(message) => rustler::Encoder::encode(&(Atom::from_str(env, "error")?, message), env),
    })
}

// ── the isolation instrument ─────────────────────────────────────────────────
//
// PARSE ONLY: walk the document and return how many JSON values it held, building NO
// Erlang terms at all. It exists to answer one question with a number instead of an
// argument — how much of a decode is the PARSE, and how much is carrying values across the
// Rust/BEAM boundary?
//
// Every control measurable from `bench/json.bl` (OTP, Jason, `binary_to_term`) compares a
// DIFFERENT implementation, which is how three wrong explanations for the decode gap
// survived as long as they did. This one holds the parser, the visitor machinery and the
// input constant, and varies the ONLY thing in question — so `json-count` and `json-decode`
// on the same bytes, in the same build, bracket the boundary cost exactly.
#[rustler::nif(schedule = "DirtyCpu")]
fn json_count(data: Binary) -> NifResult<u64> {
    struct S;
    impl<'de> DeserializeSeed<'de> for S {
        type Value = u64;
        fn deserialize<D: de::Deserializer<'de>>(self, d: D) -> Result<u64, D::Error> {
            d.deserialize_any(V)
        }
    }
    struct V;
    impl<'de> Visitor<'de> for V {
        type Value = u64;
        fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
            f.write_str("a JSON value")
        }
        fn visit_bool<E: de::Error>(self, _: bool) -> Result<u64, E> { Ok(1) }
        fn visit_i64<E: de::Error>(self, _: i64) -> Result<u64, E> { Ok(1) }
        fn visit_u64<E: de::Error>(self, _: u64) -> Result<u64, E> { Ok(1) }
        fn visit_f64<E: de::Error>(self, _: f64) -> Result<u64, E> { Ok(1) }
        fn visit_str<E: de::Error>(self, _: &str) -> Result<u64, E> { Ok(1) }
        fn visit_unit<E: de::Error>(self) -> Result<u64, E> { Ok(1) }
        fn visit_seq<A: SeqAccess<'de>>(self, mut s: A) -> Result<u64, A::Error> {
            let mut n = 1;
            while let Some(c) = s.next_element_seed(S)? { n += c; }
            Ok(n)
        }
        // A FLOAT arrives as a one-entry map under `arbitrary_precision`, so it counts 2
        // here and 1 in `json-decode`'s terms — measured: a `[1.5]` document counts 3
        // nodes, and 2 without the flag. In-range integers do NOT take this path
        // (`[1,2,3]` counts 4 either way); only a number whose lexeme has to be kept
        // does, which is exactly the point — it is how a wider-than-i64 integer is
        // noticed and declined instead of silently becoming an f64. Irrelevant to
        // timing; noted so the count is not mistaken for a term count.
        fn visit_map<A: MapAccess<'de>>(self, mut m: A) -> Result<u64, A::Error> {
            let mut n = 1;
            while let Some(_k) = m.next_key::<String>()? {
                n += m.next_value_seed(S)?;
            }
            Ok(n)
        }
    }
    let mut d = serde_json::Deserializer::from_slice(data.as_slice());
    let n = S.deserialize(&mut d).map_err(|e| err(format!("{e}")))?;
    d.end().map_err(|e| err(format!("{e}")))?;
    Ok(n)
}

// ── the rustler contract ────────────────────────────────────────────────────
//
// This string must equal `vm.native/host-module` for the declaring ns — here
// `bl.json-native` → `Elixir.BeamLisp.Native.Bl.JsonNative`. Get it wrong and
// `load_nif` binds NOTHING while every stub stays in place, so every call raises
// `:nif_not_loaded` and the .so looks absent while being right there.
rustler::init!("Elixir.BeamLisp.Native.Bl.JsonNative");
