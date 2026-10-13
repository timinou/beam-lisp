const { defineConfig } = require('@playwright/test');
const { existsSync, readdirSync } = require('node:fs');
const { join } = require('node:path');
const { homedir } = require('node:os');
const cache = join(process.env.XDG_CACHE_HOME || join(homedir(), '.cache'), 'ms-playwright');
const executable = process.env.CONTINUITY_CHROMIUM || (existsSync(cache) ? readdirSync(cache)
  .filter(name => /^chromium-\d+$/.test(name))
  .sort((a, b) => Number(b.split('-')[1]) - Number(a.split('-')[1]))
  .flatMap(name => ['chrome-linux64/chrome', 'chrome-linux/chrome'].map(bin => join(cache, name, bin)))
  .find(path => existsSync(path)) : undefined);
module.exports = defineConfig({ testDir: '.', testMatch: 'continuity.spec.js', workers: 1,
  timeout: 120000, reporter: [['line']],
  use: { headless: true, launchOptions: { executablePath: executable }, reducedMotion: 'reduce' } });
