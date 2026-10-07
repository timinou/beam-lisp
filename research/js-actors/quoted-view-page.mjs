
// The page owns exactly two things: (1) writing the decoded view into fixed
// elements through text properties only, and (2) POSTing the ONE intent to the
// same-origin endpoint and reacting to the server's answer. The view's structure
// and every check are the BL actor's and the decoder's; nothing here re-implements
// a rule. No string from the Worker or the server is ever parsed as markup.
const OP_RE = /^[a-z][a-z0-9-]{0,31}$/;
const VERSION_RE = /^(0|[1-9][0-9]{0,15})$/;

const card = document.querySelector('#view-card');
const heading = document.querySelector('#view-heading');
const field = document.querySelector('#view-field');
const button = document.querySelector('#view-button');
const copy = document.querySelector('#view-text');
const status = document.querySelector('#status');
const statusText = document.querySelector('#status-text');
const errorBox = document.querySelector('#error');
const stopButton = document.querySelector('#stop');
const log = document.querySelector('#log');

const worker = new Worker(new URL('./quoted-view-worker.mjs', import.meta.url), { type: 'module' });

const demo = {
  state: 'booting',
  view: null,
  version: null,
  events: [],
  errors: [],
  lastResult: null,
  worker,
  request: null,
  stop: null,
};
window.quotedDemo = demo;

function note(kind, text) {
  demo.events.push({ kind, text, at: Date.now() });
  const row = document.createElement('li');
  row.dataset.kind = kind;
  row.textContent = kind + ': ' + text;
  log.append(row);
}

function showError(text) {
  demo.errors.push(text);
  errorBox.hidden = false;
  errorBox.textContent = text;
}

function clearError() {
  errorBox.hidden = true;
  errorBox.textContent = '';
}

function setState(state, text) {
  demo.state = state;
  status.dataset.state = state;
  statusText.textContent = text;
  button.disabled = !(state === 'ready' && typeof demo.version === 'string');
  stopButton.disabled = state === 'stopping' || state === 'stopped' || state === 'failed';
}

// Every dynamic value is written as text, never as markup. The card's id is a
// data attribute (assigned, not parsed), so it can never become an element or a
// second node.
function renderView(view) {
  heading.textContent = view.heading.text;
  field.textContent = view.field.name + ': ' + view.field.value;
  button.textContent = view.button.label;
  copy.textContent = view.text;
  card.dataset.cardId = view.card.id;
  demo.view = view;
  demo.version = VERSION_RE.test(view.field.value) ? view.field.value : null;
}

// The ONE request path. The button and `window.quotedDemo.request` both call it,
// so a test can drive exactly what a click drives. The server owns the version:
// this only forwards the canonical decimal the current view shows.
async function request(op, version) {
  if (demo.state === 'pending') {
    demo.lastResult = { ok: false, reason: 'busy' };
    return demo.lastResult;
  }
  if (demo.state === 'stopping' || demo.state === 'stopped' || demo.state === 'failed') {
    demo.lastResult = { ok: false, reason: 'state-' + demo.state };
    return demo.lastResult;
  }
  if (typeof op !== 'string' || !OP_RE.test(op)) {
    demo.lastResult = { ok: false, reason: 'malformed-op' };
    return demo.lastResult;
  }
  if (typeof version !== 'string' || !VERSION_RE.test(version)) {
    demo.lastResult = { ok: false, reason: 'malformed-version' };
    return demo.lastResult;
  }

  setState('pending', 'Sending ' + op + ' on version ' + version + '…');
  note('request', op + ' ' + version);

  let response = null;
  try {
    const res = await fetch('/api/intent', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ op, version }),
      credentials: 'same-origin',
      mode: 'same-origin',
      cache: 'no-store',
    });
    response = await res.json();
  } catch (error) {
    showError('Request failed: ' + String(error));
    note('error', String(error));
    setState('ready', 'Request failed · keeping version ' + version);
    demo.lastResult = { ok: false, reason: 'network-error' };
    return demo.lastResult;
  }

  // Accept ONLY an authorized increment carrying a safe integer version. The
  // version the actor is told to show is the SERVER's answer, never an optimistic
  // increment of the version the page already had.
  if (response !== null && response.ok === true && response.intent === 'increment' &&
      Number.isSafeInteger(response.version) && response.version >= 0 &&
      version === demo.version && response.version === Number(version) + 1) {
    note('accepted', 'server reports version ' + response.version);
    setState('pending', 'Waiting for the actor to render version ' + response.version + '…');
    worker.postMessage({ kind: 'event', topic: 'version', payload: String(response.version) });
    demo.lastResult = { ok: true, version: response.version };
    return demo.lastResult;
  }

  if (response !== null && response.ok === true) {
    showError('Server returned an inconsistent success. Reload to resynchronize.');
    note('error', 'inconsistent server response');
    setState('failed', 'Server response out of sync');
    demo.lastResult = { ok: false, reason: 'inconsistent-response' };
    return demo.lastResult;
  }
  const reason = (response !== null && typeof response.reason === 'string') ? response.reason : 'refused';
  showError('Server refused: ' + reason);
  note('refused', reason);
  setState('ready', 'Refused (' + reason + ') · keeping version ' + (demo.version === null ? '?' : demo.version));
  demo.lastResult = { ok: false, reason };
  return demo.lastResult;
}

function stop() {
  if (demo.state === 'stopped' || demo.state === 'stopping') return;
  note('stopping', 'stop requested');
  setState('stopping', 'Stopping actor…');
  worker.postMessage({ kind: 'event', topic: 'stop', payload: '' });
}

demo.request = request;
demo.stop = stop;

worker.onmessage = ({ data }) => {
  if (!data || typeof data.kind !== 'string') return;
  switch (data.kind) {
    case 'view':
      renderView(data.view);
      clearError();
      note('view', 'version ' + (demo.version === null ? '?' : demo.version));
      setState('ready', 'Ready · version ' + (demo.version === null ? '?' : demo.version));
      break;
    case 'refused':
      showError('The actor refused the version wire. ' + data.text);
      note('refused', data.text);
      setState('ready', 'Actor refused the wire · keeping version ' + (demo.version === null ? '?' : demo.version));
      break;
    case 'stopped':
      note('stopped', 'actor stopped');
      setState('stopped', 'Actor stopped');
      break;
    case 'done':
      note('done', 'worker finished');
      if (demo.state !== 'stopped') setState('stopped', 'Actor stopped');
      break;
    case 'error':
      showError(data.text);
      note('error', data.text);
      setState('failed', 'Worker error');
      break;
    case 'output':
      note('output', data.text);
      if (data.text.startsWith('actor runtime error')) {
        showError(data.text);
        setState('failed', 'Actor error');
      }
      break;
    default:
      break;
  }
};

worker.onerror = event => {
  const message = (event && event.message) ? event.message : 'Worker error';
  showError(message);
  note('error', message);
  setState('failed', 'Worker error');
};

button.addEventListener('click', () => {
  if (typeof demo.version === 'string') request('increment', demo.version);
});
stopButton.addEventListener('click', stop);
