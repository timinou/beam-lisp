// Research fixture, compiled by research/js-actors/canonical-runtime-prototype.bl.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
const root=process.env.BL_CANONICAL_PROTOTYPE;
if(!root)throw Error('Set BL_CANONICAL_PROTOTYPE to the compiled research fixture');
test('canonical collections run inside owned actor frames and release all actors',async()=>{
 const contracts=JSON.parse(fs.readFileSync(root+'/contracts.json','utf8'));
 assert.equal(contracts.selected.length,3);
 for(const link of Object.values(contracts.links)){
  assert.equal(link.abi,'bl');assert.equal(link.path,'../canonical-ready.mjs');
 }
 const source=fs.readFileSync(root+'/out/canonical.mjs','utf8');
 for(const name of ['d_first','d_rest','d_count'])assert.ok(source.includes('import {'+name+' as '));
 const module=await import(pathToFileURL(root+'/out/canonical.mjs'));
 const {blToJS}=await import(pathToFileURL(root+'/native.mjs'));
 assert.equal(blToJS(module.observationSnapshot()).total,0);
 assert.deepEqual(blToJS(module.observationSnapshot()).resources,[]);
});
