// The page displays typed Worker output only; it neither parses BL nor executes
// source. No POST/fetch occurs on Run. All user-influenced text uses textContent.
const $ = selector => document.querySelector(selector);
const source = $('#source');
const runButton = $('#run');
const verdict = $('#verdict');
const diagnostic = $('#diagnostic');
const worker = new Worker(new URL('./quoted-playground-worker.mjs', import.meta.url), { type: 'module' });

const demo = { ready: false, pending: false, view: null, manifest: null, refusal: null, errors: [], messages: [], run, worker };
window.quotedPlayground = demo;

function state(kind, label, detail) {
  verdict.dataset.state = kind;
  verdict.textContent = label;
  diagnostic.dataset.kind = kind;
  diagnostic.textContent = detail;
  runButton.disabled = !demo.ready || demo.pending;
}
function run() {
  if (!demo.ready || demo.pending) return false;
  demo.pending = true;
  demo.refusal = null;
  state('running', 'Evaluating', 'Fencing this form inside the browser Worker…');
  worker.postMessage({ kind: 'run', source: source.value });
  return true;
}
function showView(view) {
  $('#title').textContent = view.heading.text;
  $('#field').textContent = view.field.name + ': ' + view.field.value;
  $('#intent').textContent = view.button.label;
  $('#copy').textContent = view.text;
  $('#render').dataset.cardId = view.card.id;
  demo.view = view;
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
      $('#field-contract').textContent = ':' + data.manifest.dynamic.field + ' · sample version 7 in this Worker';
      $('#intent-contract').textContent = ':' + data.manifest.intent.op + ' · ' + data.manifest.intent.authority + ' owns validation/commit';
      state('running', 'Eligible · rendering', 'Closed data form admitted. Compiled BL evaluator is rendering it locally…');
      break;
    case 'view':
      demo.pending = false;
      showView(data.view);
      state('eligible', 'Frontend eligible', 'Rendered by compiled Beam Lisp in this browser Worker. No source or view request was sent to the backend.');
      break;
    case 'refused':
      demo.pending = false;
      demo.refusal = data;
      state('refused', 'Fence refused', data.reason + ' at ' + data.line + ':' + data.column + ' (' + data.path + '). Previous preview stays unchanged.');
      break;
    case 'error':
      demo.pending = false;
      demo.errors.push(data.text);
      state('error', 'Runtime error', data.text);
      break;
    case 'stopped':
    case 'done':
      demo.ready = false;
      demo.pending = false;
      state('stopped', 'Worker stopped', 'Reload to start a new compiled actor.');
      break;
    default: break;
  }
};
worker.onerror = event => {
  demo.pending = false;
  demo.errors.push(event.message || 'Worker error');
  state('error', 'Worker error', demo.errors.at(-1));
};
runButton.addEventListener('click', run);
source.addEventListener('keydown', event => {
  if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) { event.preventDefault(); run(); }
});
