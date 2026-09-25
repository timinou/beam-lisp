// split-worker.mjs — runs the compiled BL CLIENT half in a module Worker.
//
// Thin transport only. It converts page messages into typed BL input
// (`H.enqueueData`) and BL `host/emit` values into plain JSON messages. It
// makes no decision: the view, the local reducer, the shared checks, pending
// state and rebasing are all the compiled BL (split-client.bl + the app).
//
// page → worker:  {kind:'hello'|'result'|'snapshot', frame}  server frames
//                 {kind:'event', event:[name, value?]}       one UI event
//                 {kind:'stop'}
// worker → page:  {kind:'ready'|'view'|'propose'|'trace'|'fatal'|'error', …}

import * as H from './host.mjs';
import { createCodec, encode, frameToBL } from './split-codec.mjs';

const params = new URL(import.meta.url).searchParams;
const app = /^[a-z][a-z0-9-]{0,31}$/.test(params.get('app') || '') ? params.get('app') : 'showcase';

let codec = null;
const EVENT_NAMES = new Set(['draft', 'submit', 'toggle', 'clear', 'filter']);

// A view tree is plain JSON EXCEPT its `:on-*` handler vectors, whose items
// keep their BL kind exactly: `{k:"open"}` is the keyword `:open`, a bare
// string stays a string. So the event a click sends back is the very value
// the BL view wrote, and text a user types can never become a keyword.
const HANDLER = /^on-/;
const tagItem = x => H.isKw(x) ? { k: H.kwName(x) } : encode(x);
function encodeView(x) {
  if (H.isVec(x)) return H.vecItems(x).map(encodeView);
  if (H.isBMap(x)) {
    const out = {};
    for (const k of H.listToArray(H.mapKeys(x))) {
      const name = H.kwName(k);
      const v = H.mapGet(x, k);
      out[name] = HANDLER.test(name) && H.isVec(v) ? H.vecItems(v).map(tagItem) : encodeView(v);
    }
    return out;
  }
  return encode(x);
}

H.setEmitter((topic, value) => {
  try {
    const v = topic === 'view' ? { revision: encode(H.mapGet(value, H.kw('revision'))),
                                   tree: encodeView(H.mapGet(value, H.kw('tree'))) }
                               : encode(value);
    postMessage({ kind: topic, value: v });
  } catch (error) { postMessage({ kind: 'error', text: String(error) }); }
});
// Anything the runtime prints (a crashed process, a scheduler report).
console.log = (...args) => postMessage({ kind: 'error', text: args.map(String).join(' ') });

// A UI event is a handler vector the BL view wrote (tagged as above), with at
// most one appended `{s: text}` for an input's current value.
function itemToBL(v) {
  if (v && typeof v === 'object' && typeof v.k === 'string' && /^[a-z][a-z0-9-]{0,31}$/.test(v.k)) return H.kw(v.k);
  if (v && typeof v === 'object' && typeof v.s === 'string' && v.s.length <= 256) return v.s;
  if (typeof v === 'string' && v.length <= 256) return v;
  if (Number.isSafeInteger(v) || typeof v === 'boolean') return v;
  throw new Error('UI event item is not a bounded scalar');
}
function eventToBL(event) {
  if (!Array.isArray(event) || event.length < 1 || event.length > 3 ||
      !(event[0] && EVENT_NAMES.has(event[0].k)))
    throw new Error('unknown UI event');
  return H.vec(event.map(itemToBL));
}

globalThis.onmessage = ({ data }) => {
  try {
    if (!data || typeof data !== 'object') return;
    if (data.kind === 'stop') { H.enqueueData('stop', ''); return; }
    if (data.kind === 'event') { H.enqueueData('event', eventToBL(data.event), { nodes: 4, depth: 1, text: 256 }); return; }
    if (!codec) throw new Error('contract not loaded');
    if (data.kind === 'hello') {
      H.enqueueData('hello', H.bmap([[H.kw('digest'), String(data.frame.digest)],
                                     [H.kw('revision'), data.frame.revision],
                                     [H.kw('board'), codec.decodeSnapshot(data.frame.board)]]));
      return;
    }
    if (data.kind === 'result' || data.kind === 'snapshot') { H.enqueueData(data.kind, frameToBL(codec, data.frame)); return; }
    if (data.kind === 'unreachable' && Number.isSafeInteger(data.request)) { H.enqueueData('unreachable', data.request); return; }
  } catch (error) {
    postMessage({ kind: 'error', text: String(error.message || error) });
  }
};

const contract = await (await fetch(`./out/${app}.contract.json`, { cache: 'no-store' })).json();
codec = createCodec(contract);
postMessage({ kind: 'contract', digest: codec.digest });
import(`./out/${app}-client.mjs`).catch(error => postMessage({ kind: 'fatal', value: { reason: String(error.message || error) } }));
