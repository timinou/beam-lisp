'use strict';
const token = document.querySelector('meta[name="continuity-token"]').content;
const byId = id => document.getElementById(id);
const text = (id, value) => { byId(id).textContent = value; };
const money = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });
const samples = [];
let state, actor, busy = false, traffic = true, stopped = false;
const labels = { ready: 'Ready', running: 'In progress', blocked: 'Refused', waiting: 'Draining', completed: 'Complete', failed: 'Failed' };
const colors = { 1: '#a6d8b8', 2: '#dac286', 3: '#e59a82', 4: '#a2c9e4' };

async function post(path, extra = {}) {
  const response = await fetch(path, { method: 'POST', headers: { 'x-continuity-token': token, ...extra } });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}
function chart() {
  const cap = Math.max(25, ...samples.map(s => s.ms));
  const points = samples.map((s, i) => [samples.length === 1 ? 0 : i * 740 / 79, 120 - Math.min(1, s.ms / cap) * 105]);
  byId('request-line').setAttribute('d', points.map(([x, y], i) => `${i ? 'L' : 'M'}${x.toFixed(1)} ${y.toFixed(1)}`).join(' '));
  byId('request-points').replaceChildren(...points.map(([x, y], i) => {
    const point = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    point.setAttribute('cx', x); point.setAttribute('cy', y); point.setAttribute('r', 2.6);
    point.setAttribute('fill', colors[samples[i].version] || colors[1]);
    return point;
  }));
  text('chart-window', `${samples.length} samples · ${cap.toFixed(0)} ms scale`);
}
function render(s) {
  state = s;
  actor ||= s.actor;
  text('orders', s.orders.toLocaleString()); text('revenue', money.format(s.cents / 100));
  text('version', `v${s.version}`); text('actor', s.actor); text('vm', s.vm);
  text('same-actor', actor === s.actor ? 'Same PID' : 'PID changed');
  text('client', `protocol v${s['client-version']}`); text('client-state', s.drained ? 'Current' : 'Retained');
  text('owners', `${s.owners ?? '—'} observed roles`);
  text('job', s.job.state === 'done' ? `Finished with v${s.job.version} code` : 'Pending · accepted on v1');
  text('job-state', s.job.state === 'done' ? 'Done' : 'Retained');
  text('requests', s.requests.toLocaleString()); text('errors', s.errors);
  text('latency', s['p95-ms'] == null ? '—' : `${s['p95-ms'].toFixed(1)} ms`);
  text('deployment-title', s.label); text('outcome', s.recovered && s.phase === 'recover' ? 'Recovered' : labels[s.state] || s.state);
  byId('outcome').dataset.state = s.state;
  const stages = new Map();
  for (const event of s.events) stages.set(event.phase, event.state);
  document.querySelectorAll('[data-phase]').forEach(node => { node.dataset.state = stages.get(node.dataset.phase) || 'pending'; });
  for (const kind of ['message', 'state', 'reply', 'data']) {
    const node = document.querySelector(`[data-check="${kind}"]`);
    const status = s[`${kind}-check`] || 'pending';
    node.dataset.state = status;
    node.querySelector('.check-mark').textContent = status === 'passed' ? '✓' : status === 'blocked' ? '×' : '○';
    node.setAttribute('aria-label', `${kind}: ${status}`);
  }
  byId('recovery').hidden = s.phase !== 'recover' && !s.recovered;
  text('recovery-title', s.recovered ? 'Recovered. Every receipt kept.' : 'Health check failed. Recovering.');
  byId('graphs').replaceChildren(...s.graphs.sort((a, b) => a.version - b.version).map(g => {
    const node = document.createElement('div'); node.className = 'graph';
    node.dataset.state = g.retired ? 'retired' : g.version === s.version ? 'current' : 'retained';
    const title = document.createElement('strong'); title.textContent = `v${g.version}`;
    const detail = document.createElement('small'); detail.textContent = g.retired ? 'Retired' : g.version === s.version ? 'Serving' : g.version > s.version ? 'Prepared' : 'Retained';
    node.append(title, detail); return node;
  }));
  byId('events').replaceChildren(...s.events.slice(-5).reverse().map(event => {
    const item = document.createElement('li'); item.dataset.state = event.state;
    const time = document.createElement('time'); time.textContent = new Date(event.at).toLocaleTimeString('en-GB');
    const label = document.createElement('span'); label.textContent = event.label;
    item.append(time, label); return item;
  }));
  byId('timings').replaceChildren(...[['Publication', s.timings.commit], ['Recovery', s.timings.recovery]].flatMap(([label, value]) => {
    const dt = document.createElement('dt'); dt.textContent = label;
    const dd = document.createElement('dd'); dd.textContent = value == null ? '—' : `${value.toFixed(2)} ms`;
    return [dt, dd];
  }));
  updateButtons();
}
function updateButtons() {
  document.querySelectorAll('[data-scenario]').forEach(button => {
    const action = button.dataset.scenario;
    const allowed = state && (action === 'upgrade' || action === 'bad-message' || action === 'bad-state' ? state.version === 1
      : action === 'recover' ? state.version === 2 && !state.drained
      : action === 'drain' ? state.version >= 2 && !state.drained : true);
    button.disabled = busy || !allowed;
  });
}
document.querySelectorAll('[data-scenario]').forEach(button => button.addEventListener('click', async () => {
  busy = true; updateButtons();
  try { await post(`/api/scenario/${button.dataset.scenario}`); }
  catch (error) { text('deployment-title', `Scenario unavailable · ${error.message}`); }
  finally { busy = false; await refresh(); updateButtons(); }
}));
byId('traffic-toggle').addEventListener('click', () => {
  traffic = !traffic;
  byId('traffic-toggle').setAttribute('aria-pressed', String(traffic));
  byId('traffic-toggle').textContent = traffic ? 'Ⅱ Pause traffic' : '▶ Resume traffic';
});
async function refresh() {
  try {
    const response = await fetch('/api/state', { cache: 'no-store' });
    if (!response.ok) throw new Error('State unavailable');
    render(await response.json());
    byId('connection').dataset.state = 'live'; text('connection', 'Live');
  } catch (_) {
    byId('connection').dataset.state = 'offline'; text('connection', 'Reconnecting');
  }
}
async function send() {
  if (traffic && state) {
    const version = state.version;
    try {
      const result = await post('/api/order', { 'x-order-id': crypto.randomUUID() });
      samples.push({ ms: result['elapsed-ms'], version }); if (samples.length > 80) samples.shift(); chart();
    } catch (_) { /* Server counts refusal; network failures are shown separately. */
      byId('connection').dataset.state = 'offline'; text('connection', 'Request unconfirmed');
    }
  }
  if (!stopped) setTimeout(send, 150);
}
async function observe() { await refresh(); if (!stopped) setTimeout(observe, 300); }
window.addEventListener('pagehide', () => { stopped = true; });
observe(); send();
