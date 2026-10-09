import {test} from 'node:test';
import assert from 'node:assert/strict';
import * as H from './host.mjs';
import * as J from './native.mjs';
import * as A from '../../priv/lib/js/abi.mjs';
test('native values retain identity, floats and undefined',()=>{
 const value={x:[1.25,undefined]};
 assert.equal(J.argument(value),value);assert.equal(J.result(value),value);
 assert.equal(J.result(1.25).v,1.25);assert.equal(J.result(undefined),undefined);
 const fn=x=>x;assert.equal(J.argument(J.result(fn)),fn);assert.equal(J.result(fn),J.result(fn));
});
test('BL values require explicit conversion and actor callbacks fail clearly',()=>{
 for(const value of [H.vec([1]),H.bmap([[H.kw('x'),2]]),H.listFromArray([1])])assert.throws(()=>J.argument(value),/collection needs/);
 assert.throws(()=>J.argument(H.blFn('wait',new Map(),null)),/not proven non-suspending/);
 assert.deepEqual(J.blToJS(H.bmap([[H.kw('x'),H.vec([1,2])]])),{x:[1,2]});
 const value=J.jsToBL({x:[1,2]},H.kw('keywordize-keys'),true);
 assert.deepEqual(J.blToJS(value),{x:[1,2]});
});
test('conversion detects cycles and never invokes prototype setters',()=>{
 const cycle={};cycle.x=cycle;assert.throws(()=>J.jsToBL(cycle),/cyclic/);
 const value=H.bmap([['__proto__',H.vec([1])]]),plain=J.blToJS(value);
 assert.deepEqual(plain.__proto__,[1]);assert.equal(Object.getPrototypeOf(plain),Object.prototype);
 assert.equal(J.propertyKey('x'),'x');
 let keys=0;assert.equal(J.propertyKey({toString(){keys++;return 'own';}}),'own');assert.equal(keys,1);
});

test('checked callbacks reenter the actor machine with canonical values',()=>{
 const rt=H.newRuntime();
 const inc=H.blFn('inc',new Map([[1,function*(rt,[x]){return H.arith('add',x,1);}]]),null,rt,true);
 const callback=J.argument(inc);
 assert.equal(J.argument(inc),callback);
 const metadata=H.bmap([[H.kw('doc'),'increment']]),tagged=A.with_meta(inc,metadata);
 assert.equal(A.meta(tagged),metadata);assert.equal(A.meta(inc),null);
 assert.equal(J.argument(tagged)(2),3);
 assert.equal(H.resolveCallee(tagged,[2]),H.resolveCallee(inc,[2]));
 assert.equal(A.invoke(inc,2),3);
 assert.equal(callback(1.5),2.5);
 assert.equal(inc(H.flt(1.5)).v,2.5);
 const many=H.tup([H.kw('$blfn'),H.bmap([[1,inc]]),null]);
 assert.equal(J.argument(many)(2),3);
 const error=new Error('original');
 const fail=H.blFn('fail',new Map([[0,function*(){throw error;}]]),null,rt,true);
 assert.throws(()=>J.argument(fail)(),e=>e===error);
 const nested=H.blFn('nested',new Map([[1,function*(rt,[x]){return J.argument(inc)(H.numberValue(x));}]]),null,rt,true);
 assert.equal(J.argument(nested)(2),3);
 let caught=false;
 const undefinedThrow=H.blFn('undefined',new Map([[0,function*(){throw undefined;}]]),null,rt,true);
 try{J.argument(undefinedThrow)();}catch(e){caught=true;assert.equal(e,undefined);}assert.ok(caught);
});
test('unknown and suspending arity arms cannot reach JS; callbacks are bounded',()=>{
 const rt=H.newRuntime(); let effects=0;
 const unknown=H.blFn('unknown',new Map([[0,function*(){effects++;return 1;}]]),null,rt);
 assert.throws(()=>J.argument(unknown),/not proven/);assert.equal(effects,0);
 const safe=H.blFn('safe',new Map([[0,function*(){return 1;}]]),null,rt,true);
 const mixed=H.tup([H.kw('$blfn'),H.bmap([[0,safe],[1,unknown]]),null]);
 assert.throws(()=>J.argument(mixed),/not proven/);
 let released=false;
 const loop=H.blFn('loop',new Map([[0,function*(){try{for(;;)yield {k:'value',v:null};}finally{released=true;}}]]),null,rt,true);
 assert.throws(()=>H.invokeSynchronous(loop,[],10),/budget/);assert.ok(released);
 assert.equal(J.argument(safe)(),1);
});
