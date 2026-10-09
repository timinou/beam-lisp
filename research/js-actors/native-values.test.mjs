import {test} from 'node:test';
import assert from 'node:assert/strict';
import * as H from './host.mjs';
import * as J from './native.mjs';
test('native values retain identity, floats and undefined',()=>{
 const value={x:[1.25,undefined]};
 assert.equal(J.argument(value),value);assert.equal(J.result(value),value);
 assert.equal(J.result(1.25).v,1.25);assert.equal(J.result(undefined),undefined);
 const fn=x=>x;assert.equal(J.argument(fn),fn);assert.equal(J.result(fn),fn);
});
test('BL values require explicit conversion and actor callbacks fail clearly',()=>{
 for(const value of [H.vec([1]),H.bmap([[H.kw('x'),2]]),H.listFromArray([1])])assert.throws(()=>J.argument(value),/collection needs/);
 assert.throws(()=>J.argument(H.blFn('wait',new Map(),null)),/cannot be synchronous/);
 assert.deepEqual(J.blToJS(H.bmap([[H.kw('x'),H.vec([1,2])]])),{x:[1,2]});
 const value=J.jsToBL({x:[1,2]},H.kw('keywordize-keys'),true);
 assert.deepEqual(J.blToJS(value),{x:[1,2]});
});
test('conversion detects cycles and never invokes prototype setters',()=>{
 const cycle={};cycle.x=cycle;assert.throws(()=>J.jsToBL(cycle),/cyclic/);
 const value=H.bmap([['__proto__',H.vec([1])]]),plain=J.blToJS(value);
 assert.deepEqual(plain.__proto__,[1]);assert.equal(Object.getPrototypeOf(plain),Object.prototype);
 assert.throws(()=>J.propertyKey(H.kw('x')),/property key/);
});
