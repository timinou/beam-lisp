import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';

const bundle = new URL('./out/portable-helper.mjs', import.meta.url);
assert.ok(existsSync(bundle), 'run the source build before verifying the portable helper');
const result = spawnSync(process.execPath, ['--input-type=module', '-e',
  "await import('./out/portable-helper.mjs')"], {
  cwd: new URL('.', import.meta.url), encoding: 'utf8', timeout: 60000,
});
assert.equal(result.status, 0, result.stderr || result.error?.message);
assert.equal(result.stdout.trim(), 'Inbox', 'the source-built JS target must execute the admitted chain');
console.log('PASS emitted BL view-label → label returned the exact string on JS');
console.log('js-actors: PORTABLE-HELPER PASS');
