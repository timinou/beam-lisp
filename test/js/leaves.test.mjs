// test/js/leaves.test.mjs — the leaf table is ONE table: every key has one
// owner, and the table refuses a second definition (PLAN-163 structural fix 2).
// Run: node --test test/js/
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const dir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../priv/lib/js");

test("the leaf table loads (no key is defined twice)", async () => {
  const L = await import(path.join(dir, "leaves.mjs"));
  assert.ok(L.NAMES.length > 300, "expected the full table, got " + L.NAMES.length);
  assert.equal(new Set(L.NAMES).size, L.NAMES.length);
});

// The load check above only sees keys that reach the table. A static scan
// catches a duplicate the table would never get to see (a key repeated
// inside one object literal: JS keeps the LAST silently).
test("no leaf key is spelled twice in the leaf sources", () => {
  const seen = new Map();
  const dups = [];
  for (const f of ["leaves.mjs", "host-leaves.mjs", "lazy.mjs"]) {
    const src = fs.readFileSync(path.join(dir, f), "utf8");
    const lines = src.split("\n");
    lines.forEach((line, i) => {
      const m = line.match(/^\s*(?:\[LS \+ )?"([^"]+\/\d+)"\]?\s*:/);
      if (!m) return;
      const key = line.includes("[LS + ") ? "Elixir.BeamLisp.LazySeq/" + m[1] : m[1];
      if (seen.has(key)) dups.push(key + " at " + seen.get(key) + " and " + f + ":" + (i + 1));
      else seen.set(key, f + ":" + (i + 1));
    });
  }
  assert.deepEqual(dups, []);
});
