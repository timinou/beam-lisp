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

// A reconnect SWAPS `ws` for a new object (openSocket reassigns it), and the
// click handler reads `ws.__navigate` off whatever is current. Attach the
// navigator to only the first socket and the one a reconnect brings back has
// none: the click is preventDefault'd, no navigate frame is ever sent, and the
// URL never moves — a dead in-app link on a socket that reports itself live.
// Silent, and only after a drop, which is what makes it look intermittent.
test("reconnect: an in-app link still navigates on the socket that came back", async ({ page }) => {
  await boot(page);
  await page.waitForFunction(() => window.__sockets.length === 1 && window.__sockets[0].readyState === 1);
  await page.evaluate(() => {
    document.getElementById("live-root").innerHTML = '<a href="/lib/dossier-mci">dossier-mci</a>';
  });
  await page.evaluate(() => window.Live.ws.close());
  await page.waitForFunction(() => window.__sockets.length === 2 && window.__sockets[1].readyState === 1);

  await page.click("a[href='/lib/dossier-mci']");

  // the click must reach the server over the socket that is actually open
  await page.waitForFunction(() => window.__sockets[1].sent.length > 0, null, { timeout: 2000 });
  expect(await page.evaluate(() => window.__sockets[1].sent))
    .toEqual(['["event",["navigate","/lib/dossier-mci"],{}]']);
});

// ── the session id ───────────────────────────────────────────────────
//
// The server keys the SESSION (locals, last-seen tree, subscriptions) on
// `live-sid`, so a reconnect resumes instead of re-mounting. Two things have
// to hold for that: the id is on every socket URL, and it is the SAME one
// across a reconnect of the same page load — a fresh id per reconnect would
// be a fresh session, which is the bug this exists to prevent.

test("session: every socket URL carries the sid, identical across a reconnect", async ({ page }) => {
  await boot(page);
  await page.waitForFunction(() => window.__sockets.length === 1 && window.__sockets[0].readyState === 1);
  const first = await page.evaluate(() => window.__sockets[0].url);
  expect(first).toMatch(/[?&]live-sid=[0-9a-f]{32}/);
  await page.evaluate(() => window.Live.ws.close());
  await page.waitForFunction(() => window.__sockets.length === 2, null, { timeout: 5000 });
  const second = await page.evaluate(() => window.__sockets[1].url);
  expect(second).toBe(first);
});

test("session: a fresh connect() mints a NEW sid (a reload is a new session)", async ({ page }) => {
  await boot(page);
  await page.waitForFunction(() => window.__sockets.length === 1 && window.__sockets[0].readyState === 1);
  const first = await page.evaluate(() => window.__sockets[0].url);
  const other = await page.evaluate(() => {
    var before = window.__sockets.length;
    window.Live.connect({ root: document.getElementById("live-root"), url: "ws://fake/ws" });
    return window.__sockets[before].url;
  });
  expect(other).not.toBe(first);
  expect(other).toMatch(/[?&]live-sid=[0-9a-f]{32}/);
});
