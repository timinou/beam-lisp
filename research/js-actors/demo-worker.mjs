// Transport only: source receives, scheduling and replies are defined in BL.
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
  // This import remains pending while a BL actor waits for future UI events.
  await import('./out/demo.mjs');
  postMessage({ kind: 'done' });
} catch (error) {
  postMessage({ kind: 'error', text: String(error.stack || error) });
}
