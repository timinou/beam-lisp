// A data reader and compiled BL evaluator in one browser Worker. No network API
// is used here; the backend bundle is neither imported nor available as a route.
import * as H from './host.mjs';
import { fenceQuotedForm, isKeyword } from './quoted-form.mjs';
import { decodeViewFrame, isViewLine } from './quoted-view-frame.mjs';

let pending = false;
let ready = false;

function valueToBL(value) {
  if (Array.isArray(value)) return H.vec(value.map(valueToBL));
  if (value instanceof Map) return H.bmap([...value].map(([k, v]) => [valueToBL(k), valueToBL(v)]));
  if (isKeyword(value)) return H.kw(value.keyword);
  if (typeof value === 'string' || Number.isSafeInteger(value)) return value;
  throw new Error('closed form contains unsupported data');
}

// Capture the actor's output before import: boot and registration run in its
// top-level await. A preview produces exactly one accepted or refused line.
console.log = (...args) => {
  const line = args.map(x => typeof x === 'string' ? x : String(x)).join(' ');
  if (line === 'QV-PLAY READY') { ready = true; postMessage({ kind: 'ready' }); return; }
  if (isViewLine(line)) {
    pending = false;
    const decoded = decodeViewFrame(line);
    postMessage(decoded.ok ? { kind: 'view', view: decoded.view } :
      { kind: 'error', text: 'compiled view frame refused: ' + decoded.reason });
    return;
  }
  if (line.startsWith('QV-PLAY REFUSED ')) {
    pending = false;
    postMessage({ kind: 'error', text: 'compiled BL evaluator refused: ' + line.slice(16) });
    return;
  }
  if (line === 'QV-PLAY STOP') { postMessage({ kind: 'stopped' }); return; }
  postMessage({ kind: 'error', text: line });
};

globalThis.onmessage = ({ data }) => {
  try {
    if (!data || typeof data !== 'object') return;
    if (data.kind === 'stop') { H.enqueueInput('stop', ''); return; }
    if (data.kind !== 'run') return;
    if (!ready || pending) {
      postMessage({ kind: 'refused', reason: ready ? 'busy' : 'not-ready', line: 1, column: 1, path: '$' });
      return;
    }
    const result = fenceQuotedForm(data.source);
    if (!result.ok) { postMessage({ kind: 'refused', ...result }); return; }
    const form = valueToBL(result.form);
    pending = true;
    postMessage({ kind: 'eligible', manifest: result.manifest });
    H.enqueueQuotedForm(form);
  } catch (error) {
    pending = false;
    postMessage({ kind: 'error', text: String(error) });
  }
};

// Remains pending while the BL actor waits for input; the Worker stays responsive.
import('./out/quoted-playground.mjs').then(
  () => postMessage({ kind: 'done' }),
  error => postMessage({ kind: 'error', text: String(error) }),
);
