//! keycodec — the order-preserving KEY encoding, in Rust.
//!
//! This mirrors `priv/datom/codec.bl`'s `encode-value` BYTE-FOR-BYTE for the
//! lanes a datom key actually uses in bulk (int, string, keyword, bool). The bl
//! codec is the oracle: `keycodec_encode/1` is tested to produce identical bytes,
//! because a key that sorts differently is a silently corrupt index.
//!
//! Why in Rust: key construction is the dominant transact cost — measured ~522ms
//! for 800 datoms' keys (superlinear), against 25ms for the value encoding it
//! wraps, because each key allocates through interpreted bl byte-work. Every
//! index write (2-4 per datom) pays it. Moving it native removes that tax.
//!
//! SCOPE: the four bulk lanes. A value outside them (a collection, a pid, a
//! bignum past 2^53, a tuple) returns `None`, and the caller falls back to the
//! bl codec for that datom — correctness never depends on this covering
//! everything, only on it being byte-identical where it DOES answer.

// ── key tags (codec.bl) ──────────────────────────────────────────────
const TAG_FALSE: u8 = 32; // 0x20
const TAG_TRUE: u8 = 33; // 0x21
const TAG_NUM: u8 = 48; // 0x30
const TAG_STR: u8 = 64; // 0x40
const TAG_KEYWORD: u8 = 80; // 0x50

// 2^53: the largest integer a float represents exactly. Within ±this, an int
// encodes as the float it equals (codec.bl unifies numbers under one tag).
const MAX_EXACT_INT: i64 = 9_007_199_254_740_992;

/// The order-preserving 8 bytes of an f64 (codec.bl `encode-float`): IEEE bits,
/// big-endian, with the high bit set for positives and every bit inverted for
/// negatives — so the byte order matches numeric order across the whole line.
fn encode_float(f: f64) -> [u8; 8] {
    let bits = f.to_bits();
    let ordered = if f >= 0.0 {
        bits | 0x8000_0000_0000_0000
    } else {
        bits ^ 0xFFFF_FFFF_FFFF_FFFF
    };
    ordered.to_be_bytes()
}

/// Escape every 0x00 to 0x00 0xFF (codec.bl `escape-nul`): a NUL inside a
/// variable-length payload must not forge the 0x00 component terminator, and
/// 0xFF sorts above every real continuation byte so order is preserved.
fn escape_nul(bytes: &[u8], out: &mut Vec<u8>) {
    for &b in bytes {
        out.push(b);
        if b == 0 {
            out.push(0xFF);
        }
    }
}

/// A value the fan-out hands us, already classified on the bl side (so this
/// module needs no BEAM term inspection). One variant per bulk lane.
pub enum KeyVal<'a> {
    Int(i64),
    Str(&'a [u8]),     // raw UTF-8
    Keyword(&'a [u8]), // raw UTF-8 name
    Bool(bool),
}

/// Append one value's key bytes to `out`, in place. Returns false (and leaves
/// `out` in an unspecified state the caller discards) when the value is out of
/// lane. The in-place form is for the BATCH path, which builds one key across
/// several components without an allocation per component.
pub fn encode_into(v: &KeyVal, out: &mut Vec<u8>) -> bool {
    match v {
        KeyVal::Bool(false) => out.push(TAG_FALSE),
        KeyVal::Bool(true) => out.push(TAG_TRUE),
        KeyVal::Int(n) => {
            if *n <= MAX_EXACT_INT && *n >= -MAX_EXACT_INT {
                out.push(TAG_NUM);
                out.extend_from_slice(&encode_float(*n as f64));
                out.push(1);
            } else {
                return false;
            }
        }
        KeyVal::Str(bytes) => {
            out.push(TAG_STR);
            escape_nul(bytes, out);
            out.push(0);
        }
        KeyVal::Keyword(bytes) => {
            out.push(TAG_KEYWORD);
            escape_nul(bytes, out);
            out.push(0);
        }
    }
    true
}

/// Encode one value to its order-preserving key bytes, byte-identical to
/// codec.bl. Returns None only for an Int past 2^53 (the bignum tie-break lane),
/// which the caller routes to the bl codec.
pub fn encode(v: &KeyVal) -> Option<Vec<u8>> {
    match v {
        KeyVal::Bool(false) => Some(vec![TAG_FALSE]),
        KeyVal::Bool(true) => Some(vec![TAG_TRUE]),

        KeyVal::Int(n) => {
            if *n <= MAX_EXACT_INT && *n >= -MAX_EXACT_INT {
                // [TAG_NUM] + encode_float(n as f64) + [1]  (the exact-float marker)
                let mut out = Vec::with_capacity(10);
                out.push(TAG_NUM);
                out.extend_from_slice(&encode_float(*n as f64));
                out.push(1);
                Some(out)
            } else {
                // past 2^53: the bignum tie-break lane — defer to bl codec.
                None
            }
        }

        KeyVal::Str(bytes) => {
            let mut out = Vec::with_capacity(bytes.len() + 2);
            out.push(TAG_STR);
            escape_nul(bytes, &mut out);
            out.push(0);
            Some(out)
        }

        KeyVal::Keyword(bytes) => {
            let mut out = Vec::with_capacity(bytes.len() + 2);
            out.push(TAG_KEYWORD);
            escape_nul(bytes, &mut out);
            out.push(0);
            Some(out)
        }
    }
}
