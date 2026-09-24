// No exception policy here: this Worker only forwards BL output and the result
// of importing a deliberately failing BL app. Source frames come from BL/ANF.
console.log = (...args) => postMessage({ kind: 'output', text: args.join(' ') });
try {
  await import('./out/trace-demo.mjs');
  postMessage({ kind: 'unexpected-success' });
} catch (error) {
  postMessage({ kind: 'ended', text: String(error) });
}
