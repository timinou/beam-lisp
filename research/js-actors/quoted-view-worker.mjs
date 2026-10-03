// quoted-view-worker.mjs — the browser Worker transport for the quoted view.
//
// TRANSPORT, NOT POLICY. The Worker's scheduling, the ONE view, the version wire
// rule and the view's meaning are all written in BL (`quoted-frontend.bl` +
// `quoted-view-core.bl` + `runtime.bl`, built to `out/quoted-frontend.mjs`). This
// file only moves bytes across three boundaries the BL actor cannot see:
//
//   1. `host/write` → the page. The actor writes ONE line per event through
//      `console.log`; the override below captures each line, decodes a
//      `QV-FRONT VIEW …` frame with `quoted-view-frame.mjs`, and posts a small
//      typed message. A frame that fails the decoder becomes an `error` message,
//      never a rendered view, so a malformed line cannot reach the DOM.
//   2. page → the actor. `onmessage` accepts exactly `version` (a string payload)
//      and `stop`, and hands each to the BL actor with `H.enqueueInput`. Any
//      other topic is refused with an error message and enqueues nothing.
//   3. actor failure → the page. An import failure, a bad decode or an event
//      failure is forwarded as an `error` message; the Worker never throws out of
//      an event and never leaves the page waiting on silence.
//
// THE IMPORT REMAINS PENDING WHILE THE ACTOR WAITS. `out/quoted-frontend.mjs`
// runs `await H.boot(rt)` at its top level, and the actor's `receive` parks the
// scheduler until the next browser event, so the dynamic `import` below does not
// resolve until `:stop` ends the actor. That pending promise IS the Worker's
// lifetime: it is not awaited with `await` at the top level, because the Worker
// must stay responsive to `onmessage` while the actor waits.
//
// NO DOM HERE. This Worker only decodes and posts structured data; all rendering
// lives in the page, which assigns text through `textContent` and data
// attributes only.

import * as H from './host.mjs';
import { decodeViewFrame, isViewLine } from './quoted-view-frame.mjs';

const REFUSED_PREFIX = 'QV-FRONT REFUSED ';
const STOP_LINE = 'QV-FRONT STOP';

/** Post one structured message to the page. The Worker is the only writer. */
function send(message) { postMessage(message); }

/** The actor writes through `console.log(...args)`; join exactly as the host
 *  does so a line is byte-identical to what `host/write` produced. */
function lineOf(args) {
  return args.map(value => (typeof value === 'string' ? value : String(value))).join(' ');
}

// Capture the actor's output BEFORE importing it: the first view is written
// during import, so a later override would miss it. Only this Worker's console is
// affected (each Worker owns its own global scope).
console.log = (...args) => {
  const text = lineOf(args);
  if (isViewLine(text)) {
    const decoded = decodeViewFrame(text);
    if (decoded.ok) send({ kind: 'view', view: decoded.view });
    else send({ kind: 'error', text: 'frame rejected: ' + decoded.reason });
    return;
  }
  if (text.startsWith(REFUSED_PREFIX)) { send({ kind: 'refused', text }); return; }
  if (text === STOP_LINE) { send({ kind: 'stopped' }); return; }
  send({ kind: 'output', text });
};

globalThis.onmessage = ({ data }) => {
  try {
    if (!data || data.kind !== 'event') return;
    if (data.topic === 'version') {
      if (typeof data.payload !== 'string') {
        send({ kind: 'error', text: 'version event payload must be a string' });
        return;
      }
      H.enqueueInput('version', data.payload);
      return;
    }
    if (data.topic === 'stop') { H.enqueueInput('stop', ''); return; }
    send({ kind: 'error', text: 'unsupported event topic: ' + String(data.topic) });
  } catch (error) {
    send({ kind: 'error', text: String((error && error.stack) || error) });
  }
};

// Not awaited: the pending import is the actor's lifetime, and the Worker must
// keep answering events while it waits. Resolution (after `:stop`) ends the run.
import('./out/quoted-frontend.mjs').then(
  () => send({ kind: 'done' }),
  error => send({ kind: 'error', text: String((error && error.stack) || error) }),
);
