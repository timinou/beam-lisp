// showcase-page.mjs — the page around a compiled split app.
//
// Three jobs, none of them app policy:
//   1. RENDER the BL view tree the Worker emits into real DOM with a small keyed
//      reconciler (focus and caret survive, rows animate in once). Text reaches
//      the DOM only through `textContent`; attributes through a closed allowlist.
//   2. LINK the Worker to the server: SSE frames in, `POST /api/intent` out,
//      the result (success or refusal) handed back to the BL client unchanged.
//   3. EXPLAIN: the placement manifest, the contract and a live timeline of
//      where each step ran — all read from the generated artifacts.

const $ = id => document.getElementById(id);
const appRoot = $('app');

// One app per process: the shell says which. The Worker, the manifest and the
// contract are all keyed by this name, so it is resolved before anything else.
const APP = await fetchAppName();

const ATTRS = new Set(['class', 'type', 'value', 'placeholder', 'maxlength', 'disabled',
                       'aria-label', 'aria-pressed',
                       'title', 'role', 'aria-expanded', 'aria-level', 'aria-current', 'data-depth']);

async function fetchAppName() {
  try {
    const info = await (await fetch('/api/app', { cache: 'no-store' })).json();
    if (info && /^[a-z][a-z0-9-]{0,31}$/.test(info.app)) return info.app;
  } catch { /* fall through */ }
  return 'showcase';
}

// A keyed row that MOVES (a re-sort) glides from where it was: FLIP.
function rememberRows() {
  const at = new Map();
  for (const li of appRoot.querySelectorAll('li[data-k]')) at.set(li.dataset.k, li.getBoundingClientRect().top);
  return at;
}
function glideRows(before) {
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  for (const li of appRoot.querySelectorAll('li[data-k]')) {
    const was = before.get(li.dataset.k);
    if (was === undefined) continue;
    const dy = was - li.getBoundingClientRect().top;
    if (Math.abs(dy) < 1) continue;
    li.animate([{ transform: `translateY(${dy}px)` }, { transform: 'none' }], { duration: 220, easing: 'ease-out' });
  }
}
const TAGS = new Set(['section', 'header', 'footer', 'nav', 'div', 'h1', 'h2', 'p', 'strong', 'small',
                      'span', 'ul', 'li', 'button', 'input',
                      'ol', 'h3', 'label', 'em', 'code', 'kbd', 'article', 'aside']);
const EVENTS = { 'on-click': 'click', 'on-input': 'input', 'on-enter': 'keydown', 'on-escape': 'escape' };

const worker = new Worker(`./split-worker.mjs?app=${APP}`, { type: 'module' });
// Names this tab to the transport so the timeline can tell "another tab" from
// this tab's own echo. Metadata only: the authority never sees it.
const TAB = [...crypto.getRandomValues(new Uint8Array(8))].map(b => b.toString(16).padStart(2, '0')).join('');
const state = { handlers: new WeakMap(), rendered: 0, link: 'connecting', revision: null, source: APP + '.bl' };

// ── rendering ────────────────────────────────────────────────────────────────

function isElement(node) {
  return Array.isArray(node) && typeof node[0] === 'string' && TAGS.has(node[0]) &&
         node.length >= 2 && node[1] !== null && typeof node[1] === 'object' && !Array.isArray(node[1]);
}

// A child list flattens nested vectors (a `mapv` of rows) and drops "".
function childrenOf(node) {
  const out = [];
  const walk = xs => {
    for (const x of xs) {
      if (x === '' || x === null) continue;
      if (Array.isArray(x) && !isElement(x)) walk(x);
      else out.push(x);
    }
  };
  walk(node.slice(2));
  return out;
}

function keyOf(node, i) {
  return isElement(node) && typeof node[1].key === 'string' ? 'k:' + node[1].key
    : (isElement(node) ? 'e:' + node[0] : 't') + ':' + i;
}

function create(node) {
  if (!isElement(node)) return document.createTextNode(String(node));
  const el = document.createElement(node[0]);
  if (state.rendered > 0) el.dataset.fresh = '1';
  patch(el, node);
  // `:autofocus true` focuses an element once, when the view first creates it
  // (an inline editor that just opened) — never on later renders
  if (node[1].autofocus === true) queueMicrotask(() => el.focus());
  return el;
}

function send(event) { worker.postMessage({ kind: 'event', event }); }

function bind(el, attrs) {
  const actions = {};
  for (const [name, type] of Object.entries(EVENTS)) if (Array.isArray(attrs[name])) actions[type] = attrs[name];
  let slot = state.handlers.get(el);
  if (!slot) {
    slot = { actions: {} };
    state.handlers.set(el, slot);
    el.addEventListener('click', () => { const a = slot.actions.click; if (a) send(a); });
    el.addEventListener('input', () => { const a = slot.actions.input; if (a) send([...a, { s: el.value }]); });
    el.addEventListener('keydown', e => {
      const a = e.key === 'Enter' ? slot.actions.keydown : e.key === 'Escape' ? slot.actions.escape : null;
      if (a) { e.preventDefault(); send(a); }
    });
  }
  slot.actions = actions;
}

function patch(el, node) {
  const attrs = node[1];
  for (const name of ATTRS) {
    const v = attrs[name];
    if (name === 'value') { if (el.value !== String(v ?? '')) el.value = String(v ?? ''); continue; }
    if (name === 'disabled') { el.disabled = v === true; continue; }
    if (v === undefined || v === null || v === false && !name.startsWith('aria-')) el.removeAttribute(name);
    else el.setAttribute(name, String(v));
  }
  bind(el, attrs);
  const kids = childrenOf(node);
  const existing = new Map();
  [...el.childNodes].forEach((c, i) => existing.set(c.__key || 't:' + i, c));
  const next = kids.map((k, i) => {
    const key = keyOf(k, i);
    let dom = existing.get(key);
    if (dom && isElement(k) && dom.nodeType === 1 && dom.tagName.toLowerCase() === k[0]) {
      existing.delete(key);
      delete dom.dataset.fresh;
      patch(dom, k);
    } else if (dom && !isElement(k) && dom.nodeType === 3) {
      existing.delete(key);
      if (dom.textContent !== String(k)) dom.textContent = String(k);
    } else {
      dom = create(k);
    }
    dom.__key = key;
    if (dom.nodeType === 1 && isElement(k) && typeof k[1].key === 'string') dom.dataset.k = k[1].key;
    return dom;
  });
  next.forEach((dom, i) => { if (el.childNodes[i] !== dom) el.insertBefore(dom, el.childNodes[i] || null); });
  while (el.childNodes.length > next.length) el.removeChild(el.lastChild);
}

function render(tree) {
  if (!isElement(tree)) throw new Error('view root is not an element');
  const before = rememberRows();
  if (!appRoot.firstChild || appRoot.firstChild.tagName.toLowerCase() !== tree[0]) {
    appRoot.replaceChildren(create(tree));
  } else {
    patch(appRoot.firstChild, tree);
  }
  glideRows(before);
  state.rendered++;
}

// ── the timeline ─────────────────────────────────────────────────────────────

const t0 = performance.now();
function log(where, text) {
  const li = document.createElement('li');
  const t = document.createElement('span'); t.className = 't';
  t.textContent = ((performance.now() - t0) / 1000).toFixed(2) + 's';
  const w = document.createElement('span'); w.className = 'where ' + where; w.textContent = where;
  const m = document.createElement('span'); m.textContent = text;
  li.append(t, w, m);
  const list = $('timeline');
  list.prepend(li);
  while (list.childNodes.length > 60) list.removeChild(list.lastChild);
}

const TRACE = {
  local: v => ['browser', `local ${v.event} — no network`],
  proposed: v => ['browser', `${v.op} checked here, sent @rev ${v.revision}${v.retry ? ' (rebased)' : ''}`],
  'client-refused': v => ['browser', `${v.op} refused before sending: ${v.reason}`],
  confirmed: v => ['server', v.duplicate ? `${v.op} was already committed — answered once, not applied twice`
                                         : `${v.op} committed → rev ${v.revision}`],
  diverged: v => ['browser', `${v.op}: the server's result differs from the prediction — showing the server's`],
  queued: v => ['browser', `${v.op} queued offline (${v.count} waiting) — shown now, sent when back online`],
  online: v => ['browser', `back online — sending ${v.count} queued intent${v.count === 1 ? '' : 's'} in order`],
  'server-refused': v => ['server', `${v.op} refused: ${v.reason}`],
  rebased: v => ['browser', `${v.op} lost a race — re-checked against rev ${v.revision}, resent`],
  'rebase-refused': v => ['browser', `${v.op} no longer valid after rebase: ${v.reason}`],
  snapshot: v => ['server', `snapshot rev ${v.revision}${v.op ? ` (${v.op} from another tab)` : ''}`],

};

// ── the link ─────────────────────────────────────────────────────────────────

function setLink(mode, text) {
  state.link = mode;
  const el = $('link');
  el.className = 'pill ' + (mode === 'live' ? 'live' : mode === 'down' ? 'down' : '');
  el.textContent = text;
}

// OFFLINE. The tab is offline when its event stream is down — or when the user
// flips "Go offline", which closes this tab's stream and stops sending: the
// same transport state a dropped connection produces, chosen on purpose for
// a demo. The BL client is told either way; it queues, and sends in order when
// it hears `online`.
let offline = false;
function goOffline(why) {
  if (offline) return;
  offline = true;
  worker.postMessage({ kind: 'offline' });
  setLink('down', why);
}
function goOnline() {
  if (!offline) return;
  offline = false;
  worker.postMessage({ kind: 'online' });
}

async function propose(proposal) {
  if (offline) { worker.postMessage({ kind: 'unreachable', request: proposal.request }); return; }
  let body;
  try {
    const r = await fetch('/api/intent', { method: 'POST', headers: { 'content-type': 'application/json', 'x-split-tab': TAB },
                                           body: JSON.stringify(proposal) });
    body = await r.json();
  } catch {
    body = null;
  }
  if (!body || typeof body.revision !== 'number' || !body.board) {
    // No authoritative answer: tell the BL client the request failed without
    // inventing a board — it keeps the last confirmed one.
    log('wire', `${proposal.op}: server unreachable`);
    goOffline('offline');
    worker.postMessage({ kind: 'unreachable', request: proposal.request });
    return;
  }
  log('wire', `${proposal.op} ← ${body.ok ? 'ok' : body.reason}`);
  worker.postMessage({ kind: 'result', frame: { ...body, request: proposal.request } });
}

let events = null;
function connect() {
  events = new EventSource('/api/events');
  events.addEventListener('hello', e => {
    const frame = JSON.parse(e.data);
    if (state.revision === null) { worker.postMessage({ kind: 'hello', frame, tab: TAB }); log('server', `hello rev ${frame.revision}`); }
    else worker.postMessage({ kind: 'snapshot', frame });
    setLink('live', 'live · rev ' + frame.revision);
    goOnline();
  });
  events.addEventListener('snapshot', e => {
    const { by, ...frame } = JSON.parse(e.data);
    // this tab's own commit reaches it through the POST result; the echo is
    // skipped so the timeline shows each commit once
    if (by !== TAB) worker.postMessage({ kind: 'snapshot', frame });
    setLink('live', 'live · rev ' + frame.revision);
  });
  events.onerror = () => { if (!simulated) goOffline('reconnecting…'); };
}

let simulated = false;
$('offline-toggle').addEventListener('click', () => {
  simulated = !simulated;
  $('offline-toggle').textContent = simulated ? 'Go online' : 'Go offline';
  $('offline-toggle').setAttribute('aria-pressed', String(simulated));
  if (simulated) { events.close(); goOffline('offline'); }
  else connect();
});

// ── the Worker ───────────────────────────────────────────────────────────────

worker.onmessage = ({ data }) => {
  const v = data.value;
  switch (data.kind) {
    case 'contract':
      $('digest').textContent = 'contract ' + data.digest.slice(0, 12);
      return;
    case 'ready':
      connect();
      return;
    case 'view': {
      const prev = state.revision;
      state.revision = v.revision;
      render(v.tree);
      if (prev !== null && prev !== v.revision) {
        appRoot.classList.remove('flash'); void appRoot.offsetWidth; appRoot.classList.add('flash');
      }
      return;
    }
    case 'propose':
      propose(v);
      return;
    case 'trace': {
      const f = TRACE[v.step];
      if (f) log(...f(v));
      return;
    }
    case 'fatal':
      appRoot.replaceChildren(Object.assign(document.createElement('p'),
        { className: 'fatal', textContent: 'Client stopped: ' + v.reason }));
      return;
    case 'error':
      log('browser', 'error: ' + data.text);
      return;
  }
};
worker.onerror = e => log('browser', 'worker error: ' + e.message);

// ── the explainer ────────────────────────────────────────────────────────────

// tone: 'verdict' colors ok/refusal; 'plain' is information, never a verdict
function evidenceLine(k, v, tone = 'verdict') {
  const row = document.createElement('div');
  const key = document.createElement('span'); key.className = 'k'; key.textContent = k.padEnd(9);
  const val = document.createElement('span');
  val.className = tone === 'plain' ? '' : v === 'ok' || v === 'yes' ? 'ok' : v === 'no' ? '' : 'no';
  val.textContent = v;
  row.append(key, val);
  return row;
}

function showEvidence(f, btn) {
  document.querySelectorAll('.fn.sel').forEach(b => b.classList.remove('sel'));
  btn.classList.add('sel');
  const box = $('evidence');
  box.replaceChildren();
  const title = document.createElement('div');
  title.textContent = `${f.name}  (${state.source}:${f.line}) → ${f.placement}`;
  box.append(title,
    evidenceLine('graph', f.evidence.graph),
    evidenceLine('effects', f.evidence.effects),
    evidenceLine('abi', f.evidence.abi),
    evidenceLine('values', f.evidence.values),
    evidenceLine('role', [f.evidence['calls-values'] ? 'calls function values' : '',
                          f.evidence['used-as-value'] ? 'used as a value' : ''].filter(Boolean).join(' · ') || 'first-order', 'plain'),
    evidenceLine('recurs', f.evidence.recursion ? `yes — finite by ${f.evidence.recursion}` : 'no', 'plain'),
    evidenceLine('private', f.evidence.private ? 'declared :private' : 'no'),
    evidenceLine('portable', f.portable ? 'yes' : `no — ${f.why.reason}${f.why.detail ? ' ' + f.why.detail : ''}`),
    evidenceLine('calls', f.calls.length ? f.calls.join(', ') : '—', 'plain'));
}

async function explain() {
  const [manifest, contract] = await Promise.all([
    fetch(`./out/${APP}.split.json`, { cache: 'no-store' }).then(r => r.json()),
    fetch(`./out/${APP}.contract.json`, { cache: 'no-store' }).then(r => r.json()),
  ]);
  state.source = (typeof manifest.source === 'string' && manifest.source.split('/').pop()) || APP + '.bl';
  const lanes = { client: [], shared: [], server: [] };
  for (const f of manifest.functions) if (lanes[f.placement]) lanes[f.placement].push(f);
  for (const [lane, fns] of Object.entries(lanes)) {
    $('n-' + lane).textContent = fns.length;
    $('lane-' + lane).replaceChildren(...fns.map(f => {
      const b = document.createElement('button');
      b.className = 'fn';
      b.type = 'button';
      b.append(Object.assign(document.createElement('span'), { className: 'name', textContent: f.name }));
      const badge = (cls, text) => Object.assign(document.createElement('span'), { className: 'badge ' + cls, textContent: text });
      if (f.evidence['calls-values']) b.append(badge('calls', 'calls values'));
      if (f.evidence['used-as-value']) b.append(badge('value', 'a value'));
      if (f.evidence.recursion) b.append(badge('rec', 'recursion: ' + f.evidence.recursion));
      if (!f.portable) {
        const why = document.createElement('div');
        why.className = 'why';
        why.textContent = f.why.reason === 'reaches' ? `reaches ${f.why.detail}` : f.why.reason;
        b.append(why);
      }
      b.addEventListener('click', () => showEvidence(f, b));
      return b;
    }));
  }
  const kb = n => (n / 1024).toFixed(0) + ' KB';
  $('bundle-stats').textContent =
    `browser gets ${manifest.bundles.client['app-functions']} of ${manifest.functions.length} fns · ` +
    `${kb(manifest.bundles.client.bytes)} client / ${kb(manifest.bundles.server.bytes)} server`;
  const { digest, ...body } = contract;
  $('contract').textContent = JSON.stringify(body, null, 2);
  $('contract-file').textContent = `out/${APP}.contract.json · sha256 ${digest.slice(0, 12)}…`;
}

// ── the page metadata ──────────────────────────────────────────────────────

// Tiny markup for ledes and hints: `code` → <code>, **bold** → <b>. Nodes are
// built from text, never parsed as HTML.
function markup(text) {
  const frag = document.createDocumentFragment();
  const re = /`([^`]+)`|\*\*([^*]+)\*\*/g;
  let last = 0, m;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) frag.append(text.slice(last, m.index));
    const el = document.createElement(m[1] !== undefined ? 'code' : 'b');
    el.textContent = m[1] ?? m[2];
    frag.append(el);
    last = re.lastIndex;
  }
  if (last < text.length) frag.append(text.slice(last));
  return frag;
}

async function describe() {
  let page = null;
  try { page = await (await fetch('./app.page.json', { cache: 'no-store' })).json(); }
  catch { /* an app may ship no metadata: the shell falls back to its name */ }
  const title = page && typeof page.title === 'string' && page.title ? page.title : APP;
  document.title = title;
  const h1 = document.querySelector('.top h1');
  if (h1) h1.textContent = title;
  const lede = document.querySelector('.top .lede');
  if (lede) lede.replaceChildren(markup(page && typeof page.lede === 'string' ? page.lede : ''));
  const hints = $('hints');
  if (hints) {
    const list = page && Array.isArray(page.hints) ? page.hints.filter(h => typeof h === 'string') : [];
    hints.replaceChildren(...list.map(h => {
      const p = document.createElement('p');
      p.className = 'hint';
      p.append(markup(h));
      return p;
    }));
  }
}

// ── the explainer toggle ───────────────────────────────────────────────────
// The side column is shown by default; the choice survives a reload.
const EXPLAIN_KEY = 'split-explain';
const mainEl = document.querySelector('main');
const explainButton = $('explain-toggle');
function setExplained(shown) {
  mainEl.classList.toggle('explain-hidden', !shown);
  explainButton.textContent = shown ? 'Hide' : 'How it was built';
  explainButton.setAttribute('aria-expanded', String(shown));
  try { localStorage.setItem(EXPLAIN_KEY, shown ? 'shown' : 'hidden'); } catch { /* private mode */ }
}
let explainShown = true;
try { explainShown = localStorage.getItem(EXPLAIN_KEY) !== 'hidden'; } catch { /* default shown */ }
setExplained(explainShown);
explainButton.addEventListener('click', () => setExplained(mainEl.classList.contains('explain-hidden')));

describe().catch(() => {});

explain().catch(error => { $('evidence').textContent = 'manifest unavailable: ' + error.message; });

// A test hook, read-only: the page's own state, never a way to change the app.
window.splitShowcase = Object.freeze({
  get revision() { return state.revision; },
  get link() { return state.link; },
  get renders() { return state.rendered; },
});
