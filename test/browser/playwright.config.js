// playwright.config.js — run the live-client browser proof headless.
const { defineConfig } = require("@playwright/test");

module.exports = defineConfig({
  testDir: ".",
  testMatch: "*.spec.js",
  timeout: 15000,
  use: { headless: true },
  reporter: [["line"]],
});
