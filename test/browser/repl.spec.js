const { test, expect } = require('@playwright/test');
const fs = require('node:fs');
const path = require('node:path');

const assets = path.resolve(__dirname, '../../priv/std/vm/repl');

async function openRepl(page) {
  await page.addInitScript(() => {
    window.__sockets = [];
    window.WebSocket = class {
      static OPEN = 1;
      constructor(url) {
        this.url = url;
        this.readyState = 1;
        this.sent = [];
        window.__sockets.push(this);
        setTimeout(() => this.onmessage?.({ data: JSON.stringify({ kind: 'hello', session: 's1', ns: 'user' }) }), 0);
      }
      send(data) { this.sent.push(JSON.parse(data)); }
      close() { this.readyState = 3; this.onclose?.(); }
      receive(frame) { this.onmessage?.({ data: JSON.stringify(frame) }); }
    };
  });
  await page.route('**/repl/editor.bundle.js*', route => route.fulfill({
    contentType: 'text/javascript', body: fs.readFileSync(path.join(assets, 'editor.bundle.js')),
  }));
  await page.route('**/repl', route => route.fulfill({
    contentType: 'text/html', body: fs.readFileSync(path.join(assets, 'page.html'), 'utf8').replace('__BL_TOKEN__', JSON.stringify('test-token')),
  }));
  await page.goto('http://localhost:7841/repl');
  await expect(page.locator('#connection')).toHaveText('Connected');
}

test('starter, balanced Run, output, and working state', async ({ page }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await openRepl(page);
  await expect(page.locator('#welcome')).toBeVisible();
  await expect(page.locator('#run')).toBeDisabled();
  await page.getByRole('button', { name: '(+ 1 2)' }).click();
  await expect(page.locator('.cm-content')).toContainText('(+ 1 2)');
  await expect(page.locator('#run')).toBeEnabled();
  await page.locator('#run').click();
  await expect(page.locator('#welcome')).toBeHidden();
  await expect(page.locator('#connection')).toHaveText('Evaluating…');
  await expect(page.locator('#interrupt')).toBeEnabled();
  const op = await page.evaluate(() => window.__sockets[0].sent.find(x => x.op === 'eval'));
  expect(op.src).toBe('(+ 1 2)');
  await page.evaluate(id => window.__sockets[0].receive({ kind: 'out', id, text: 'hello' }), op.id);
  await page.evaluate(id => window.__sockets[0].receive({ kind: 'value', id, text: '3', ns: 'user', ms: 2 }), op.id);
  await expect(page.locator('#log')).toContainText('=> 3');
  await expect(page.locator('#connection')).toHaveText('Connected');
  await expect(page.locator('#interrupt')).toBeDisabled();
  expect(errors).toEqual([]);
});

test('disconnect preserves draft and explains interrupted result', async ({ page }) => {
  await openRepl(page);
  await page.locator('.cm-content').fill('(+ 2 3)');
  await page.locator('#run').click();
  await page.locator('.cm-content').fill('(def draft 5)');
  await page.evaluate(() => window.__sockets[0].close());
  await expect(page.locator('#connection')).toContainText('Disconnected');
  await expect(page.locator('#log')).toContainText('Connection lost before evaluation completed.');
  await expect(page.locator('.cm-content')).toContainText('(def draft 5)');
  await expect(page.locator('#run')).toBeDisabled();
});

test('narrow layout fits viewport and keyboard help is accessible', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 650 });
  await openRepl(page);
  await expect(page.locator('#shortcuts summary')).toBeVisible();
  await page.locator('#shortcuts summary').click();
  await expect(page.locator('#shortcuts .popover')).toBeVisible();
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
  expect(overflow).toBe(false);
});

test('Enter waits for a complete form, then Stop interrupts the correct evaluation', async ({ page }) => {
  await openRepl(page);
  await page.locator('.cm-content').fill('(+ 1');
  await expect(page.locator('#run')).toBeDisabled();
  await page.locator('.cm-content').press('Enter');
  await expect(page.locator('#log .src')).toHaveCount(0);
  await page.locator('.cm-content').fill('(+ 1 2)');
  await page.locator('.cm-content').press('Enter');
  const op = await page.evaluate(() => window.__sockets[0].sent.find(x => x.op === 'eval'));
  expect(op.src).toBe('(+ 1 2)');
  await page.locator('#interrupt').click();
  const interrupt = await page.evaluate(() => window.__sockets[0].sent.find(x => x.op === 'interrupt'));
  expect(interrupt).toBeTruthy();
  await page.evaluate(id => window.__sockets[0].receive({ kind: 'interrupt-sent', id }), interrupt.id);
  await page.evaluate(id => window.__sockets[0].receive({ kind: 'error', id, text: 'eval ended: killed', interrupted: true, ms: 8 }), op.id);
  await expect(page.locator('#log')).toContainText('Interrupted — eval ended: killed');
  await expect(page.locator('#interrupt')).toBeDisabled();
  await expect(page.locator('#connection')).toHaveText('Connected');
});

test('documentation response cannot consume an eval result', async ({ page }) => {
  await openRepl(page);
  await page.locator('.cm-content').fill('(+ 1 2)');
  await page.locator('#run').click();
  await page.locator('.cm-content').fill('map');
  const evalOp = await page.evaluate(() => window.__sockets[0].sent.find(x => x.op === 'eval'));
  await expect.poll(() => page.evaluate(() => window.__sockets[0].sent.find(x => x.op === 'doc')?.id)).toBeGreaterThan(0);
  const docOp = await page.evaluate(() => window.__sockets[0].sent.find(x => x.op === 'doc'));
  await page.evaluate(id => window.__sockets[0].receive({ kind: 'doc', id, name: 'map', ns: 'core', arglists: '(map f xs)', doc: 'Apply a function.' }), docOp.id);
  await expect(page.locator('#hints')).toContainText('Apply a function.');
  await page.evaluate(id => window.__sockets[0].receive({ kind: 'value', id, text: '3', ms: 2 }), evalOp.id);
  await expect(page.locator('#log')).toContainText('=> 3');
  await expect(page.locator('.cm-content')).toContainText('map');
});
