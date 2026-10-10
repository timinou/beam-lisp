import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import * as H from './host.mjs';
import {lastInput,callCount} from './native-helper.mjs';
let emitted;
H.setEmitter((topic,value)=>{assert.equal(topic,'native');emitted=value;});
const logs=[],log=console.log;
try{console.log=value=>logs.push(value);await import('./out/native-fixture.mjs');}
finally{console.log=log;}
assert.equal(logs.length,1);
assert.deepEqual(logs[0],{identity:true,method:'1,2,3,4,5',undefined:true,conversion:[1,2,3]});
assert.equal(callCount(),2);
assert.deepEqual(emitted.hello,[1,2,3,4,5]);
assert.equal(emitted,lastInput());
const source=await readFile(new URL('./out/native-fixture.mjs',import.meta.url),'utf8');
assert.match(source,/import \{identity as N_/);
assert.match(source,/N_[A-Za-z0-9_$]+\(J\.argument\(t\d+\)\)/);
assert.doesNotMatch(source,/k:'call', f: N_/);
console.log('PASS native call emitted directly; object returned through local actor mailbox');
