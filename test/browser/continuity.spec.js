const { test, expect } = require('@playwright/test');
const { mkdirSync, writeFileSync } = require('node:fs');
const { join } = require('node:path');
const url = process.env.CONTINUITY_URL;
const evidence = process.env.CONTINUITY_EVIDENCE;

test('Continuity: real orders survive refusal, native publication, recovery and retirement', async ({ page, request }) => {
  test.skip(!url || !evidence, 'Run examples/continuity/verify.sh against its isolated server');
  test.setTimeout(120_000);
  mkdirSync(evidence, { recursive: true });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.setViewportSize({ width: 1440, height: 1100 });
  await page.goto(url);
  await expect(page.locator('#connection')).toHaveText('Live');
  const token = await page.locator('meta[name="continuity-token"]').getAttribute('content');
  const snapshot = async () => (await request.get(`${url}/api/state`)).json();
  const initial = await snapshot();
  expect(initial.version).toBe(1);
  await expect.poll(async () => (await snapshot()).orders).toBeGreaterThan(2);
  const draft = page.getByLabel('Your unsent note');
  await draft.fill('Ship the code. Keep this draft.');
  await draft.evaluate(node => { window.savedDraftNode = node; });
  const unauthorized = await request.post(`${url}/api/scenario/upgrade`);
  expect(unauthorized.status()).toBe(403);
  const hostile = await request.post(`${url}/api/scenario/upgrade`, { headers: { 'x-continuity-token': token, origin: 'https://hostile.invalid' } });
  expect(hostile.status()).toBe(403);
  for (const [label, title] of [['Message', 'Message migration refused'], ['State', 'State migration refused'], ['Data', 'Duplicate references refused']]) {
    await page.getByRole('button', { name: label, exact: true }).click();
    await expect(page.locator('#deployment-title')).toHaveText(title);
    expect((await snapshot()).version).toBe(1);
  }
  await page.screenshot({ path: join(evidence, '01-refused.png'), fullPage: true });
  const before = await snapshot();
  await page.getByRole('button', { name: 'Deploy v2', exact: true }).click();
  await expect.poll(async () => (await snapshot()).version).toBe(2);
  await expect(page.locator('#deployment-title')).toHaveText('Old client still connected');
  await expect.poll(async () => (await snapshot()).orders).toBeGreaterThan(before.orders);
  await expect(draft).toHaveValue('Ship the code. Keep this draft.');
  expect(await draft.evaluate(node => node === window.savedDraftNode)).toBe(true);
  const upgraded = await snapshot();
  expect(upgraded.actor).toBe(initial.actor); expect(upgraded.vm).toBe(initial.vm);
  expect(upgraded['client-version']).toBe(1); expect(upgraded.errors).toBe(0);
  await page.screenshot({ path: join(evidence, '02-live-upgrade.png'), fullPage: true });
  // Independent concurrent HTTP writers run during the fault/recovery window.
  // Each ID is unique; no retry hides a failure or ambiguous response.
  const results = [];
  const writers = Array.from({ length: 3 }, (_, worker) => (async () => {
    for (let n = 0; n < 25; n++) {
      const start = performance.now();
      const response = await request.post(`${url}/api/order`, { headers: { 'x-continuity-token': token, 'x-order-id': `browser-${worker}-${n}` } });
      const body = await response.json();
      results.push({ status: response.status(), accepted: body.accepted, ms: performance.now() - start });
      await new Promise(resolve => setTimeout(resolve, 35));
    }
  })());
  await page.getByRole('button', { name: 'Deploy a faulty release', exact: true }).click();
  await expect(page.locator('#recovery')).toBeVisible();
  await expect.poll(async () => (await snapshot()).version).toBe(4);
  await Promise.all(writers);
  await expect(page.locator('#recovery-title')).toHaveText('Recovered. Every receipt kept.');
  const recovered = await snapshot();
  expect(recovered.orders).toBeGreaterThanOrEqual(upgraded.orders + 75);
  expect(recovered.cents).toBe(recovered.orders * 1599);
  expect(recovered.actor).toBe(initial.actor); expect(recovered.vm).toBe(initial.vm);
  expect(results).toHaveLength(75);
  expect(results.every(r => r.status === 200 && r.accepted)).toBe(true);
  expect(recovered.errors).toBe(0);
  await page.screenshot({ path: join(evidence, '03-recovered.png'), fullPage: true });
  await page.getByRole('button', { name: 'Finish old work', exact: true }).click();
  await expect(page.locator('#deployment-title')).toHaveText('Old contracts retired');
  const retired = await snapshot();
  expect(retired['legacy-versions']).toEqual([]);
  expect(retired.graphs.filter(g => g.version < 4).every(g => g.retired)).toBe(true);
  expect(retired['client-version']).toBe(4);
  expect(retired.job).toEqual({ state: 'done', version: 1, origin: 1 });
  await expect(draft).toHaveValue('Ship the code. Keep this draft.');
  await page.screenshot({ path: join(evidence, '04-retired.png'), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ reducedMotion: 'reduce' });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.screenshot({ path: join(evidence, '05-mobile.png'), fullPage: true });
  await page.getByRole('button', { name: 'Pause traffic', exact: false }).focus();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('button', { name: 'Resume traffic', exact: false })).toBeFocused();
  await page.keyboard.press('Enter');
  expect(errors).toEqual([]);
  const times = results.map(r => r.ms).sort((a, b) => a - b);
  const quantile = p => times[Math.min(times.length - 1, Math.ceil(times.length * p) - 1)];
  writeFileSync(join(evidence, 'browser-results.json'), JSON.stringify({ scope: 'source demo; native actors and Fjall; external Chromium', initial: { actor: initial.actor, vm: initial.vm }, upgraded, recovered, retired, concurrent: { requests: times.length, errors: results.filter(r => r.status !== 200 || !r.accepted).length, p50: quantile(.5), p95: quantile(.95), p99: quantile(.99), max: times.at(-1) }, browserErrors: errors }, null, 2));
});
