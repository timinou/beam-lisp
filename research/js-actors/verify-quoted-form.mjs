// verify-quoted-form.mjs — the acceptance contract for the client-side fence
// `quoted-form.mjs`.
//
// Run from this directory (no BL build needed — the fence is plain JS):
//   node research/js-actors/verify-quoted-form.mjs
//
// WHAT IS ASSERTED, and why each half matters:
//   1. the EXACT accepted form — the fixture the quoted-view playground Worker
//      feeds the compiled evaluator — reads to plain data (arrays, `Map`,
//      interned keyword tokens, string, safe integer) and an eligible manifest;
//   2. accepted EDITS and comments/whitespace variants all parse, and an edited
//      view's manifest captures the edited strings;
//   3. a refusal table covering the demanded classes — malicious JS/BL calls,
//      quote/lists, symbols, reader macros, unknown op/attribute/field/intent,
//      wrong layout, duplicate keys, malformed source, and oversized
//      source/depth/tokens/strings/text/numbers — each with the expected typed
//      reason, a valid 1-based line/column and a `$`-rooted path;
//   4. every emitted reason is a member of the exported `REASONS` vocabulary,
//      so a typo'd diagnostic cannot pass unnoticed;
//   5. determinism — the same source yields a byte-identical manifest;
//   6. BOUNDS COMPATIBILITY — a frame built from the captured manifest is
//      accepted by the REAL strict decoder (`quoted-view-frame.mjs`), and the
//      worst-case frame/total-text lengths stay inside the core's bounds;
//   7. no-EVALUATION — the module constructs no JavaScript at runtime.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  fenceQuotedForm, keyword, isKeyword, REASONS,
  MAX_SOURCE, MAX_DEPTH, MAX_TOKENS, MAX_ATTR_TEXT, MAX_TOTAL_TEXT,
  MAX_FIELD_VALUE, MAX_FRAME, FENCE_VERSION,
} from './quoted-form.mjs';
import { decodeViewFrame } from './quoted-view-frame.mjs';

const modulePath = new URL('./quoted-form.mjs', import.meta.url);
const reasonSet = new Set(REASONS);

function pass(label) { console.log('PASS ' + label); }

// ── fixtures ─────────────────────────────────────────────────────────────────

const H = '[:heading {:level 2 :text "Inbox"}]';
const F = '[:field :unread]';
const B = '[:button {:label "Mark all read" :intent [:intent :increment]}]';
const T = '[:text "no unread mail"]';
const card = (children) => `[:card {:id "inbox"} ${children}]`;
const OK = card(`${H} ${F} ${B} ${T}`);

// ── 1. the accepted form ─────────────────────────────────────────────────────

const base = fenceQuotedForm(OK);
assert.equal(base.ok, true, 'the canonical view must be eligible');
assert.deepEqual(Object.keys(base).sort(), ['form', 'manifest', 'ok']);

const form = base.form;
assert.ok(Array.isArray(form), 'a BL vector must become a JS array');
assert.equal(form.length, 6, 'card + attrs + four children');
assert.ok(isKeyword(form[0]) && form[0].keyword === 'card', 'op must be a keyword token');
assert.ok(form[1] instanceof Map, 'a BL map must become a Map');
assert.equal(form[1].get(keyword('id')), 'inbox');
assert.ok(isKeyword(form[2][0]) && form[2][0].keyword === 'heading');
assert.ok(form[2][1] instanceof Map);
assert.equal(form[2][1].get(keyword('level')), 2);
assert.equal(form[2][1].get(keyword('text')), 'Inbox');
assert.ok(isKeyword(form[3][0]) && form[3][0].keyword === 'field');
assert.ok(isKeyword(form[3][1]) && form[3][1].keyword === 'unread');
assert.ok(form[4][1] instanceof Map);
assert.equal(form[4][1].get(keyword('label')), 'Mark all read');
assert.ok(Array.isArray(form[4][1].get(keyword('intent'))));
assert.equal(form[4][1].get(keyword('intent'))[1].keyword, 'increment');
assert.ok(isKeyword(form[5][0]) && form[5][0].keyword === 'text');
assert.equal(form[5][1], 'no unread mail');
assert.equal(typeof form[2][1].get(keyword('level')), 'number');
// keyword tokens are interned so a Map is readable by keyword lookup
assert.equal(keyword('id'), keyword('id'));
assert.equal(isKeyword('id'), false);
assert.equal(isKeyword({ keyword: 'id', extra: 1 }), false);

const manifest = base.manifest;
assert.equal(manifest.fenceVersion, FENCE_VERSION);
assert.equal(manifest.verdict, 'client-view-only');
assert.equal(manifest.dynamic.field, 'unread');
assert.equal(manifest.dynamic.providedBy, 'server-version-wire');
assert.equal(manifest.dynamic.evaluatedClientSide, false);
assert.equal(manifest.intent.op, 'increment');
assert.equal(manifest.intent.authority, 'server');
assert.equal(manifest.intent.version, 'server-authoritative-monotonic-successor');
assert.ok(manifest.notClaimed.includes('general-bl-auto-fencing'),
  'the manifest must explicitly disclaim general BL auto-fencing');
assert.equal(manifest.captured.field, 'unread');
assert.equal(manifest.captured.card.id, 'inbox');
assert.equal(manifest.captured.heading.level, 2);
assert.equal(manifest.captured.button.intent, 'increment');
pass('accepted form: arrays, Map, interned keyword tokens, client-view-only manifest');

// ── 2. accepted edits, comments and whitespace ───────────────────────────────

const commented =
  '; an edited view\n' +
  '[ :card , { :id "inbox" }  ; the card\n' +
  '  [:heading {:level 2 :text "Today"}] ; heading\n' +
  '  [:field :unread]\n' +
  '  [:button {:label "Refresh" :intent [:intent :increment]}]\n' +
  '  [:text "3 items"] ; trailing comment\n' +
  ']';
const edited = fenceQuotedForm(commented);
assert.equal(edited.ok, true, 'comments and whitespace must be accepted');
assert.equal(edited.manifest.captured.heading.text, 'Today');
assert.equal(edited.manifest.captured.button.label, 'Refresh');
assert.equal(edited.manifest.captured.text, '3 items');
assert.equal(edited.manifest.captured.card.id, 'inbox');
// the accepted variants materialise to exactly the same data shape
assert.equal(edited.form[2][1].get(keyword('text')), 'Today');

// a form with no `:id` defaults to the core's `_`, and stays eligible
const noId = fenceQuotedForm(`[:card {} ${H} ${F} ${B} ${T}]`);
assert.equal(noId.ok, true);
assert.equal(noId.manifest.captured.card.id, '_');

// a trailing comment after the whole form is consumed, not trailing syntax
assert.equal(fenceQuotedForm(`${OK} ; done\n`).ok, true);
pass('accepted edits: comments, commas, whitespace, optional :id');

// ── 3. refusals ──────────────────────────────────────────────────────────────

const REFUSALS = [
  // malicious JS / BL calls and lists
  ['list form (JS call)', '(function () { return 1 })()', 'list-form'],
  ['list form (eval-like)', '(eval "2+2")', 'list-form'],
  ['list form (BL call)', '(host/write "x")', 'list-form'],
  ['child list form', card(`(host/write "x") ${F} ${B} ${T}`), 'list-form'],
  ['quote literal', "'[:card {:id \"x\"}]", 'quote-literal'],
  ['syntax quote', '`x', 'syntax-quote'],
  ['unquote', '~x', 'unquote'],
  ['deref form', '@x', 'deref-form'],
  ['metadata form', '^:a', 'metadata-form'],
  ['dispatch form', '#{1}', 'dispatch-form'],
  ['char literal', '\\a', 'char-literal'],
  // symbols / names / captures
  ['bare symbol', 'foo', 'symbol'],
  ['symbol in vector', '[foo]', 'symbol'],
  ['namespaced symbol', 'host/write', 'symbol'],
  // malformed source
  ['empty source', '', 'empty-source'],
  ['comment only', '  ; nothing here\n', 'empty-source'],
  ['unterminated string', card(`${H} ${F} ${B} [:text "abc]`), 'unterminated-string'],
  ['unterminated form', `[:card {:id "inbox"} ${H} ${F} ${B}`, 'unterminated-form'],
  ['bad escape', card(`${H} ${F} ${B} [:text "a\\qb"]`), 'bad-escape'],
  ['bad keyword', '[:]', 'bad-keyword'],
  ['map key not keyword', '[:card {"id" "x"}]', 'map-key-not-keyword'],
  ['malformed map', card(`${H} ${F} ${B} [:button {:label "b" :intent}]`), 'malformed-map'],
  ['trailing syntax', `${OK} extra`, 'trailing-syntax'],
  ['trailing closing paren', `${OK})`, 'trailing-syntax'],
  ['source not a string', 42, 'source-not-a-string'],
  // duplicate keys
  ['duplicate key', `[:card {:id "a" :id "b"} ${H} ${F} ${B} ${T}]`, 'duplicate-key'],
  // oversized source / depth / tokens
  ['oversized source', '[' + ' '.repeat(MAX_SOURCE), 'oversized-source'],
  ['oversized depth', '['.repeat(MAX_DEPTH + 4) + ']'.repeat(MAX_DEPTH + 4), 'too-deep'],
  ['too many tokens', '[' + Array.from({ length: MAX_TOKENS + 40 }, () => '0').join(' ') + ']', 'too-many-tokens'],
  // oversized / unsupported numbers
  ['negative number', '[:text -1]', 'negative-number'],
  ['float', '[:text 1.5]', 'unsupported-number'],
  ['hex number', '[:text 0x10]', 'unsupported-number'],
  ['leading zero', '[:text 007]', 'non-canonical-number'],
  ['number out of range', '[:text 9007199254740992]', 'number-out-of-range'],
  // unknown op / attribute / field / intent
  ['unknown op at root', '[:marquee {:id "x"}]', 'unknown-op'],
  ['unknown op as child', card(`[:effect :now] ${F} ${B} ${T}`), 'unknown-op'],
  ['unknown attribute (card)', `[:card {:id "x" :href "y"} ${H} ${F} ${B} ${T}]`, 'unknown-attribute'],
  ['unknown attribute (heading)', card(`[:heading {:level 2 :text "I" :onclick "x"}] ${F} ${B} ${T}`), 'unknown-attribute'],
  ['unknown field', card(`${H} [:field :secret] ${B} ${T}`), 'unknown-field'],
  ['malformed field', card(`${H} [:field "unread"] ${B} ${T}`), 'malformed-field'],
  ['unknown intent', card(`${H} ${F} [:button {:label "b" :intent [:intent :delete]}] ${T}`), 'unknown-intent'],
  ['intent shape', card(`${H} ${F} [:button {:label "b" :intent :increment}] ${T}`), 'intent-shape'],
  // wrong layout / shape
  ['heading at root', '[:heading {:level 2 :text "I"}]', 'wrong-layout'],
  ['non-vector card', ':card', 'wrong-layout'],
  ['children swapped', card(`${F} ${H} ${B} ${T}`), 'wrong-layout'],
  ['extra child', card(`${H} ${F} ${B} ${T} ${T}`), 'wrong-layout'],
  ['missing child', card(`${H} ${F} ${B}`), 'wrong-layout'],
  ['heading level 3', card(`[:heading {:level 3 :text "I"}] ${F} ${B} ${T}`), 'heading-level'],
  ['heading level not integer', card(`[:heading {:level "2" :text "I"}] ${F} ${B} ${T}`), 'attribute-not-an-integer'],
  ['missing heading level', card(`[:heading {:text "I"}] ${F} ${B} ${T}`), 'missing-attribute'],
  ['missing button intent', card(`${H} ${F} [:button {:label "b"}] ${T}`), 'missing-attribute'],
  ['heading extra arity', card(`[:heading {:level 2 :text "I"} 3] ${F} ${B} ${T}`), 'malformed-arity'],
  ['text not a string', card(`${H} ${F} ${B} [:text 3]`), 'attribute-not-a-string'],
  // oversized strings / total text / control characters
  ['oversized card id', `[:card {:id "${'A'.repeat(MAX_ATTR_TEXT + 1)}"} ${H} ${F} ${B} ${T}]`, 'oversized-attribute'],
  ['oversized heading text', card(`[:heading {:level 2 :text "${'A'.repeat(MAX_ATTR_TEXT + 1)}"}] ${F} ${B} ${T}`), 'oversized-attribute'],
  ['oversized button label', card(`${H} ${F} [:button {:label "${'B'.repeat(MAX_ATTR_TEXT + 1)}" :intent [:intent :increment]}] ${T}`), 'oversized-attribute'],
  ['oversized copy', card(`${H} ${F} ${B} [:text "${'C'.repeat(MAX_ATTR_TEXT + 1)}"]`), 'oversized-attribute'],
  ['too much total text',
    card(`[:heading {:level 2 :text "${'A'.repeat(40)}"}] ${F} ` +
      `[:button {:label "${'B'.repeat(30)}" :intent [:intent :increment]}] [:text "${'C'.repeat(20)}"]`),
    'too-much-text'],
  ['control character', card(`${H} ${F} ${B} [:text "a\\nb"]`), 'control-char'],
  ['outer frame escape expansion',
    `[:card {:id "${String.fromCharCode(0xd800).repeat(64)}"} ` +
      `[:heading {:level 2 :text "${String.fromCharCode(0xd800).repeat(30)}"}] ${F} ` +
      `[:button {:label "${String.fromCharCode(0xd800).repeat(30)}" :intent [:intent :increment]}] ` +
      `[:text "${String.fromCharCode(0xd800).repeat(20)}"]]`, 'oversized-frame'],
];

let refusalCount = 0;
for (const [label, source, reason] of REFUSALS) {
  const result = fenceQuotedForm(source);
  assert.equal(result.ok, false, `${label}: must be refused`);
  assert.equal(result.reason, reason, `${label}: wrong reason`);
  assert.deepEqual(Object.keys(result).sort(), ['column', 'line', 'ok', 'path', 'reason'],
    `${label}: a refusal must carry only reason/line/column/path`);
  assert.ok(Number.isInteger(result.line) && result.line >= 1, `${label}: bad line ${result.line}`);
  assert.ok(Number.isInteger(result.column) && result.column >= 1, `${label}: bad column ${result.column}`);
  assert.ok(typeof result.path === 'string' && result.path.startsWith('$'), `${label}: bad path ${result.path}`);
  assert.ok(reasonSet.has(result.reason), `${label}: reason not in REASONS vocabulary`);
  refusalCount += 1;
}
pass(`refusals: ${refusalCount} typed, positioned, no partial form or manifest`);

// ── 4. the vocabulary is closed and observed reasons are declared ────────────

const observed = new Set(REFUSALS.map(([, , reason]) => reason));
assert.ok(observed.size >= 25, 'the refusal table must exercise a broad vocabulary');
assert.equal(new Set(REASONS).size, REASONS.length, 'the reason vocabulary must be unique');
pass(`reason vocabulary: ${observed.size} distinct reasons observed of ${REASONS.length} declared`);

// ── 5. determinism ───────────────────────────────────────────────────────────

const again = fenceQuotedForm(OK);
assert.deepEqual(again.manifest, base.manifest, 'manifest must be deterministic');
assert.equal(JSON.stringify(again.manifest), JSON.stringify(base.manifest),
  'manifest serialisation must be byte-identical');
assert.deepEqual(again.form, base.form, 'form must be deterministic');
assert.equal(JSON.stringify(fenceQuotedForm(OK).manifest), JSON.stringify(fenceQuotedForm(OK).manifest));
pass('determinism: identical source yields a byte-identical manifest and form');

// ── 6. bounds compatibility with the real core and the strict decoder ────────

// Reconstruct the exact frame the core would render, from the manifest alone,
// and decode it with the shipped strict decoder. This is a bound cross-check,
// not a second evaluator: the template is the one the decoder documents.
function frameFor(captured, version) {
  return 'view{card(' + JSON.stringify(captured.card.id) + '){heading(' + captured.heading.level + ',' +
    JSON.stringify(captured.heading.text) + ') field(' + captured.field + '=' + JSON.stringify(version) +
    ') button(' + JSON.stringify(captured.button.label) + ',' + captured.button.intent +
    ') text(' + JSON.stringify(captured.text) + ')}}';
}
function decode(frame) {
  return decodeViewFrame('QV-FRONT VIEW [:ok ' + JSON.stringify(frame) + ']');
}

for (const version of ['0', '7', '9999999999999999']) {
  const decoded = decode(frameFor(manifest.captured, version));
  assert.equal(decoded.ok, true, `frame for version ${version} must decode: ${decoded.reason}`);
  assert.equal(decoded.view.field.value, version);
}
const worst = '9'.repeat(MAX_FIELD_VALUE);
assert.equal(manifest.worstCase.frameChars,
  ('QV-FRONT VIEW [:ok ' + JSON.stringify(frameFor(manifest.captured, worst)) + ']').length,
  'manifest worst-case frame length must match the reconstructed frame');
assert.ok(manifest.worstCase.frameChars <= MAX_FRAME, 'worst-case frame must fit one line');
assert.equal(manifest.worstCase.totalVisibleChars,
  manifest.captured.heading.text.length + MAX_FIELD_VALUE +
  manifest.captured.button.label.length + manifest.captured.text.length);
assert.ok(manifest.worstCase.totalVisibleChars <= MAX_TOTAL_TEXT, 'worst-case visible text must fit');

// The bound is inclusive: a form whose static text + the dynamic field exactly
// fills the core's total-text bound is eligible; one character more is not.
const atBound = card(
  `[:heading {:level 2 :text "${'A'.repeat(30)}"}] ${F} ` +
  `[:button {:label "${'B'.repeat(30)}" :intent [:intent :increment]}] [:text "${'C'.repeat(20)}"]`);
const atBoundResult = fenceQuotedForm(atBound);
assert.equal(atBoundResult.ok, true, 'a form exactly at the total-text bound is eligible');
assert.equal(atBoundResult.manifest.worstCase.totalVisibleChars, MAX_TOTAL_TEXT);
const overBound = atBound.replace('C'.repeat(20), 'C'.repeat(21));
assert.equal(fenceQuotedForm(overBound).reason, 'too-much-text');
pass(`bounds: rebuilt frames decode; frame ${manifest.worstCase.frameChars}/${MAX_FRAME}, ` +
  `visible ${manifest.worstCase.totalVisibleChars}/${MAX_TOTAL_TEXT} (inclusive)`);

// ── 7. no JavaScript is constructed at runtime ───────────────────────────────

const source = readFileSync(modulePath, 'utf8');
assert.doesNotMatch(source, /\beval\s*\(/, 'the fence must not call eval');
assert.doesNotMatch(source, /new\s+Function\s*\(/, 'the fence must not construct a Function');
assert.match(source, /export function fenceQuotedForm\(source\)/);
assert.match(source, /export default fenceQuotedForm;/);
pass('no-evaluation: the fence parses data only, never JavaScript');

// ── 8. totality under fuzz ───────────────────────────────────────────────────
// The fence must never throw: whatever bytes a user types, it returns either an
// eligible form or a fully positioned refusal. A seeded LCG keeps the corpus
// reproducible across runs.
let seed = 0x2f6e2b1;
function rnd() { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; }
const ALPHABET = '[]{}():;"\\\'`~@^# abcxyz0123456789,\n\t';
let fuzzed = 0;
for (let n = 0; n < 20000; n++) {
  const length = Math.floor(rnd() * 40);
  let sample = '';
  for (let i = 0; i < length; i += 1) sample += ALPHABET[Math.floor(rnd() * ALPHABET.length)];
  const result = fenceQuotedForm(sample);
  assert.equal(typeof result.ok, 'boolean', 'a fuzz input produced no verdict');
  if (result.ok) {
    assert.ok(Array.isArray(result.form));
    assert.equal(result.manifest.dynamic.field, 'unread');
  } else {
    assert.ok(reasonSet.has(result.reason), `fuzz reason outside the vocabulary: ${result.reason}`);
    assert.ok(result.line >= 1 && result.column >= 1 && result.path.startsWith('$'));
  }
  fuzzed += 1;
}
pass(`totality: ${fuzzed} fuzz inputs, every one a verdict, none threw`);

console.log('js-actors: QUOTED-FORM PASS');
