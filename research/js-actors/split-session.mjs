// split-session.mjs — pure helpers for the transport's identity and history
// state: signed session cookies and the durable commit log's line grammar.
//
// No BL, no HTTP, no server: every function here is total over its documented
// inputs, so the Node transport can use it and a Node-only test can exercise
// it without an authority. The transport owns the session MAP; this module
// owns the signed cookie FORMAT and the verification of a presented cookie.
//
// The commit log is JSON Lines: one `{v, revision, at, actor, op, args, nonce}`
// per commit. A crash can leave a partial LAST line, so the parser tolerates
// exactly that one case (ignoring it, caller truncates) and fails closed on
// anything else, naming the offending line.

import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';

export const SESSION_COOKIE = 'split_sid';
export const SESSION_TTL_SECONDS = 43200;
export const MAX_USER = 64;
export const LOG_VERSION = 1;

// ── sessions and cookies ─────────────────────────────────────────────────────

/** A fresh per-process signing secret. Never persisted: a restart invalidates
 *  every outstanding cookie. */
export function newSecret() {
  return randomBytes(32);
}

/** A session id: 18 random bytes, base64url. Sits in front of the dot. */
export function newSessionId() {
  return randomBytes(18).toString('base64url');
}

/** The HMAC-SHA256 of `sid` under `secret`, base64url. */
export function sessionMac(secret, sid) {
  return createHmac('sha256', secret).update(sid).digest('base64url');
}

/** `<sid>.<mac>` — the cookie value the transport sets. */
export function sessionCookieValue(secret, sid) {
  return sid + '.' + sessionMac(secret, sid);
}

export const COOKIE_ATTRS = `HttpOnly; SameSite=Strict; Path=/; Max-Age=${SESSION_TTL_SECONDS}`;
export const COOKIE_CLEAR = 'HttpOnly; SameSite=Strict; Path=/; Max-Age=0';

export function setCookieHeader(secret, sid) {
  return `${SESSION_COOKIE}=${sessionCookieValue(secret, sid)}; ${COOKIE_ATTRS}`;
}

export function clearCookieHeader() {
  return `${SESSION_COOKIE}=; ${COOKIE_CLEAR}`;
}

/** Strict `Cookie:` parse: split on `;`, take the FIRST `name=value` whose name
 *  matches EXACTLY. A missing or non-string header answers null, and a value
 *  never contains a `;` (so no quoting games). */
export function readCookie(header, name) {
  if (typeof header !== 'string') return null;
  for (const part of header.split(';')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    if (part.slice(0, eq).trim() !== name) continue;
    return part.slice(eq + 1).trim();
  }
  return null;
}

// A base64url sid from 18 bytes is exactly 24 characters. An HMAC-SHA256 in
// base64url is exactly 43. Anything else is refused before the compare.
const SID_RE = /^[A-Za-z0-9_-]{20,64}$/;
const MAC_RE = /^[A-Za-z0-9_-]{43}$/;

/** The session id a `Cookie:` header proves, or null. A malformed pair, a
 *  wrong-length mac or a mismatch is refused; the actual mac compare is
 *  constant-time (`timingSafeEqual`) whenever both sides are the fixed HMAC
 *  length. */
export function verifySessionCookie(secret, header) {
  const raw = readCookie(header, SESSION_COOKIE);
  if (raw === null) return null;
  const dot = raw.indexOf('.');
  if (dot <= 0 || raw.indexOf('.', dot + 1) >= 0) return null;
  const sid = raw.slice(0, dot);
  const mac = raw.slice(dot + 1);
  if (!SID_RE.test(sid) || !MAC_RE.test(mac)) return null;
  const want = Buffer.from(sessionMac(secret, sid));
  const got = Buffer.from(mac);
  if (want.length !== got.length) return null;
  if (!timingSafeEqual(want, got)) return null;
  return sid;
}

// ── the durable commit log ───────────────────────────────────────────────────

/** The generic shape of a log line, independent of the contract. Returns a
 *  short reason string, or null when the line may be handed to the authority. */
export function logEntryShapeError(v) {
  if (v === null || typeof v !== 'object' || Array.isArray(v)) return 'not-an-object';
  if (v.v !== LOG_VERSION) return 'bad-version';
  if (!Number.isSafeInteger(v.revision) || v.revision < 1) return 'bad-revision';
  if (!(v.actor === null || (typeof v.actor === 'string' && v.actor.length <= MAX_USER))) return 'bad-actor';
  if (typeof v.op !== 'string' || !/^[a-z][a-z0-9?-]{0,31}$/.test(v.op)) return 'bad-op';
  if (typeof v.nonce !== 'string' || v.nonce.length < 1 || v.nonce.length > 64) return 'bad-nonce';
  if (v.args === null || typeof v.args !== 'object' || Array.isArray(v.args)) return 'bad-args';
  if (typeof v.at !== 'string' || v.at.length > 40) return 'bad-at';
  return null;
}

/** Shape plus the contract-dependent checks: the op must be declared (or
 *  undo/redo), and the revision must be the one the replay expected next. */
export function logEntryError(v, { isKnownOp, expectedRevision } = {}) {
  const shape = logEntryShapeError(v);
  if (shape !== null) return shape;
  if (expectedRevision !== undefined && v.revision !== expectedRevision) return 'revision-out-of-order';
  if (isKnownOp && !isKnownOp(v.op)) return 'unknown-op';
  return null;
}

/** Parse a JSONL log. A final segment with no trailing newline is a partial
 *  write: it is NOT parsed (`truncated: true`) and the caller truncates the
 *  file to `truncatedByteLength(text)`. Any other malformed line is an error
 *  that names its 1-indexed line. */
export function parseLogText(text) {
  const entries = [];
  const result = { entries, truncated: false, error: null };
  if (typeof text !== 'string' || text === '') return result;
  const parts = text.split('\n');
  if (text.endsWith('\n')) parts.pop();
  else { result.truncated = true; parts.pop(); }
  for (let i = 0; i < parts.length; i++) {
    const raw = parts[i];
    if (raw.trim() === '') { result.error = { line: i + 1, reason: 'blank-line' }; break; }
    let value;
    try { value = JSON.parse(raw); }
    catch { result.error = { line: i + 1, reason: 'invalid-json' }; break; }
    const why = logEntryShapeError(value);
    if (why !== null) { result.error = { line: i + 1, reason: why }; break; }
    entries.push({ line: i + 1, value });
  }
  return result;
}

/** The byte length of `text` up to and including its last newline — where a
 *  file with a partial last line is truncated to. 0 when there is none. */
export function truncatedByteLength(text) {
  const i = text.lastIndexOf('\n');
  return Buffer.byteLength(i < 0 ? '' : text.slice(0, i + 1));
}
