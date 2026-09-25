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

const APP = 'showcase';
const $ = id => document.getElementById(id);
const appRoot = $('app');

const ATTRS = new Set(['class', 'type', 'value', 'placeholder', 'maxlength', 'disabled',
                       'aria-label', 'aria-pressed']);
const TAGS = new Set(['section', 'header', 'footer', 'nav', 'div', 'h1', 'h2', 'p', 'strong', 'small',
                      'span', 'ul', 'li', 'button', 'input']);
const EVENTS = { 'on-click': 'click', 'on-input': 'input', 'on-enter': 'keydown' };

const worker = new Worker(`./split-worker.mjs?app=${APP}`, { type: 'module' });
// Names this tab to the transport so the timeline can tell "another tab" from
// this tab's own echo. Metadata only: the authority never sees it.
const TAB = [...crypto.getRandomValues(new Uint8Array(8))].map(b => b.toString(16).padStart(2, '0')).join('');
const state = { handlers: new WeakMap(), rendered: 0, link: 'connecting', revision: null };

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
      const a = slot.actions.keydown;
      if (a && e.key === 'Enter') { e.preventDefault(); send(a); }
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
    return dom;
  });
  next.forEach((dom, i) => { if (el.childNodes[i] !== dom) el.insertBefore(dom, el.childNodes[i] || null); });
  while (el.childNodes.length > next.length) el.removeChild(el.lastChild);
}

function render(tree) {
  if (!isElement(tree)) throw new Error('view root is not an element');
  if (!appRoot.firstChild || appRoot.firstChild.tagName.toLowerCase() !== tree[0]) {
    appRoot.replaceChildren(create(tree));
  } else {
    patch(appRoot.firstChild, tree);
  }
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
  confirmed: v => ['server', `${v.op} committed → rev ${v.revision}`],
  'server-refused': v => ['server', `${v.op} refused: ${v.reason}`],
  rebased: v => ['browser', `${v.op} lost a race — re-checked against rev ${v.revision}, resent`],
  'rebase-refused': v => ['browser', `${v.op} no longer valid after rebase: ${v.reason}`],
  snapshot: v => ['server', `snapshot rev ${v.revision}${v.op ? ` (${v.op} from another tab)` : ''}`],
  unreachable: v => ['browser', `${v.op} dropped — no answer; board unchanged`],
};

// ── the link ─────────────────────────────────────────────────────────────────

function setLink(mode, text) {
  state.link = mode;
  const el = $('link');
  el.className = 'pill ' + (mode === 'live' ? 'live' : mode === 'down' ? 'down' : '');
  el.textContent = text;
}

async function propose(proposal) {
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
    setLink('down', 'offline');
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
    if (state.revision === null) { worker.postMessage({ kind: 'hello', frame }); log('server', `hello rev ${frame.revision}`); }
    else worker.postMessage({ kind: 'snapshot', frame });
    setLink('live', 'live · rev ' + frame.revision);
  });
  events.addEventListener('snapshot', e => {
    const { by, ...frame } = JSON.parse(e.data);
    // this tab's own commit reaches it through the POST result; the echo is
    // skipped so the timeline shows each commit once
    if (by !== TAB) worker.postMessage({ kind: 'snapshot', frame });
    setLink('live', 'live · rev ' + frame.revision);
  });
  events.onerror = () => setLink('down', 'reconnecting…');
}

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
  title.textContent = `${f.name}  (showcase.bl:${f.line}) → ${f.placement}`;
  box.append(title,
    evidenceLine('graph', f.evidence.graph),
    evidenceLine('effects', f.evidence.effects),
    evidenceLine('abi', f.evidence.abi),
    evidenceLine('private', f.evidence.private ? 'declared :private' : 'no'),
    evidenceLine('portable', f.portable ? 'yes' : `no — ${f.why.reason}${f.why.detail ? ' ' + f.why.detail : ''}`),
    evidenceLine('calls', f.calls.length ? f.calls.join(', ') : '—', 'plain'));
}

async function explain() {
  const [manifest, contract] = await Promise.all([
    fetch(`./out/${APP}.split.json`, { cache: 'no-store' }).then(r => r.json()),
    fetch(`./out/${APP}.contract.json`, { cache: 'no-store' }).then(r => r.json()),
  ]);
  const lanes = { client: [], shared: [], server: [] };
  for (const f of manifest.functions) if (lanes[f.placement]) lanes[f.placement].push(f);
  for (const [lane, fns] of Object.entries(lanes)) {
    $('n-' + lane).textContent = fns.length;
    $('lane-' + lane).replaceChildren(...fns.map(f => {
      const b = document.createElement('button');
      b.className = 'fn';
      b.type = 'button';
      b.textContent = f.name;
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

explain().catch(error => { $('evidence').textContent = 'manifest unavailable: ' + error.message; });

// A test hook, read-only: the page's own state, never a way to change the app.
window.splitShowcase = Object.freeze({
  get revision() { return state.revision; },
  get link() { return state.link; },
  get renders() { return state.rendered; },
});
