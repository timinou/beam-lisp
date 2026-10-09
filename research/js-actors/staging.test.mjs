import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';

test('staged macros and forward references execute in the actor runtime',()=>{
  const result=spawnSync(process.execPath,[new URL('./out/staging.mjs',import.meta.url).pathname],{encoding:'utf8',timeout:15000});
  assert.equal(result.status,0,result.stdout+result.stderr);
  assert.match(result.stdout,/^STAGED 42$/m);
});
