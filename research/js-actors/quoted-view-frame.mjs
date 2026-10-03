// quoted-view-frame.mjs — the strict, browser-side decoder for the ONE frame
// the quoted-view frontend actor writes.
//
// TRANSPORT, NOT POLICY. The actor owns what a view IS (`quoted-view-core.bl`
// fixes the closed grammar) and what a version wire is accepted
// (`quoted-frontend.bl`). This module owns ONE thing the actor cannot: turning
// the actor's single `QV-FRONT VIEW` line into a SMALL, TYPED value object the
// page can render with text properties alone. It decides nothing about intent,
// authorization or versions — it only refuses a frame it cannot prove matches
// the one shape below.
//
// THE FRAME. The actor writes (through `host/describe`, which quotes and escapes
// the inner string) exactly:
//
//     QV-FRONT VIEW [:ok "view{card(\"<id>\"){heading(2,\"<title>\")
//                              field(unread=\"<value>\") button(\"<label>\",increment)
//                              text(\"<copy>\")}}"]
//
// The outer text is the printable form of the BL value `[:ok <string>]`, so the
// bytes after `[:ok ` must be ONE JSON string literal. The inner string is the
// core's fixed whitelist template: the ops, the tags, the heading level (2), the
// field name (`unread`), the button intent (`increment`) and the number and order
// of children are ALL fixed; only the five JSON-quoted strings vary.
//
// FAIL CLOSED. Every accepted frame is parsed in full; any deviation — a changed
// op or tag, a heading level that is not 2, an unknown field name, an intent
// other than `increment`, an extra or missing child, extra syntax after the
// frame, an over-long string, a control character or a malformed JSON escape —
// is a typed refusal. `decodeViewFrame` NEVER throws and NEVER returns a partial
// view: an attacker who fully controls the line still only chooses which refusal
// reason they get.
//
// WHY JSON.parse FOR EACH QUOTED FIELD. `JSON.parse` is the one parser here that
// is exact about escapes, so a malformed escape (`"\q"`), an unterminated string
// or an embedded raw newline cannot smuggle extra structure past the reader. Each
// quoted field is located by scanning to its closing unescaped quote, then handed
// to `JSON.parse` WHOLE; a decoded value that still contains a control character
// is refused so a decoded string cannot reintroduce a line/frame boundary.
//
// WHAT THIS IS NOT. It is not an authorization boundary and not a sanitiser: the
// page must still render only through `textContent`/data attributes, because a
// value that decodes cleanly is still server-influenced text. It assumes the
// frame is delivered on an already-trusted same-origin Worker channel; the outer
// `console.log` interception that produces the line lives in the worker.

/** The one accepted line prefix. A line without it is not a view frame at all. */
export const VIEW_PREFIX = 'QV-FRONT VIEW ';
/** The BL printable head of the accepted value: `[:ok <string>]`. */
export const OUTER_HEAD = '[:ok ';

/** Whole-line bound. The fixed view plus a bounded version is well under this. */
export const MAX_LINE = 1024;
/** Per-string bound, mirroring the core's `qv-max-attr-text` (64). */
export const MAX_STRING = 64;
/** Total visible text bound, mirroring the core's `qv-max-text` (96). */
export const MAX_TOTAL_TEXT = 96;

/** The only field name this one view exposes; any other is `unknown-field`. */
const FIELD_NAMES = ['unread'];
/** The only button intent this one view exposes; any other is `unknown-intent`. */
const BUTTON_INTENTS = ['increment'];
/** The only heading level this one view exposes; any other is rejected. */
const HEADING_LEVEL = '2';

/** A refusal raised INSIDE the parser. It never escapes `decodeViewFrame`. */
class FrameError {
  constructor(reason) { this.reason = reason; }
}

function fail(reason) { return { ok: false, reason }; }

/** Whether `line` claims to be a view frame. Cheap and total; the caller still
 *  must `decodeViewFrame` before trusting anything it says. */
export function isViewLine(line) {
  return typeof line === 'string' && line.startsWith(VIEW_PREFIX);
}

/** Parse ONE JSON string literal beginning at `at`, or return null.
 *
 *  The closing quote is found by skipping escape pairs, then the whole slice is
 *  given to `JSON.parse`, which is what rejects a malformed escape or an
 *  unterminated string. Nothing is constructed by hand. */
function parseJsonString(src, at) {
  if (src[at] !== '"') return null;
  let j = at + 1;
  while (j < src.length) {
    const c = src[j];
    if (c === '\\') { j += 2; continue; }
    if (c === '"') break;
    j += 1;
  }
  if (src[j] !== '"') return null; // unterminated, or an escape ate the close
  const raw = src.slice(at, j + 1);
  let value;
  try { value = JSON.parse(raw); } catch { return null; }
  return typeof value === 'string' ? { value, next: j + 1 } : null;
}

/** Bound a decoded string and refuse a control character. A decoded `\n` would
 *  otherwise let a single value span what the log treats as one line. */
function checkString(value, reason) {
  if (value.length > MAX_STRING) throw new FrameError('oversized-' + reason);
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code < 0x20 || code === 0x7f) throw new FrameError('control-char-' + reason);
  }
}

/** Parse the inner `view{…}` string. Every literal, op, tag and bound is fixed;
 *  only the five quoted strings carry data. Throws `FrameError` on any deviation,
 *  including trailing syntax. */
function parseView(src) {
  let i = 0;
  const at = (text, reason) => {
    if (!src.startsWith(text, i)) throw new FrameError(reason);
    i += text.length;
  };
  const str = (reason) => {
    const hit = parseJsonString(src, i);
    if (hit === null) throw new FrameError(reason);
    i = hit.next;
    checkString(hit.value, reason);
    return hit.value;
  };
  // A bareword token (level, field name, intent) runs to `stop`, bounded so a
  // missing delimiter cannot scan the whole frame.
  const word = (stop, max, reason) => {
    const start = i;
    while (i < src.length && src[i] !== stop) {
      i += 1;
      if (i - start > max) throw new FrameError(reason);
    }
    return src.slice(start, i);
  };

  at('view{', 'view-open');
  at('card(', 'card-op');
  const id = str('card-id');
  at('){', 'card-body');
  at('heading(', 'heading-op');
  if (word(',', 2, 'heading-level') !== HEADING_LEVEL) throw new FrameError('heading-level');
  at(',', 'heading-level');
  const headingText = str('heading-text');
  at(')', 'heading-close');
  at(' ', 'child-separator');
  at('field(', 'field-op');
  const fieldName = word('=', 16, 'field-name');
  if (!FIELD_NAMES.includes(fieldName)) throw new FrameError('unknown-field');
  at('=', 'field-value');
  const fieldValue = str('field-value');
  at(')', 'field-close');
  at(' ', 'child-separator');
  at('button(', 'button-op');
  const buttonLabel = str('button-label');
  at(',', 'button-intent');
  const intent = word(')', 32, 'button-intent');
  if (!BUTTON_INTENTS.includes(intent)) throw new FrameError('unknown-intent');
  at(')', 'button-close');
  at(' ', 'child-separator');
  at('text(', 'text-op');
  const copy = str('text-copy');
  at(')', 'text-close');
  at('}}', 'view-close');
  if (i !== src.length) throw new FrameError('trailing-syntax');
  const total = headingText.length + fieldValue.length + buttonLabel.length + copy.length;
  if (total > MAX_TOTAL_TEXT) throw new FrameError('too-much-text');

  return {
    card: { id },
    heading: { level: 2, text: headingText },
    field: { name: fieldName, value: fieldValue },
    button: { label: buttonLabel, intent },
    text: copy,
  };
}

/**
 * Decode ONE actor line into `{ok: true, view}` or `{ok: false, reason}`.
 *
 * The outer value must be exactly `[:ok <one JSON string>]`, the string must be
 * the fixed `view{…}` shape, and every quoted field must be valid JSON within its
 * bound. No input — however malformed — makes this throw.
 */
export function decodeViewFrame(line) {
  try {
    if (typeof line !== 'string') return fail('not-a-string');
    if (line.length > MAX_LINE) return fail('oversized-frame');
    if (!line.startsWith(VIEW_PREFIX)) return fail('missing-prefix');
    const rest = line.slice(VIEW_PREFIX.length);
    if (!rest.startsWith(OUTER_HEAD) || !rest.endsWith(']')) return fail('frame-shape');
    const jsonText = rest.slice(OUTER_HEAD.length, -1);
    if (jsonText.length < 2 || jsonText[0] !== '"' || jsonText[jsonText.length - 1] !== '"')
      return fail('frame-not-a-string');
    let inner;
    try { inner = JSON.parse(jsonText); } catch { return fail('frame-bad-json'); }
    if (typeof inner !== 'string') return fail('frame-not-a-string');
    return { ok: true, view: parseView(inner) };
  } catch (error) {
    if (error instanceof FrameError) return fail(error.reason);
    return fail('decoder-error');
  }
}
