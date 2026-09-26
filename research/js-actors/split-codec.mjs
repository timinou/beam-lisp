// split-codec.mjs — JSON ⇄ BL data, driven by a split app's generated contract.
//
// The contract (`out/<app>.contract.json`) is emitted by compiler.bl from the
// app's `split/defapp` declaration. This module reads it and does exactly two
// things at the JSON boundary, for the Node transport and the browser Worker
// alike:
//
//   decode(spec, json)  JSON value → BL value, ONLY if it has the declared
//                       shape (exact record keys, bounded text, safe integer
//                       ranges, bounded lists). Keyword-valued positions are
//                       none in this grammar, so a string stays a string.
//   encode(value)       BL data → plain JSON (keywords as bare names), total
//                       over the closed data the BL shells emit.
//
// SHAPE, NOT AUTHORITY. A decoded value is only well-formed; the BL server
// re-checks it with split-wire.bl and decides. The codec's job is to refuse
// garbage early and to make the JS side unable to invent a shape the contract
// does not name.

import * as H from './host.mjs';

// Lists and records nest at most this deep (split-wire.bl `wire-max-depth`):
// a recursive wire type admits trees of any depth, the wire does not.
export const MAX_DEPTH = 24;

export const PROPOSAL_KEYS = ['args', 'digest', 'nonce', 'op', 'request', 'revision'];

export function createCodec(contract) {
  if (!contract || contract.schema !== 1 || typeof contract.digest !== 'string' ||
      !/^[0-9a-f]{64}$/.test(contract.digest) || typeof contract.wire !== 'object' ||
      typeof contract.intents !== 'object' || typeof contract.snapshot !== 'string')
    throw new Error('split-codec: not a schema-1 split contract');
  const wire = contract.wire;

  function resolve(spec) {
    if (spec === 'bool') return 'bool';
    if (spec === 'exact') return 'exact';
    if (typeof spec === 'string') {
      if (!Object.prototype.hasOwnProperty.call(wire, spec)) throw new Error('unknown wire type ' + spec);
      return wire[spec];
    }
    return spec;
  }

  function decode(spec, v, path = '$', depth = 0) {
    const t = resolve(spec);
    const fail = why => { const e = new Error(path + ': ' + why); e.path = path; throw e; };
    if (Array.isArray(t) && (t[0] === 'list' || t[0] === 'record') && depth >= MAX_DEPTH)
      fail(`nested deeper than ${MAX_DEPTH}`);
    if (t === 'bool') return typeof v === 'boolean' ? v : fail('expected a boolean');
    if (t === 'exact') {
      // an integer of any size: a safe one travels as a JSON number, a larger
      // one as its decimal digits (encode() does exactly this), so nothing is
      // ever rounded; the BL side gets a safe Number or a BigInt
      if (Number.isSafeInteger(v)) return v;
      if (typeof v !== 'string' || !/^-?[1-9][0-9]{15,99}$/.test(v)) fail('expected an exact integer (a safe number or its decimal digits)');
      const b = BigInt(v);
      return b >= BigInt(Number.MIN_SAFE_INTEGER) && b <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(b) : b;
    }
    if (!Array.isArray(t)) fail('malformed contract type');
    const [tag, a, b] = t;
    if (tag === 'text') {
      if (typeof v !== 'string') fail('expected text');
      if (v.length < a || v.length > b) fail(`text length ${v.length} outside ${a}..${b}`);
      return v;
    }
    if (tag === 'one-of') {
      // a keyword from a closed list: JSON carries its name, BL gets the keyword
      if (typeof v !== 'string' || !t.slice(1).includes(v)) fail(`expected one of ${t.slice(1).join(', ')}`);
      return H.kw(v);
    }
    if (tag === 'int') {
      if (!Number.isSafeInteger(v)) fail('expected an exact integer');
      if (v < a || v > b) fail(`integer ${v} outside ${a}..${b}`);
      return v;
    }
    if (tag === 'list') {
      if (!Array.isArray(v)) fail('expected a list');
      if (v.length > a) fail(`list of ${v.length} exceeds ${a}`);
      return H.vec(v.map((x, i) => decode(b, x, `${path}[${i}]`, depth + 1)));
    }
    if (tag === 'record') {
      if (v === null || typeof v !== 'object' || Array.isArray(v)) fail('expected a record');
      const want = Object.keys(a).sort();
      const got = Object.keys(v).sort();
      if (want.length !== got.length || want.some((k, i) => k !== got[i]))
        fail(`record keys ${JSON.stringify(got)} are not exactly ${JSON.stringify(want)}`);
      return H.bmap(want.map(k => [H.kw(k), decode(a[k], v[k], `${path}.${k}`, depth + 1)]));
    }
    return fail('unknown wire tag ' + tag);
  }

  function intentParams(op) {
    return Object.prototype.hasOwnProperty.call(contract.intents, op)
      ? ['record', contract.intents[op].params] : null;
  }

  const hasOp = op => Object.prototype.hasOwnProperty.call(contract.intents, op);

  return {
    contract,
    digest: contract.digest,
    // An app's declaration decides whether identity and history exist at all:
    // a contract built before those keys is an app with neither.
    people: contract.people === true,
    history: contract.history === true,
    hasOp,
    ops: Object.keys(contract.intents).sort(),
    decodeSnapshot: json => decode(contract.snapshot, json, '$board'),
    // Args for one declared op (or the built-in undo/redo), decoded by the
    // same wire type a browser proposal is. Used by the log replay path.
    decodeIntentArgs(op, json) {
      const params = intentParams(op);
      if (params === null) throw new Error('unknown intent ' + op);
      return decode(params, json, '$args');
    },
    // A browser proposal: exact keys, a declared op, args of its declared type.
    decodeProposal(json) {
      if (json === null || typeof json !== 'object' || Array.isArray(json))
        return { ok: false, reason: 'malformed-proposal' };
      const keys = Object.keys(json).sort();
      if (keys.length !== PROPOSAL_KEYS.length || keys.some((k, i) => k !== PROPOSAL_KEYS[i]))
        return { ok: false, reason: 'malformed-proposal' };
      const { request, revision, digest, nonce, op, args } = json;
      if (!Number.isSafeInteger(request) || request < 1 || !Number.isSafeInteger(revision) || revision < 0 ||
          typeof digest !== 'string' || typeof op !== 'string' ||
          typeof nonce !== 'string' || !/^[a-z0-9]{8,32}:[0-9]{1,9}$/.test(nonce))
        return { ok: false, reason: 'malformed-proposal' };
      if (digest !== contract.digest) return { ok: false, reason: 'client-outdated' };
      const params = intentParams(op);
      if (params === null) return { ok: false, reason: 'unknown-intent' };
      try {
        const bl = decode(params, args, '$args');
        return { ok: true, value: H.bmap([[H.kw('request'), request], [H.kw('revision'), revision],
          [H.kw('digest'), digest], [H.kw('nonce'), nonce], [H.kw('op'), H.kw(op)], [H.kw('args'), bl]]) };
      } catch (error) {
        return { ok: false, reason: 'malformed-args', detail: error.message };
      }
    },
  };
}

// BL closed data → JSON. Keywords become their bare names; a map needs
// keyword or string keys. Anything else (a function, a pid) is refused.
export function encode(x) {
  if (x === null || x === undefined) return null;
  if (typeof x === 'boolean' || typeof x === 'string') return x;
  if (typeof x === 'number') {
    if (!Number.isSafeInteger(x)) throw new Error('split-codec: inexact number on the wire');
    return x;
  }
  // a big exact integer: its digits, never a rounded JSON number
  if (typeof x === 'bigint') return x.toString();
  if (H.isKw(x)) return H.kwName(x);
  if (H.isVec(x)) return H.vecItems(x).map(encode);
  if (H.isCons(x) || H.isEnil(x)) return H.listToArray(x).map(encode);
  if (H.isBMap(x)) {
    const out = {};
    for (const k of H.listToArray(H.mapKeys(x))) {
      const name = H.isKw(k) ? H.kwName(k) : typeof k === 'string' ? k : null;
      if (name === null) throw new Error('split-codec: map key is not a keyword');
      out[name] = encode(H.mapGet(x, k));
    }
    return out;
  }
  throw new Error('split-codec: value is not closed data: ' + H.describe(x));
}

// ── server frames → BL, for the client actor ─────────────────────────────────
//
// The activity feed, the undo/redo summary and the roster are the app's own
// words, but they still cross a wire: every field is bounded and every keyword
// position must name a known word. A malformed ENTRY is dropped rather than
// failing the whole frame; a malformed LIST is dropped whole.

export const MAX_FRAME_LIST = 64;
export const MAX_FRAME_STR = 64;
export const MAX_SAYS = 200;

const shortStr = (v, n = MAX_FRAME_STR) => typeof v === 'string' && v.length <= n;

/** One activity entry → BL, or null when its shape is not allowed. `op` must
 *  be a declared intent (or undo/redo) so the client can never be handed a
 *  word the contract does not name. */
export function entryToBL(codec, e) {
  if (e === null || typeof e !== 'object' || Array.isArray(e)) return null;
  if (!Number.isSafeInteger(e.revision) || e.revision < 1) return null;
  if (!(e.actor === null || shortStr(e.actor))) return null;
  if (!shortStr(e.name) || !shortStr(e.op) || !shortStr(e.says, MAX_SAYS)) return null;
  if (typeof codec.hasOp !== 'function' || !codec.hasOp(e.op)) return null;
  return H.bmap([[H.kw('revision'), e.revision], [H.kw('actor'), e.actor],
    [H.kw('name'), e.name], [H.kw('op'), H.kw(e.op)], [H.kw('says'), e.says]]);
}

/** `recent`: a bounded list of entries. A non-list answers null (the caller
 *  then leaves the frame's `:recent` alone). */
export function recentToBL(codec, xs) {
  if (!Array.isArray(xs) || xs.length > MAX_FRAME_LIST) return null;
  const out = [];
  for (const e of xs) { const b = entryToBL(codec, e); if (b !== null) out.push(b); }
  return H.vec(out);
}

/** `history`: `{:undo entry|nil :redo entry|nil}`, always both keys. */
export function historyToBL(codec, h) {
  const pick = k => (h !== null && typeof h === 'object' && !Array.isArray(h) && h[k] != null
    ? entryToBL(codec, h[k]) : null);
  return H.bmap([[H.kw('undo'), pick('undo')], [H.kw('redo'), pick('redo')]]);
}

/** A public roster entry `{id, name, role}` → BL, with `role` a keyword. */
export function personToBL(p) {
  if (p === null || typeof p !== 'object' || Array.isArray(p)) return null;
  if (!shortStr(p.id) || !shortStr(p.name)) return null;
  if (!(p.role === null || p.role === undefined || (shortStr(p.role, 32) && /^[a-z][a-z0-9-]*$/.test(p.role)))) return null;
  return H.bmap([[H.kw('id'), p.id], [H.kw('name'), p.name],
    [H.kw('role'), p.role === null || p.role === undefined ? null : H.kw(p.role)]]);
}

/** A bounded roster list → BL, dropping any malformed entry. */
export function peopleToBL(list) {
  if (!Array.isArray(list) || list.length > MAX_FRAME_LIST) return null;
  const out = [];
  for (const p of list) { const b = personToBL(p); if (b !== null) out.push(b); }
  return H.vec(out);
}

/** A presence frame `{people: [...]}` → BL `{:people [...]}`, the value the
 *  client actor receives as `[:browser :presence p]`. */
export function presenceToBL(frame) {
  const list = frame !== null && typeof frame === 'object' && !Array.isArray(frame)
    ? peopleToBL(frame.people) : null;
  return H.bmap([[H.kw('people'), list === null ? H.vec([]) : list]]);
}

// JSON produced by `encode` for a known-good server frame, back to BL for the
// client actor: the snapshot is decoded BY CONTRACT; the envelope fields are
// scalars the client re-validates, and the identity/history fields are bounded
// and dropped when they do not fit.
export function frameToBL(codec, frame) {
  const board = codec.decodeSnapshot(frame.board);
  const pairs = [[H.kw('revision'), frame.revision], [H.kw('board'), board]];
  if (Number.isSafeInteger(frame.request)) pairs.push([H.kw('request'), frame.request]);
  if (frame.ok !== undefined) pairs.push([H.kw('ok'), frame.ok === true]);
  if (frame.duplicate === true) pairs.push([H.kw('duplicate'), true]);
  if (typeof frame.reason === 'string' && /^[a-z][a-z0-9?-]{0,47}$/.test(frame.reason))
    pairs.push([H.kw('reason'), H.kw(frame.reason)]);
  if (typeof frame.op === 'string' && codec.hasOp(frame.op))
    pairs.push([H.kw('op'), H.kw(frame.op)]);
  if (typeof frame.digest === 'string') pairs.push([H.kw('digest'), frame.digest]);
  if ('recent' in frame) { const r = recentToBL(codec, frame.recent); if (r !== null) pairs.push([H.kw('recent'), r]); }
  if ('history' in frame) pairs.push([H.kw('history'), historyToBL(codec, frame.history)]);
  if ('people' in frame) { const p = peopleToBL(frame.people); if (p !== null) pairs.push([H.kw('people'), p]); }
  if ('me' in frame) pairs.push([H.kw('me'), frame.me === null ? null : personToBL(frame.me)]);
  return H.bmap(pairs);
}

/** The SSE hello frame → BL for the client actor: the same snapshot/envelope
 *  decode as any other frame, plus the read-only viewer's identity and the
 *  app's roster/feed/history when the transport supplied them. */
export function helloToBL(codec, frame, tab) {
  const pairs = [[H.kw('digest'), String(frame.digest)], [H.kw('tab'), tab],
    [H.kw('revision'), frame.revision], [H.kw('board'), codec.decodeSnapshot(frame.board)]];
  if ('people' in frame) pairs.push([H.kw('people'), frame.people === null ? null : peopleToBL(frame.people)]);
  if ('me' in frame) pairs.push([H.kw('me'), frame.me === null ? null : personToBL(frame.me)]);
  if ('recent' in frame) { const r = recentToBL(codec, frame.recent); if (r !== null) pairs.push([H.kw('recent'), r]); }
  if ('history' in frame) pairs.push([H.kw('history'), historyToBL(codec, frame.history)]);
  return H.bmap(pairs);
}
