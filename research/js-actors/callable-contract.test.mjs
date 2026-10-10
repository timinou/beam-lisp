import {test} from 'node:test';
import assert from 'node:assert/strict';
import * as R from '../../priv/lib/js/rt.mjs';
import * as A from '../../priv/lib/js/abi.mjs';
import * as H from '../../priv/lib/js/actor/host.mjs';
const multi=(fixed,variadic=null)=>R.tup([R.kw('$blfn'),R.EMPTY_MAP.assoc(2,fixed),variadic]);
function turn(f,args,budget=100){
 const rt=H.newRuntime(),entry=function*(){return yield new H.Step('call',{f,args});};
 const frames=[entry()];let result;
 do {result=H.runTurn(rt,frames,budget,false,true);} while(result.status==='yield');
 if(result.status==='error')throw result.exception[0];
 assert.equal(result.status,'done');return result.value;
}
test('ordinary multi-arity values execute inside the actor frame engine',()=>{
 const fn=multi((a,b)=>a+b);
 assert.equal(A.invoke(fn,20,22),42);assert.equal(turn(fn,[20,22]),42);
 assert.equal(turn(fn,[20,22],1),42,'selection survives a turn boundary');
});
test('fixed arms precede variadic arms and rest is packed exactly once in both entries',()=>{
 const rest=(head,tail)=>R.tup([head,tail]);
 const fn=multi((a,b)=>a+b,R.tup([1,rest]));
 assert.equal(turn(fn,[20,22]),42);
 for(const args of [[10],[10,20,30,40]]){
   const direct=A.invoke(fn,...args),actor=turn(fn,args,1);
   assert.ok(R.keyEq(actor,direct));
   assert.equal(R.printStr(actor.items[1]),R.printStr(R.listFromArray(args.slice(1))));
 }
});
test('a variadic arm can itself be an actor closure',()=>{
 const arm=H.blFn('rest',new Map([[2,function*(_rt,[head,rest]){return R.tup([head,rest]);}]]));
 const fn=R.tup([R.kw('$blfn'),R.EMPTY_MAP,R.tup([1,arm])]);
 const value=turn(fn,[1,2,3],1);assert.equal(value.items[0],1);assert.equal(R.printStr(value.items[1]),'(2 3)');
});
test('present nil arms fail as nil calls and do not fall through to variadic dispatch',()=>{
 let fallback=false;const fn=multi(null,R.tup([0,()=>{fallback=true;return 99;}]));
 assert.throws(()=>turn(fn,[1,2]),/cannot call nil/);
 assert.throws(()=>A.invoke(fn,1,2),/cannot call nil|not a function|runtime/);
 assert.equal(fallback,false);
});
test('nested dispatch and metadata retain native thrown values',()=>{
 const original=new Error('selected arm failed');
 const tagged=A.with_meta(()=>{throw original;},R.EMPTY_MAP);
 const inner=R.tup([R.kw('$blfn'),R.EMPTY_MAP.assoc(2,tagged),null]);
 const fn=multi(inner);
 assert.throws(()=>turn(fn,[1,2],1),e=>e===original);
 assert.throws(()=>A.invoke(fn,1,2),e=>e===original);
 assert.throws(()=>turn(fn,[],1),/wrong number of args/);
});

test('multi-arity frame arms preserve constant-space tail calls',()=>{
 const rt=H.newRuntime();let fn;
 const arm=H.blFn('countdown',new Map([[1,function*(_rt,[n]){
   if(n===0)return 42;
   return yield new H.Step('tail',{f:fn,args:[n-1]});
 }]]));
 fn=R.tup([R.kw('$blfn'),R.EMPTY_MAP.assoc(1,arm),null]);
 const frames=[H.resolveCallee(fn,[10000])(rt,[10000])];let result;
 do {result=H.runTurn(rt,frames,17,false,true);}while(result.status==='yield');
 assert.equal(result.status,'done');assert.equal(result.value,42);assert.equal(rt.maxFrames,1);
});
test('a selected native control arm retains its root continuation while parked',()=>{
 const rt=H.newRuntime(),fn=R.tup([R.kw('$blfn'),R.EMPTY_MAP.assoc(0,()=>new H.Step('park')),null]);
 const frames=[H.resolveCallee(fn,[])(rt,[])];
 const paused=H.runTurn(rt,frames,100,false,true);assert.equal(paused.status,'park');assert.equal(frames.length,1);
 const resumed=H.runTurn(rt,frames,100,false,true);assert.equal(resumed.status,'done');assert.equal(resumed.value,null);
});
