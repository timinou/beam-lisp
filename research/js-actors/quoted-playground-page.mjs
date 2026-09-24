// The page displays typed Worker output and forwards one versioned intent.
// Editing/Run stays entirely in the Worker; only a button click contacts BL's
// authoritative backend. Every dynamic value enters the DOM via textContent.
import { createIntentCodec } from './quoted-intent-codec.mjs';

const $ = selector => document.querySelector(selector);
const source = $('#source');
const runButton = $('#run');
const intentButton = $('#intent');
const verdict = $('#verdict');
const diagnostic = $('#diagnostic');
const worker = new Worker(new URL('./quoted-playground-worker.mjs', import.meta.url), { type: 'module' });

const demo = {
  ready: false, pending: false, intentPending: false, failed: false,
  view: null, version: null, manifest: null, codec: null, refusal: null,
  errors: [], messages: [], lastResult: null, run, request, worker,
};
window.quotedPlayground = demo;

function canRequest() {
  return demo.ready && !demo.pending && !demo.intentPending && !demo.failed &&
    demo.view !== null && demo.codec !== null && demo.codec.matchesView(demo.manifest) &&
    demo.codec.versionOK(demo.version);
}
function state(kind, label, detail) {
  verdict.dataset.state = kind;
  verdict.textContent = label;
  diagnostic.dataset.kind = kind;
  diagnostic.textContent = detail;
  runButton.disabled = !demo.ready || demo.pending || demo.intentPending || demo.failed;
  intentButton.disabled = !canRequest();
}
function run() {
  if (!demo.ready || demo.pending || demo.intentPending || demo.failed) return false;
  demo.pending = true;
  demo.refusal = null;
  // An edit invalidates the old view/manifest's authority until BL renders the
  // new form. The last good preview remains visible but cannot send an intent.
  demo.manifest = null;
  state('running', 'Evaluating', 'Fencing this form inside the browser Worker…');
  worker.postMessage({ kind: 'run', source: source.value });
  return true;
}
function showView(view) {
  $('#title').textContent = view.heading.text;
  $('#field').textContent = view.field.name + ': ' + view.field.value;
  intentButton.textContent = view.button.label;
  $('#copy').textContent = view.text;
  $('#render').dataset.cardId = view.card.id;
  demo.view = view;
  demo.version = view.field.value;
}

async function request(op = demo.manifest?.intent?.op, version = demo.version) {
  if (!canRequest()) return (demo.lastResult = { ok: false, reason: 'not-ready' });
  const encoded = demo.codec.encodeRequest(op, version);
  if (!encoded.ok) return (demo.lastResult = encoded);
  demo.intentPending = true;
  state('running', 'Awaiting server', 'Sending an intent; the preview will not change until the backend accepts it.');
  let result;
  try {
    const response = await fetch('/api/intent', {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: encoded.body,
      credentials: 'same-origin', mode: 'same-origin', cache: 'no-store',
    });
    result = demo.codec.decodeResponse(response.status, await response.json(), version);
  } catch (error) {
    result = { ok: false, reason: 'network-error' };
    demo.errors.push(String(error));
  }
  if (result.ok && version !== demo.version)
    result = { ok: false, reason: 'inconsistent-response', fatal: true };
  demo.lastResult = result;
  if (result.ok) {
    // Keep intentPending true until the BL actor's NEW frame is decoded. A
    // success response cannot optimistically change the displayed version.
    demo.expectedVersion = result.version;
    state('running', 'Rendering server result', 'Backend accepted. Waiting for compiled BL to render version ' + result.version + '…');
    worker.postMessage({ kind: 'server-version', version: result.version });
  } else {
    demo.intentPending = false;
    if (result.fatal) demo.failed = true;
    state(result.fatal ? 'error' : 'refused', result.fatal ? 'Contract mismatch' : 'Server refused',
      result.reason + ' · last confirmed view remains unchanged.');
  }
  return result;
}

worker.onmessage = ({ data }) => {
  if (!data || typeof data.kind !== 'string') return;
  demo.messages.push(data.kind);
  switch (data.kind) {
    case 'ready':
      demo.ready = true;
      state('ready', 'Worker ready', 'Compiled BL actor ready. Run the form to evaluate it.');
      run();
      break;
    case 'eligible':
      demo.manifest = data.manifest;
      $('#view-contract').textContent = data.manifest.verdict + ' · fixed ' + data.manifest.grammar.childOrder.join(' → ');
      $('#field-contract').textContent = ':' + data.manifest.dynamic.field + ' · version from last confirmed server frame';
      $('#intent-contract').textContent = ':' + data.manifest.intent.op + ' · server validates/commits';
      state('running', 'Eligible · rendering', 'Closed form admitted. Compiled BL is rendering it locally…');
      break;
    case 'view':
      if (demo.intentPending && data.view.field.value !== demo.expectedVersion) {
        demo.failed = true;
        demo.errors.push('BL Worker returned a version different from the accepted server result');
        state('error', 'Version mismatch', 'Reload to resynchronize; last confirmed view remains unchanged.');
        break;
      }
      demo.pending = false;
      demo.intentPending = false;
      showView(data.view);
      state('eligible', 'Frontend eligible', 'Rendered by compiled BL in this Worker. Run never sends source or a view request to the backend.');
      break;
    case 'refused':
      demo.pending = false;
      demo.refusal = data;
      state('refused', 'Fence refused', data.reason + ' at ' + data.line + ':' + data.column + ' (' + data.path + '). Previous preview stays unchanged.');
      break;
    case 'error':
      demo.pending = false;
      if (demo.intentPending) demo.failed = true;
      demo.intentPending = false;
      demo.errors.push(data.text);
      state('error', 'Runtime error', data.text);
      break;
    case 'stopped':
    case 'done':
      demo.ready = false;
      demo.pending = false;
      demo.intentPending = false;
      state('stopped', 'Worker stopped', 'Reload to start a new compiled actor.');
      break;
    default: break;
  }
};
worker.onerror = event => {
  demo.pending = false;
  demo.intentPending = false;
  demo.failed = true;
  demo.errors.push(event.message || 'Worker error');
  state('error', 'Worker error', demo.errors.at(-1));
};
runButton.addEventListener('click', run);
intentButton.addEventListener('click', () => { void request(); });
source.addEventListener('keydown', event => {
  if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) { event.preventDefault(); run(); }
});

// This is a read-only descriptor emitted by the compiled backend actor at boot.
// A missing or incompatible descriptor disables the intent, but never blocks
// purely local editing and rendering.
fetch('/api/contract', { credentials: 'same-origin', mode: 'same-origin', cache: 'no-store' })
  .then(async response => {
    if (!response.ok) throw new Error('contract HTTP ' + response.status);
    demo.codec = createIntentCodec(await response.json());
    state(verdict.dataset.state, verdict.textContent, diagnostic.textContent);
  })
  .catch(error => {
    demo.errors.push('Live intent unavailable: ' + String(error));
    $('#intent-contract').textContent = 'Unavailable; local preview still runs';
    state(verdict.dataset.state, verdict.textContent, diagnostic.textContent);
  });
