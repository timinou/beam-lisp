import {test} from 'node:test';import assert from 'node:assert/strict';
import * as R from '../../priv/lib/js/rt.mjs';import * as H from './host.mjs';import * as P from './out/pattern-cases.mjs';
test('literal matching preserves BEAM numeric kind rather than loose BL equality',()=>{
 assert.equal(P.intLiteral(1),true);assert.equal(P.intLiteral(1n),true);assert.equal(P.intLiteral(R.flt(1)),false);
 assert.equal(P.floatLiteral(R.flt(1)),true);assert.equal(P.floatLiteral(1),false);
});
test('a missing map or record field cannot match a present nil',()=>{
 assert.equal(P.nilField(R.hashMap()),false);assert.equal(P.nilField(R.hashMap(R.kw('value'),null)),true);
 const record=R.hashMap(R.kw('__struct__'),R.kw('Example'));
 assert.equal(P.recordField(record),false);assert.equal(P.recordField(record.assoc(R.kw('value'),null)),true);
 assert.equal(P.recordField(null),false);assert.equal(P.recordField(1),false);
});
test('canonical tuple/vector structure is shared by ordinary and actor consumers',()=>{
 assert.equal(P.tuple(H.tup([H.kw('pair'),42])),true);assert.equal(P.tuple(R.vec(R.kw('pair'),42)),false);
 assert.equal(P.vector(H.vec([1])),true);assert.equal(P.vector(R.vec(1,2)),false);
 assert.equal(H.structMod,R.structMod);assert.equal(H.structField,R.structField);assert.equal(H.struct,R.struct);
});
