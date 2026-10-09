import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import * as H from '../../priv/lib/js/actor/host.mjs';

test('value/effect initialization preserves order and calls forward functions',()=>{
  const result=spawnSync(process.execPath,[new URL('./out/initializers.mjs',import.meta.url).pathname],{encoding:'utf8',timeout:15000});
  assert.equal(result.status,0,result.stdout+result.stderr);
  assert.deepEqual(result.stdout.trim().split('\n'),['FIRST 3','SECOND 7','INITIALIZED 3 7 undefined']);
});
test('initialization yields to host tasks through the same bounded frame machine',async()=>{
  const rt=H.newRuntime();rt.budget=2;let timer=false;
  const ready=new Promise(resolve=>setTimeout(()=>{timer=true;resolve();},0));
  H.def(rt,'js/__init',H.blFn('init',new Map([[0,function*(){
    for(let i=0;i<30;i++)yield new H.Step('call',{f:H.erlangRef('+'),args:[1,2]});
    return 42;
  }]]),null));
  assert.equal(await H.init(rt),42);assert.equal(timer,true);await ready;
});
test('a bound undefined global and alias do not fall through to core',()=>{
  const rt=H.newRuntime();H.def(rt,'core/value',42);H.def(rt,'example/value',undefined);
  assert.equal(H.ref(rt,'example','value'),undefined);
  H.defAlias(rt,'example/alias','example/value');assert.equal(H.ref(rt,'example','alias'),undefined);
  assert.throws(()=>H.ref(rt,'example','absent'),/unresolved global/);
});
