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

  return {
    contract,
    digest: contract.digest,
    ops: Object.keys(contract.intents).sort(),
    decodeSnapshot: json => decode(contract.snapshot, json, '$board'),
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

// JSON produced by `encode` for a known-good server frame, back to BL for the
// client actor: the snapshot is decoded BY CONTRACT; the envelope fields are
// scalars the client re-validates.
export function frameToBL(codec, frame) {
  const board = codec.decodeSnapshot(frame.board);
  const pairs = [[H.kw('revision'), frame.revision], [H.kw('board'), board]];
  if (Number.isSafeInteger(frame.request)) pairs.push([H.kw('request'), frame.request]);
  if (frame.ok !== undefined) pairs.push([H.kw('ok'), frame.ok === true]);
  if (frame.duplicate === true) pairs.push([H.kw('duplicate'), true]);
  if (typeof frame.reason === 'string' && /^[a-z][a-z0-9?-]{0,47}$/.test(frame.reason))
    pairs.push([H.kw('reason'), H.kw(frame.reason)]);
  if (typeof frame.op === 'string' && Object.prototype.hasOwnProperty.call(codec.contract.intents, frame.op))
    pairs.push([H.kw('op'), H.kw(frame.op)]);
  if (typeof frame.digest === 'string') pairs.push([H.kw('digest'), frame.digest]);
  return H.bmap(pairs);
}
