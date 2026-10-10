import {test} from 'node:test';
import assert from 'node:assert/strict';
import * as R from '../../priv/lib/js/rt.mjs';
import * as H from './host.mjs';
test('actor and direct modules share interned and persistent values',()=>{
 assert.equal(H.kw('shared/x'),R.kw('shared/x'));
 assert.equal(H.ENIL,R.EMPTY);
 assert.ok(H.tup([1]) instanceof R.Tup);
 const key=R.vec(1,R.kw('x'));
 const map=H.bmap([[H.vec([1,H.kw('x')]),'shared']]);
 assert.ok(map instanceof R.HMap);
 assert.equal(map.get(key),'shared');
 assert.equal(H.mapGet(R.hashMap(key,'direct'),H.vec([1,H.kw('x')])),'direct');
 assert.ok(H.setHas(R.hashSet(key),H.vec([1,H.kw('x')])));
 const next=H.mapPut(map,key,'changed');
 assert.equal(map.get(key),'shared');assert.equal(next.get(key),'changed');
 const record=H.struct('Example',{value:key});
 assert.equal(H.structMod(record),'Example');assert.equal(H.structField(record,'value'),key);
 assert.equal(H.mapGet(H.bmap([[record,42]]),H.struct('Example',{value:H.vec([1,H.kw('x')])})),42);
});
test('equal exact integers have equal hashes and work as interchangeable keys',()=>{
 for(const n of [0,1,-1,4294967297,-4294967297,Number.MAX_SAFE_INTEGER,2**70]){
  assert.equal(R.hashOf(n),R.hashOf(BigInt(n)));
  assert.equal(H.mapGet(H.bmap([[n,'ok']]),BigInt(n)),'ok');
  assert.equal(H.mapGet(H.bmap([[BigInt(n),'ok']]),n),'ok');
 }
});

test('canonical equality keeps exact numbers and improper-list tails',()=>{
 assert.equal(H.eq,R.eqv);
 assert.equal(H.eq(9007199254740993n,9007199254740992),false);
 assert.equal(H.eq(1n,1),true);
 assert.equal(H.eq(H.cons(1,2),H.cons(1,3)),false);
 assert.equal(H.eq(H.cons(1,2),H.listFromArray([1])),false);
 assert.equal(H.eq(H.cons(1,2),H.cons(1,2)),true);
 assert.equal(H.mapGet(H.bmap([[H.cons(1,2),'tail']]),H.cons(1,3)),null);
});

test('actor numeric operations retain canonical float and decimal identity',()=>{
 const x=H.arith('div',8,2);
 assert.ok(x instanceof R.Flt);assert.equal(x.v,4);
 assert.equal(H.isFloat(x),true);assert.equal(H.isInt(x),false);
 assert.equal(H.eq(x,4),true);assert.equal(H.identical(x,4),false);
 assert.equal(H.mapGet(H.bmap([[x,'float'],[4,'int']]),R.flt(4)),'float');
 assert.equal(H.mapGet(H.bmap([[x,'float'],[4,'int']]),4),'int');
 assert.equal(H.arith('add',9007199254740993n,R.flt(.25)).v,9007199254740992);
 assert.equal(H.arith('add',R.dec(15,1),1).plain(),'2.5');
 assert.throws(()=>H.arith('add',R.dec(15,1),R.flt(.25)),/float cannot enter decimal/);
});

test('all canonical numeric equality leaves agree with BEAM beyond the safe band',()=>{
 const a=9007199254740993n,b=R.flt(9007199254740992);
 assert.equal(R.eqv(a,b),false);assert.equal(R.erlEq(a,b),false);assert.equal(R.numEq(a,b),false);
 assert.equal(H.erlangRef('==')(a,b),false);
 assert.equal(H.erlangRef('=:=')(R.flt(4),4),false);
 assert.equal(H.erlangRef('==')(R.flt(4),4),true);
});

test('host table key identity never mutates foreign or frozen objects',()=>{
 for(const value of [Object.freeze({x:1}),Object.freeze(()=>1)]){
  const before=Reflect.ownKeys(value),key=H.hashKey(value);
  assert.equal(H.hashKey(value),key);assert.deepEqual(Reflect.ownKeys(value),before);
  assert.notEqual(H.hashKey(Object.freeze({x:1})),key);
 }
});
