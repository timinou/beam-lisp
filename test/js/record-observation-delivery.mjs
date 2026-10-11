import {writeFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const O=await import(pathToFileURL(process.env.BL_OBSERVATION_OUT+'/ns/js.observation.mjs'));
const start=performance.now(),events=[],deliveries=[];let release,active=true,value=0;
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const event=name=>events.push({name,atMs:performance.now()-start});
const resource=O.d_observe_package('owned fixture',()=>({value}),{});
const dispose=O.d_subscribe((rows,metadata)=>{
 deliveries.push({atMs:performance.now()-start,rows,metadata});event('delivery '+deliveries.length);
 if(deliveries.length===1)return new Promise(resolve=>release=resolve);
 active=false;
},{interval:250,active:()=>active,onError:error=>{throw error;}});
try{
 await sleep(30);assert.equal(deliveries.length,1);event('consumer pending');
 value=1;await sleep(550);assert.equal(deliveries.length,1);event('consumer released');release();
 for(let i=0;i<40&&deliveries.length<2;i++)await sleep(50);
 assert.equal(deliveries.length,2);assert.ok(deliveries[1].metadata.coalesced>=1);
 assert.equal(deliveries[1].rows[0].resources[0].data.value,1);
 dispose();resource();event('owners disposed');
 await sleep(300);assert.equal(deliveries.length,2);
 writeFileSync('docs/proof/runtime-observation/milestone-2/delivery.json',JSON.stringify({schema:'bl.observation.delivery.proof.v1',intervalMs:250,events,deliveries,checks:{onePendingDelivery:true,resyncFromCurrent:true,noDeliveryAfterDispose:true}},null,2)+'\n');
 console.log('recorded two bounded deliveries, coalescing, resynchronization and disposal');
}finally{dispose();resource();}
