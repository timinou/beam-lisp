// Build fixtures/observation-actor.bl with js.actor before running this check.
// BL_ACTOR_OBSERVATION_OUT points at the directory containing host.mjs/native.mjs/out/.
import test from 'node:test';
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const root=process.env.BL_ACTOR_OBSERVATION_OUT;
if(!root)throw Error('Set BL_ACTOR_OBSERVATION_OUT to the compiled fixture directory');
const {observationSnapshot}=await import(pathToFileURL(root+'/out/observation.mjs'));
const {blToJS}=await import(pathToFileURL(root+'/native.mjs'));
test('direct snapshots are bounded, non-suspending, and leave no actor behind',()=>{
 const first=blToJS(observationSnapshot());
 assert.equal(first.total,0);
 assert.equal(first.schema,'bl.runtime.observation.v1');
 assert.deepEqual(blToJS(observationSnapshot()),first);
 assert.deepEqual(first.resources,[]);
 for(const limit of [0,129,1.5,'1',null])assert.throws(()=>observationSnapshot(limit));
 assert.deepEqual(blToJS(observationSnapshot()),first);
});
