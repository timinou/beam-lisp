// Browser transport only. The BL app chooses the input sink, supervisor,
// restart policy, message handling and every line of the visible ledger.
import * as H from './host.mjs';

console.log = (...args) => postMessage({ kind: 'output', text: args.join(' ') });
globalThis.onmessage = ({ data }) => {
  if (!data || data.kind !== 'event') return;
  try {
    H.enqueueInput(data.topic, data.payload);
  } catch (error) {
    postMessage({ kind: 'error', text: String(error) });
  }
};

try {
  await import('./out/super-demo.mjs');
  postMessage({ kind: 'done' });
} catch (error) {
  postMessage({ kind: 'error', text: String(error.stack || error) });
}
