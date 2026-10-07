import { test } from "node:test";
import assert from "node:assert/strict";
import { ENV } from "../../priv/lib/js/env.mjs";
import { run } from "../../priv/lib/js/leaves.mjs";

test("exact provider lookups refuse core fallback and preserve live rebinding", () => {
  ENV.intern("core", "exact-fixture-name", 42);
  assert.equal(ENV["fetch!"]("exact-fixture-provider", "exact-fixture-name"), 42);
  assert.throws(() => ENV["fetch_exact!"]("exact-fixture-provider", "exact-fixture-name"), /undefined var: exact-fixture-provider\/exact-fixture-name/);
  assert.throws(() => run('return GX("exact-fixture-provider", "exact-fixture-name");'), /undefined var: exact-fixture-provider\/exact-fixture-name/);
  ENV.intern("exact-fixture-provider", "exact-fixture-name", null);
  assert.equal(ENV["fetch_exact!"]("exact-fixture-provider", "exact-fixture-name"), null);
  assert.equal(run('return GX("exact-fixture-provider", "exact-fixture-name");'), null);
  ENV.intern("exact-fixture-provider", "exact-fixture-name", 7);
  assert.equal(ENV["fetch_exact!"]("exact-fixture-provider", "exact-fixture-name"), 7);
  assert.equal(run('return GX("exact-fixture-provider", "exact-fixture-name");'), 7);
});
