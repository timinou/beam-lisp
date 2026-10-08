// One closed transport codec, parameterized by the descriptor emitted by the
// compiled BL backend from qv-wire-contract. This is shape validation, never
// authorization. The backend checks the principal/grants/version again in BL.
const OP = /^[a-z][a-z0-9-]{0,31}$/;
const DECIMAL = /^(0|[1-9][0-9]*)$/;
const CONTRACT_LINE = /^QV-BACKEND CONTRACT ([0-9]+) :([a-z][a-z0-9-]*) :([a-z][a-z0-9-]*) ([0-9]+) ([0-9]+)$/;
const keysAre = (v, keys) => v && typeof v === 'object' && !Array.isArray(v) &&
  Object.keys(v).length === keys.length && keys.every(k => Object.hasOwn(v, k));

export function parseContractLine(line) {
  const parts = CONTRACT_LINE.exec(line);
  if (!parts) return null;
  try {
    return createIntentCodec({ schema: Number(parts[1]), op: parts[2], field: parts[3],
      versionChars: Number(parts[4]), payloadChars: Number(parts[5]) }).contract;
  } catch { return null; }
}

export function createIntentCodec(raw) {
  if (!keysAre(raw, ['schema', 'op', 'field', 'versionChars', 'payloadChars']) ||
      raw.schema !== 1 || typeof raw.op !== 'string' || !OP.test(raw.op) ||
      typeof raw.field !== 'string' || !OP.test(raw.field) ||
      !Number.isInteger(raw.versionChars) || raw.versionChars < 1 || raw.versionChars > 16 ||
      !Number.isInteger(raw.payloadChars) || raw.payloadChars < 0 || raw.payloadChars > 16) {
    throw new Error('unsupported BL intent contract');
  }
  const contract = Object.freeze({ schema: raw.schema, op: raw.op, field: raw.field,
    versionChars: raw.versionChars, payloadChars: raw.payloadChars });
  const versionOK = version => typeof version === 'string' && version.length <= contract.versionChars &&
    DECIMAL.test(version) && Number.isSafeInteger(Number(version));

  // The transport admits a syntactically valid unknown operation, so the BL
  // grant check—not the codec—returns its authoritative :unknown-intent.
  function decodeRequest(request) {
    if (!keysAre(request, ['op', 'version'])) return { ok: false, reason: 'malformed-request' };
    if (typeof request.op !== 'string' || !OP.test(request.op))
      return { ok: false, reason: 'malformed-op' };
    if (!versionOK(request.version)) return { ok: false, reason: 'malformed-version' };
    return { ok: true, op: request.op, version: request.version };
  }
  function encodeRequest(op, version) {
    if (op !== contract.op || !versionOK(version)) return { ok: false, reason: 'invalid-client-intent' };
    return { ok: true, body: JSON.stringify({ op, version }) };
  }
  function decodeResponse(status, value, sentVersion) {
    if (status === 200) {
      if (!keysAre(value, ['ok', 'intent', 'version']) || value.ok !== true ||
          value.intent !== contract.op || !versionOK(sentVersion) ||
          !Number.isSafeInteger(value.version) || value.version !== Number(sentVersion) + 1) {
        return { ok: false, reason: 'inconsistent-response', fatal: true };
      }
      return { ok: true, version: String(value.version) };
    }
    if (!keysAre(value, ['ok', 'reason']) || value.ok !== false ||
        typeof value.reason !== 'string' || !OP.test(value.reason)) {
      return { ok: false, reason: 'inconsistent-response', fatal: true };
    }
    return { ok: false, reason: value.reason };
  }
  function matchesView(manifest) {
    return manifest?.verdict === 'client-view-only' && manifest?.intent?.authority === 'server' &&
      manifest.intent.op === contract.op && manifest.dynamic?.field === contract.field &&
      manifest.bounds?.fieldValue === contract.versionChars;
  }
  return Object.freeze({ contract, decodeRequest, encodeRequest, decodeResponse, matchesView, versionOK });
}
