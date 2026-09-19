// connect.spec.js — the socket lifecycle defaults, proven in a real browser.
//
// client.spec.js proves the DIFFER (ops → DOM). This proves the other half of
// priv/lib/live/client.js: connect() itself — the heartbeat that holds a quiet
// page under the server's 120s idle timeout (web/upgrade), and the
// auto-reconnect that brings a culled socket back. No server is started: a
// FakeWebSocket stands in, so what is asserted is the client's behaviour given
// the DEFAULTS the apps rely on (a shell passing no opts) plus the two opt-outs.
//
// Run:  cd test/browser && npx playwright test connect.spec.js

const { test, expect } = require("@playwright/test");
const fs = require("fs");
const path = require("path");

const clientJs = fs.readFileSync(
  path.join(__dirname, "../../priv/lib/live/client.js"),
  "utf8"
);

// a WebSocket that never talks to a server. Every instance is recorded, opens
// on the next tick, and close() fires onclose synchronously — so a test can
// close one socket and watch a fresh one appear (or not) with the real timers.
const FAKE = `
window.__sockets = [];
window.WebSocket = function (url) {
  var self = this;
  this.url = url; this.sent = []; this.readyState = 0;
  window.__sockets.push(this);
  setTimeout(function () { self.readyState = 1; if (self.onopen) self.onopen(); }, 0);
};
window.WebSocket.CONNECTING = 0;
window.WebSocket.OPEN = 1;
window.WebSocket.CLOSING = 2;
window.WebSocket.CLOSED = 3;
window.WebSocket.prototype.send = function (d) { this.sent.push(d); };
window.WebSocket.prototype.close = function () {
  this.readyState = 3;
  if (this.onclose) this.onclose();
};
`;

async function boot(page, opts) {
  await page.setContent('<div id="live-root"></div>');
  await page.addScriptTag({ content: FAKE });
  await page.addScriptTag({ content: clientJs });
  await page.evaluate(
    (o) => window.Live.connect(Object.assign(
      { root: document.getElementById("live-root"), url: "ws://fake/ws" }, o)),
    opts || {}
  );
}

const pingsOf = (page) =>
  page.evaluate(() => window.__sockets.map((s) => s.sent.filter((d) => d === '["ping"]').length));

// ── the heartbeat ─────────────────────────────────────────────────────

test("heartbeat: a ['ping'] frame per heartbeatMs, and no stray traffic", async ({ page }) => {
  await boot(page, { heartbeatMs: 40 });
  await page.waitForTimeout(300);
  const counts = await pingsOf(page);
  expect(counts.length).toBe(1);
  expect(counts[0]).toBeGreaterThanOrEqual(2);   // ~7 in 300ms; >=2 is the claim
  // every frame it sent is the ping (nothing else is invented on the wire)
  const all = await page.evaluate(() => window.__sockets[0].sent);
  expect(all.every((d) => d === '["ping"]')).toBe(true);
});

test("heartbeat: 0 disables it", async ({ page }) => {
  await boot(page, { heartbeatMs: 0 });
  await page.waitForTimeout(300);
  expect((await pingsOf(page))[0]).toBe(0);
});

// The default cadence is the one that has to beat the server's 120s idle
// timeout, so it is pinned by observation, not by reading a constant: 30s.
test("heartbeat: the DEFAULT is 30s — quiet at 1s, beating by 31s", async ({ page }) => {
  test.setTimeout(45000);
  await boot(page);                       // no opts — what every shell passes
  await page.waitForTimeout(1000);
  expect((await pingsOf(page))[0]).toBe(0);
  await page.waitForFunction(
    () => window.__sockets[0].sent.filter((d) => d === '["ping"]').length >= 1,
    null, { timeout: 33000 });
  expect((await pingsOf(page))[0]).toBeGreaterThanOrEqual(1);
});

// ── reconnect ─────────────────────────────────────────────────────────

test("reconnect: a closed socket comes back with no opts (the default)", async ({ page }) => {
  await boot(page);                       // no opts
  await page.waitForFunction(() => window.__sockets.length === 1 && window.__sockets[0].readyState === 1);
  await page.evaluate(() => window.Live.ws.close());
  await page.waitForFunction(() => window.__sockets.length === 2, null, { timeout: 5000 });
  await page.waitForFunction(() => window.__sockets[1].readyState === 1);
  expect(await page.evaluate(() => document.documentElement.getAttribute("data-live"))).toBe("1");
});

test("reconnect: {reconnect:false} opts out", async ({ page }) => {
  await boot(page, { reconnect: false });
  await page.waitForFunction(() => window.__sockets.length === 1 && window.__sockets[0].readyState === 1);
  await page.evaluate(() => window.Live.ws.close());
  await page.waitForTimeout(1200);         // > the 500ms first backoff
  expect(await page.evaluate(() => window.__sockets.length)).toBe(1);
});
