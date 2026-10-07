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

test("exact lookup follows only explicit reexports and terminates cyclic declarations", () => {
  ENV.intern("exact-reexport-provider", "identity", 19);
  ENV.add_refer("exact-reexport-facade", "identity", "exact-reexport-provider");
  ENV.add_refer("exact-reexport-outer", "identity", "exact-reexport-facade");
  assert.equal(ENV["fetch_exact!"]("exact-reexport-facade", "identity"), 19);
  assert.equal(run('return GX("exact-reexport-outer", "identity");'), 19);
  ENV.intern("exact-reexport-facade", "identity", 23);
  assert.equal(ENV["fetch_exact!"]("exact-reexport-facade", "identity"), 23);
  ENV.add_refer("exact-reexport-cycle-a", "identity", "exact-reexport-cycle-b");
  ENV.add_refer("exact-reexport-cycle-b", "identity", "exact-reexport-cycle-a");
  assert.throws(() => ENV["fetch_exact!"]("exact-reexport-cycle-a", "identity"), /undefined var/);
  assert.throws(() => run('return GX("exact-reexport-cycle-a", "identity");'), /undefined var/);
});
