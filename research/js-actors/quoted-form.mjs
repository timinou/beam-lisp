// quoted-form.mjs — the CLIENT-SIDE FENCE for the ONE editable quoted-view data
// form. It READS a bounded Beam Lisp DATA literal and decides, fail-closed,
// whether that literal is exactly the fixed Loom-like view `quoted-view-core.bl`
// already evaluates.
//
// WHAT THIS IS. `fenceQuotedForm(source)` is a total reader + eligibility gate
// over a NARROW closed grammar:
//
//     value  ::= vector | map | keyword | string | integer
//     vector ::= "[" value* "]"
//     map    ::= "{" (keyword value)* "}"          ; keyword keys only, no repeats
//     keyword::= ":" [A-Za-z] [A-Za-z0-9_-]*
//     string ::= '"' (escape | non-control)* '"'   ; escapes: \" \\ \/ \n \t \r
//     integer::= "0" | [1-9][0-9]*                  ; nonnegative, safe integer
//
// Whitespace — space, tab, newline, carriage return and comma — and `;` line
// comments may appear between any two tokens. The whole source must be consumed:
// one value followed by anything but whitespace/comments is `trailing-syntax`.
//
// WHAT IT REFUSES, BY NAME. No symbol, no list `(…)`, no call, no quote `'`, no
// syntax-quote, no unquote, no deref, no metadata, no dispatch, no character
// literal, no negative/float/hex/exponent/oversized number, no repeated map key,
// and no source, depth, token, string or text past the bounds below. Every
// refusal is a positioned `{reason, line, column, path}` — never a throw.
//
// WHAT THE GATE ADDS. Reading the grammar is not enough: the fence then requires
// the EXACT view layout the strict frame decoder already accepts —
//
//     [:card {:id "…"}
//        [:heading {:level 2 :text "…"}]
//        [:field :unread]
//        [:button {:label "…" :intent [:intent :increment]}]
//        [:text "…"]]
//
// — with only those ops, only those attribute keys, heading level exactly 2, the
// field exactly `:unread`, the intent exactly `[:intent :increment]`, the four
// children in that order, and every string inside the core's per-string bound.
// The total visible text (heading + the DYNAMIC field + button label + copy) and
// the assembled frame are checked in their WORST case, so an accepted form can
// never make the core refuse at render time or overrun one frame line.
//
// THE RESULT. On success `{ok: true, form, manifest}`:
//
//   * `form` is the literal as plain JavaScript data — BL vector → `Array`,
//     BL map → `Map`, BL string → `String`, BL integer → `Number`, and BL
//     KEYWORD → a frozen `{keyword: "<name>"}` token (see `keyword`/`isKeyword`).
//     Keywords are interned, so `keyword("id") === keyword("id")` and a `Map` is
//     readable by keyword lookup. `form` is data only: it is never turned into
//     code, never `eval`ed, and never used to build a `Function`.
//
//   * `manifest` is a deterministic, self-describing eligibility verdict: it
//     states that this is a CLIENT VIEW ONLY, captures the fixed operators and
//     the DYNAMIC `unread` field, records the SERVER-AUTHORITATIVE `increment`
//     version contract, and lists explicitly what the fence does NOT claim —
//     most importantly, no general Beam Lisp auto-fencing.
//
// WHAT THIS IS NOT. It is not a sandbox, not an authorization boundary and not a
// Lisp reader. It proves one fixed data form is portable to the browser; it does
// not place arbitrary BL, does not isolate hostile code, and does not make a
// browser-supplied intent trustworthy. The only consumer is the quoted-view
// playground Worker, which converts the returned `form` to BL runtime values.

// ─────────────────────────────────────────────────────────────────────────────
// 1. The bounds
//
// Each mirrors the bound the SAME value is held to downstream, so the fence is
// at least as strict as the reader that will re-parse the frame.
// ─────────────────────────────────────────────────────────────────────────────

/** Chars of source accepted. The view is a few hundred; 4 KiB is a hard stop. */
export const MAX_SOURCE = 4096;
/** Nesting depth, root value is 0 (core `qv-max-depth` is 6). */
export const MAX_DEPTH = 8;
/** Reader tokens — containers and atoms — in one source. */
export const MAX_TOKENS = 128;
/** One string value (core `qv-max-attr-text`, frame `MAX_STRING`). */
export const MAX_ATTR_TEXT = 64;
/** Heading + field value + button label + copy (core `qv-max-text`). */
export const MAX_TOTAL_TEXT = 96;
/** The dynamic version wire (core `qv-max-version-wire`). */
export const MAX_FIELD_VALUE = 16;
/** One frame line (frame `MAX_LINE`). */
export const MAX_FRAME = 1024;
/** Manifest schema version. */
export const FENCE_VERSION = 1;

/** The ONLY ops the closed grammar knows; anything else is `unknown-op`. */
const KNOWN_OPS = ['card', 'heading', 'button', 'text', 'field'];
/** The fixed child order of the one card this fence accepts. */
const CHILD_SEQUENCE = ['heading', 'field', 'button', 'text'];
/** The ONLY field this view reads — its value is the dynamic version wire. */
const FIELD_NAME = 'unread';
/** The ONLY button intent, and it is authored on the SERVER, never here. */
const INTENT_NAME = 'increment';
/** The ONE heading level the strict frame decoder accepts. */
const HEADING_LEVEL = 2;
/** The default card id the core substitutes when `:id` is absent. */
const CARD_DEFAULT_ID = '_';

/** Every refusal reason this module can return. Exported so tests can assert the
 *  vocabulary is closed rather than discovering a typo'd string. */
export const REASONS = Object.freeze([
  // reader
  'source-not-a-string', 'oversized-source', 'empty-source',
  'unexpected-char', 'unterminated-string', 'unterminated-form', 'bad-escape',
  'bad-keyword', 'symbol', 'negative-number', 'unsupported-number',
  'non-canonical-number', 'number-out-of-range', 'list-form', 'quote-literal',
  'syntax-quote', 'unquote', 'deref-form', 'metadata-form', 'dispatch-form',
  'char-literal', 'map-key-not-keyword', 'malformed-map', 'duplicate-key',
  'trailing-syntax', 'too-deep', 'too-many-tokens', 'reader-error',
  // gate
  'wrong-layout', 'unknown-op', 'unknown-attribute', 'unknown-field',
  'unknown-intent', 'intent-shape', 'heading-level', 'attribute-not-an-integer',
  'malformed-arity', 'malformed-field', 'missing-attribute',
  'attribute-not-a-string', 'oversized-attribute', 'control-char',
  'too-much-text', 'oversized-frame', 'fence-error',
]);

// ─────────────────────────────────────────────────────────────────────────────
// 2. Keyword tokens
//
// A keyword is not a string in this representation: an explicit frozen
// `{keyword: "<name>"}` distinguishes `:unread` from `"unread"` without
// pretending a symbol is a value. Interning keeps `Map` lookup natural.
// ─────────────────────────────────────────────────────────────────────────────

const KEYWORD_CACHE = new Map();

/** The keyword token for `name`. Frozen and interned per name. */
export function keyword(name) {
  let token = KEYWORD_CACHE.get(name);
  if (token === undefined) {
    token = Object.freeze({ keyword: name });
    KEYWORD_CACHE.set(name, token);
  }
  return token;
}

/** Whether `value` is a keyword token and nothing else. */
export function isKeyword(value) {
  return (
    typeof value === 'object' && value !== null &&
    typeof value.keyword === 'string' && Object.keys(value).length === 1
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. The reader — grammar only, no meaning
// ─────────────────────────────────────────────────────────────────────────────

class FormError {
  constructor(reason, line, column, path) {
    this.reason = reason;
    this.line = line;
    this.column = column;
    this.path = path;
  }
}

const NAME_START = /[A-Za-z]/;
const NAME_REST = /[A-Za-z0-9_-]/;
const SPACE = /[ \t\n\r,]/;

class Reader {
  constructor(source) {
    this.src = source;
    this.i = 0;
    this.line = 1;
    this.column = 1;
    this.tokens = 0;
  }

  eof() { return this.i >= this.src.length; }
  peek() { return this.src[this.i]; }

  advance() {
    const ch = this.src[this.i];
    this.i += 1;
    if (ch === '\n') { this.line += 1; this.column = 1; } else { this.column += 1; }
    return ch;
  }

  fail(reason, path) {
    throw new FormError(reason, this.line, this.column, path);
  }

  failAt(reason, path, line, column) {
    throw new FormError(reason, line, column, path);
  }

  /** Skip inter-token whitespace (incl. comma, as the BL reader does) and `;`
   *  line comments. */
  skipSpace() {
    while (!this.eof()) {
      const ch = this.src[this.i];
      if (SPACE.test(ch)) { this.advance(); continue; }
      if (ch === ';') {
        while (!this.eof() && this.src[this.i] !== '\n') this.advance();
        continue;
      }
      break;
    }
  }

  countToken(path) {
    this.tokens += 1;
    if (this.tokens > MAX_TOKENS) this.fail('too-many-tokens', path);
  }

  readValue(path, depth) {
    if (depth > MAX_DEPTH) this.fail('too-deep', path);
    this.skipSpace();
    if (this.eof()) this.fail('unexpected-char', path);
    const line = this.line;
    const column = this.column;
    const ch = this.src[this.i];
    let node;
    if (ch === '[') node = this.readVector(path, depth);
    else if (ch === '{') node = this.readMap(path, depth);
    else if (ch === '"') node = this.readString(path);
    else if (ch === ':') node = this.readKeyword(path);
    else if (ch === '-' || (ch >= '0' && ch <= '9')) node = this.readNumber(path);
    else if (ch === '(') this.fail('list-form', path);
    else if (ch === "'") this.fail('quote-literal', path);
    else if (ch === '`') this.fail('syntax-quote', path);
    else if (ch === '~') this.fail('unquote', path);
    else if (ch === '@') this.fail('deref-form', path);
    else if (ch === '^') this.fail('metadata-form', path);
    else if (ch === '#') this.fail('dispatch-form', path);
    else if (ch === '\\') this.fail('char-literal', path);
    else if (ch === ')' || ch === ']' || ch === '}') this.fail('unexpected-char', path);
    else this.fail('symbol', path);
    node.line = line;
    node.column = column;
    node.path = path;
    return node;
  }

  readVector(path, depth) {
    this.countToken(path);
    this.advance(); // '['
    const items = [];
    for (;;) {
      this.skipSpace();
      if (this.eof()) this.fail('unterminated-form', path);
      if (this.src[this.i] === ']') { this.advance(); break; }
      items.push(this.readValue(`${path}[${items.length}]`, depth + 1));
    }
    return { kind: 'vec', items };
  }

  readMap(path, depth) {
    this.countToken(path);
    this.advance(); // '{'
    const entries = [];
    const seen = new Set();
    for (;;) {
      this.skipSpace();
      if (this.eof()) this.fail('unterminated-form', path);
      if (this.src[this.i] === '}') { this.advance(); break; }
      if (this.src[this.i] !== ':') this.fail('map-key-not-keyword', path);
      const keyLine = this.line;
      const keyColumn = this.column;
      const key = this.readKeyword(path);
      key.line = keyLine;
      key.column = keyColumn;
      key.path = `${path}.${key.name}`;
      if (seen.has(key.name)) this.failAt('duplicate-key', key.path, keyLine, keyColumn);
      seen.add(key.name);
      const valuePath = key.path;
      this.skipSpace();
      if (this.eof()) this.fail('unterminated-form', path);
      if (this.src[this.i] === '}') this.fail('malformed-map', valuePath);
      entries.push({ key, value: this.readValue(valuePath, depth + 1) });
    }
    return { kind: 'map', entries };
  }

  readKeyword(path) {
    this.countToken(path);
    const line = this.line;
    const column = this.column;
    this.advance(); // ':'
    if (this.eof() || !NAME_START.test(this.src[this.i])) this.failAt('bad-keyword', path, line, column);
    const start = this.i;
    this.advance();
    while (!this.eof() && NAME_REST.test(this.src[this.i])) this.advance();
    return { kind: 'keyword', name: this.src.slice(start, this.i) };
  }

  readString(path) {
    this.countToken(path);
    const line = this.line;
    const column = this.column;
    this.advance(); // opening quote
    let value = '';
    for (;;) {
      if (this.eof() || this.peek() === '\n') this.failAt('unterminated-string', path, line, column);
      const ch = this.advance();
      if (ch === '"') break;
      if (ch !== '\\') { value += ch; continue; }
      if (this.eof()) this.failAt('bad-escape', path, line, column);
      const esc = this.advance();
      if (esc === '"') value += '"';
      else if (esc === '\\') value += '\\';
      else if (esc === '/') value += '/';
      else if (esc === 'n') value += '\n';
      else if (esc === 't') value += '\t';
      else if (esc === 'r') value += '\r';
      else this.fail('bad-escape', path);
    }
    return { kind: 'string', value };
  }

  readNumber(path) {
    this.countToken(path);
    if (this.src[this.i] === '-') {
      const next = this.src[this.i + 1];
      if (next !== undefined && next >= '0' && next <= '9') this.fail('negative-number', path);
      this.fail('symbol', path);
    }
    const start = this.i;
    while (!this.eof()) {
      const ch = this.src[this.i];
      if (ch < '0' || ch > '9') break;
      this.advance();
    }
    const stop = this.src[this.i];
    if (stop !== undefined && '.eExXnNmM'.includes(stop)) this.fail('unsupported-number', path);
    const digits = this.src.slice(start, this.i);
    if (digits.length > 1 && digits[0] === '0') this.fail('non-canonical-number', path);
    const value = Number(digits);
    if (!Number.isSafeInteger(value)) this.fail('number-out-of-range', path);
    return { kind: 'int', value };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Materialisation — annotated tree → plain data
// ─────────────────────────────────────────────────────────────────────────────

function materialize(node) {
  switch (node.kind) {
    case 'vec':
      return node.items.map(materialize);
    case 'map': {
      const out = new Map();
      for (const entry of node.entries) out.set(keyword(entry.key.name), materialize(entry.value));
      return out;
    }
    case 'keyword':
      return keyword(node.name);
    case 'string':
      return node.value;
    case 'int':
      return node.value;
    default:
      throw new Error('unreachable node kind: ' + node.kind);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. The eligibility gate — the exact fixed layout
// ─────────────────────────────────────────────────────────────────────────────

class GateError {
  constructor(reason, node) {
    this.reason = reason;
    this.node = node;
  }
}

function gfail(reason, node) { throw new GateError(reason, node); }

function mapGet(mapNode, name) {
  for (const entry of mapNode.entries) if (entry.key.name === name) return entry.value;
  return undefined;
}

function checkKeys(mapNode, allowed) {
  for (const entry of mapNode.entries) {
    if (!allowed.includes(entry.key.name)) gfail('unknown-attribute', entry.key);
  }
}

/** A bounded, control-free string node. The frame decoder refuses over-long and
 *  control-character values, so the fence must too — before anything renders. */
function checkString(node) {
  if (node.kind !== 'string') gfail('attribute-not-a-string', node);
  if (node.value.length > MAX_ATTR_TEXT) gfail('oversized-attribute', node);
  for (let i = 0; i < node.value.length; i++) {
    const code = node.value.charCodeAt(i);
    if (code < 0x20 || code === 0x7f) gfail('control-char', node);
  }
  return node.value;
}

function checkHeading(node) {
  if (node.items.length !== 2) gfail('malformed-arity', node);
  const attrs = node.items[1];
  if (attrs.kind !== 'map') gfail('wrong-layout', attrs);
  checkKeys(attrs, ['level', 'text']);
  const level = mapGet(attrs, 'level');
  if (level === undefined) gfail('missing-attribute', attrs);
  if (level.kind !== 'int') gfail('attribute-not-an-integer', level);
  if (level.value !== HEADING_LEVEL) gfail('heading-level', level);
  const text = mapGet(attrs, 'text');
  if (text === undefined) gfail('missing-attribute', attrs);
  return checkString(text);
}

function checkField(node) {
  if (node.items.length !== 2) gfail('malformed-arity', node);
  const arg = node.items[1];
  if (arg.kind !== 'keyword') gfail('malformed-field', arg);
  if (arg.name !== FIELD_NAME) gfail('unknown-field', arg);
  return arg.name;
}

function checkButton(node) {
  if (node.items.length !== 2) gfail('malformed-arity', node);
  const attrs = node.items[1];
  if (attrs.kind !== 'map') gfail('wrong-layout', attrs);
  checkKeys(attrs, ['label', 'intent']);
  const labelNode = mapGet(attrs, 'label');
  if (labelNode === undefined) gfail('missing-attribute', attrs);
  const label = checkString(labelNode);
  const intentNode = mapGet(attrs, 'intent');
  if (intentNode === undefined) gfail('missing-attribute', attrs);
  if (intentNode.kind !== 'vec' || intentNode.items.length !== 2) gfail('intent-shape', intentNode);
  const head = intentNode.items[0];
  if (head.kind !== 'keyword' || head.name !== 'intent') gfail('intent-shape', head);
  const op = intentNode.items[1];
  if (op.kind !== 'keyword') gfail('intent-shape', op);
  if (op.name !== INTENT_NAME) gfail('unknown-intent', op);
  return { label, intent: op.name };
}

function checkText(node) {
  if (node.items.length !== 2) gfail('malformed-arity', node);
  return checkString(node.items[1]);
}

/** The worst-case rendered frame for the accepted form: the fixed template with
 *  the longest dynamic field value the version wire can carry. `describe` is
 *  `JSON.stringify` for strings, so this is exactly the bytes the frame decoder
 *  will see. */
function worstCaseFrame(captured) {
  const field = '9'.repeat(MAX_FIELD_VALUE);
  return (
    'view{card(' + JSON.stringify(captured.cardId) + '){heading(' + HEADING_LEVEL + ',' +
    JSON.stringify(captured.headingText) + ') field(' + FIELD_NAME + '=' + JSON.stringify(field) +
    ') button(' + JSON.stringify(captured.buttonLabel) + ',' + captured.intent +
    ') text(' + JSON.stringify(captured.text) + ')}}'
  );
}

/** Gate the annotated root and return the captured fixed view, or throw. */
function gate(root) {
  if (root.kind !== 'vec') gfail('wrong-layout', root);
  const head = root.items[0];
  if (head === undefined || head.kind !== 'keyword') gfail('wrong-layout', head === undefined ? root : head);
  if (!KNOWN_OPS.includes(head.name)) gfail('unknown-op', head);
  if (head.name !== 'card') gfail('wrong-layout', head);
  if (root.items.length !== 2 + CHILD_SEQUENCE.length) gfail('wrong-layout', root);

  const attrs = root.items[1];
  if (attrs === undefined || attrs.kind !== 'map') gfail('wrong-layout', attrs === undefined ? root : attrs);
  checkKeys(attrs, ['id']);
  const idNode = mapGet(attrs, 'id');
  const cardId = idNode === undefined ? CARD_DEFAULT_ID : checkString(idNode);

  for (let k = 0; k < CHILD_SEQUENCE.length; k++) {
    const child = root.items[2 + k];
    if (child === undefined || child.kind !== 'vec') gfail('wrong-layout', child === undefined ? root : child);
    const op = child.items[0];
    if (op === undefined || op.kind !== 'keyword') gfail('wrong-layout', op === undefined ? child : op);
    if (!KNOWN_OPS.includes(op.name)) gfail('unknown-op', op);
    if (op.name !== CHILD_SEQUENCE[k]) gfail('wrong-layout', op);
  }

  const headingText = checkHeading(root.items[2]);
  const field = checkField(root.items[3]);
  const button = checkButton(root.items[4]);
  const text = checkText(root.items[5]);

  const totalVisible = headingText.length + MAX_FIELD_VALUE + button.label.length + text.length;
  if (totalVisible > MAX_TOTAL_TEXT) gfail('too-much-text', root);

  const captured = {
    cardId,
    headingLevel: HEADING_LEVEL,
    headingText,
    field,
    buttonLabel: button.label,
    intent: button.intent,
    text,
  };
  if (worstCaseFrame(captured).length > MAX_FRAME) gfail('oversized-frame', root);

  return { captured, totalVisible };
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. The manifest
// ─────────────────────────────────────────────────────────────────────────────

/** A deterministic eligibility manifest. No timestamps, no randomness, no
 *  object identity — the same source always serialises to the same bytes. */
function buildManifest(captured, totalVisible) {
  const frame = worstCaseFrame(captured);
  return {
    fenceVersion: FENCE_VERSION,
    verdict: 'client-view-only',
    grammar: {
      literals: ['vector', 'map', 'keyword', 'string', 'nonnegative-safe-integer'],
      ops: KNOWN_OPS.slice(),
      childOrder: CHILD_SEQUENCE.slice(),
    },
    bounds: {
      sourceChars: MAX_SOURCE,
      depth: MAX_DEPTH,
      tokens: MAX_TOKENS,
      attrText: MAX_ATTR_TEXT,
      totalText: MAX_TOTAL_TEXT,
      fieldValue: MAX_FIELD_VALUE,
      frameChars: MAX_FRAME,
    },
    captured: {
      card: { id: captured.cardId },
      heading: { level: captured.headingLevel, text: captured.headingText },
      field: captured.field,
      button: { label: captured.buttonLabel, intent: captured.intent },
      text: captured.text,
    },
    dynamic: {
      field: captured.field,
      providedBy: 'server-version-wire',
      maxChars: MAX_FIELD_VALUE,
      evaluatedClientSide: false,
    },
    intent: {
      op: captured.intent,
      authority: 'server',
      version: 'server-authoritative-monotonic-successor',
      payload: 'server-validated',
    },
    worstCase: {
      totalVisibleChars: totalVisible,
      frameChars: frame.length,
    },
    claim: 'one fixed closed data form may be evaluated on the client',
    notClaimed: [
      'general-bl-auto-fencing',
      'arbitrary-bl-placement',
      'untrusted-code-isolation',
      'authenticated-intent',
      'server-state-change-without-server',
    ],
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. The entry point
// ─────────────────────────────────────────────────────────────────────────────

function refusal(reason, line, column, path) {
  return { ok: false, reason, line, column, path };
}

/**
 * Read `source` as the one bounded quoted-view data form and decide, fail-closed,
 * whether it is frontend-eligible.
 *
 * @param {unknown} source
 * @returns {{ok: true, form: unknown, manifest: object}
 *         | {ok: false, reason: string, line: number, column: number, path: string}}
 *
 * Total: no input makes this throw. Every failure carries a reason, a 1-based
 * line/column and a `$`-rooted path (`[n]` for a vector slot, `.name` for a map
 * key). On success `form` is plain data (see the header) and `manifest` is the
 * deterministic verdict.
 */
export function fenceQuotedForm(source) {
  if (typeof source !== 'string') return refusal('source-not-a-string', 1, 1, '$');
  if (source.length > MAX_SOURCE) return refusal('oversized-source', 1, 1, '$');

  const reader = new Reader(source);
  let root;
  try {
    reader.skipSpace();
    if (reader.eof()) return refusal('empty-source', reader.line, reader.column, '$');
    root = reader.readValue('$', 0);
    reader.skipSpace();
    if (!reader.eof()) return refusal('trailing-syntax', reader.line, reader.column, '$');
  } catch (error) {
    if (error instanceof FormError) return refusal(error.reason, error.line, error.column, error.path);
    return refusal('reader-error', reader.line, reader.column, '$');
  }

  try {
    const { captured, totalVisible } = gate(root);
    return { ok: true, form: materialize(root), manifest: buildManifest(captured, totalVisible) };
  } catch (error) {
    if (error instanceof GateError) {
      const node = error.node;
      return refusal(error.reason, node.line, node.column, node.path);
    }
    return refusal('fence-error', 1, 1, '$');
  }
}

export default fenceQuotedForm;
