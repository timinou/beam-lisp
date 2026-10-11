import test from 'node:test';
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const O=await import(pathToFileURL(process.env.BL_OBSERVATION_OUT+'/ns/js.observation.mjs'));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
test('resource handles own lifetime, bounded registration, and local actions',()=>{
 const hub=O.d_hub();let cancelled=0;
 const resource=hub.register('fixture',()=>({count:1}),{cancel:()=>++cancelled});
 const reader=hub.reader();
 assert.equal(reader.sample()[0].schema,'bl.runtime.observation.v1');
 assert.equal(reader.sample()[0].resources[0].data.count,1);
 reader.invoke(resource.id,'cancel');assert.equal(cancelled,1);
 resource.dispose();resource.dispose();assert.equal(reader.sample()[0].resources.length,0);
 assert.throws(()=>reader.invoke(resource.id,'cancel'));
 reader.dispose();reader.dispose();assert.deepEqual(reader.sample(),[]);
});
test('registration is bounded; failed projections cannot poison the owner',()=>{
 const hub=O.d_hub();const rows=Array.from({length:32},()=>hub.register('fixture',()=>{throw Error('read failed')},{}));
 assert.throws(()=>hub.register('overflow',()=>null,{}));const reader=hub.reader();
 assert.equal(reader.sample()[0].resources.length,32);
 assert.equal(reader.sample()[0].resources[0].error,'Observation failed');
 for(const row of rows)row.dispose();reader.dispose();
});
test('peer reports expire and never grant action authority',async()=>{
 const source=O.d_hub(),target=O.d_hub();const resource=source.register('peer',()=>({value:2}),{cancel:()=>{throw Error('remote action ran')}});
 const reader=target.reader();let rows;
 for(let i=0;i<30;i++){rows=reader.sample();if(rows.some(r=>r.remote))break;await sleep(30);}
 assert.equal(rows.find(r=>r.remote).resources[0].data.value,2);
 assert.throws(()=>reader.invoke(resource.id,'cancel'));
 resource.dispose();const previous=Object.getOwnPropertyDescriptor(performance,'now');const time=performance.now();Object.defineProperty(performance,'now',{configurable:true,value:()=>time+7000});
 try{assert.equal(reader.sample().filter(r=>r.remote).length,0);}finally{if(previous)Object.defineProperty(performance,'now',previous);else delete performance.now;reader.dispose();}
});

test('local reports bound UTF-8 bytes and isolate cyclic projections',()=>{
 const hub=O.d_hub(),cycle={};cycle.self=cycle;
 const rows=[hub.register('unicode',()=>({text:'😀'.repeat(30000)}),{}),
             hub.register('cyclic',()=>cycle,{})];
 const reader=hub.reader(),snapshot=reader.sample()[0];
 assert.equal(snapshot.resources[0].error,'Observation exceeds report byte budget');
 assert.equal(snapshot.resources[1].error,'Observation failed');
 assert.ok(new TextEncoder().encode(JSON.stringify(snapshot)).byteLength<131072);
 for(const row of rows)row.dispose();reader.dispose();
});
test('malformed and oversized peer reports cannot enter the reader',async()=>{
 const hub=O.d_hub(),reader=hub.reader();
 const channel=new BroadcastChannel('bl.runtime.observations.v1');
 channel.postMessage(null);channel.postMessage(undefined);channel.postMessage(0);
 channel.postMessage({type:'snapshot',value:{schema:'bl.runtime.observation.v1',session:'foreign',resources:[{text:'😀'.repeat(40000)}]}});
 await sleep(50);
 assert.equal(reader.sample().filter(r=>r.remote).length,0);
 channel.close();reader.dispose();
});

test('reader admission is bounded and disposal releases capacity',()=>{
 const hub=O.d_hub(),readers=Array.from({length:32},()=>hub.reader());
 assert.throws(()=>hub.reader(),/reader limit/);
 readers.pop().dispose();readers.push(hub.reader());
 for(const reader of readers)reader.dispose();
});
test('subscriptions own their timer and reader and honor inactive views',async()=>{
 let calls=0,active=false;
 assert.throws(()=>O.d_subscribe(()=>{}, {interval:1}));
 const dispose=O.d_subscribe(()=>++calls,{interval:250,active:()=>active});
 await sleep(10);assert.equal(calls,0);active=true;
 await sleep(270);assert.equal(calls,1);
 dispose();dispose();await sleep(270);assert.equal(calls,1);
});

test('one large resource is allowed while aggregate reports remain bounded',()=>{
 const hub=O.d_hub(),rows=Array.from({length:32},(_,i)=>hub.register('fixture',()=>({text:'x'.repeat(50000),i}),{}));
 const reader=hub.reader(),snapshot=reader.sample()[0];
 assert.equal(snapshot.resources[0].data.text.length,50000);
 assert.ok(snapshot.resources.slice(1).every(r=>r.error));
 assert.ok(new TextEncoder().encode(JSON.stringify(snapshot)).byteLength<131072);
 for(const row of rows)row.dispose();reader.dispose();
});

test('a projection that replaces its registration cannot extend the current snapshot',()=>{
 const hub=O.d_hub(),reader=hub.reader();let registration,reads=0;
 const read=()=>{reads++;registration.dispose();registration=hub.register('replacement',read,{});return {reads};};
 registration=hub.register('initial',read,{});
 try{const snapshot=reader.sample()[0];assert.equal(reads,1);assert.equal(snapshot.resources.length,1);}
 finally{registration.dispose();reader.dispose();}
});

test('subscription changes bound backlog, count coalescing and resynchronize',async()=>{
 let release,calls=0,active=true;const deliveries=[];
 const disposeResource=O.d_observe_package('changing',()=>({value:calls}),{});
 const dispose=O.d_subscribe((rows,meta)=>{calls++;deliveries.push({rows,meta});if(calls===1)return new Promise(resolve=>release=resolve);active=false;},{interval:250,active:()=>active});
 try {
  await sleep(30);assert.equal(calls,1);assert.equal(deliveries[0].meta.changes[0].reset,true);
  await sleep(530);assert.equal(calls,1);
  release();for(let i=0;i<40&&calls<2;i++)await sleep(50);assert.equal(calls,2);
  assert.ok(deliveries[1].meta.coalesced>=1);
  assert.equal(deliveries[1].meta.changes[0].reset,false);
  assert.equal(deliveries[1].meta.changes[0].upsert[0].data.value,1);
 }finally{dispose();disposeResource();}
});
test('callback failure disposes owned subscriptions and late rejection is inert',async()=>{
 let failures=0;
 const disposals=Array.from({length:32},()=>O.d_subscribe(()=>{throw Error('consumer failure')},{interval:250,onError:()=>failures++}));
 await sleep(30);assert.equal(failures,32);
 const reader=O.d_observations();reader.dispose();for(const dispose of disposals)dispose();
 let reject;const dispose=O.d_subscribe(()=>new Promise((_,fail)=>reject=fail),{interval:250,onError:()=>failures++});
 await sleep(20);dispose();reject(Error('late'));await sleep(20);assert.equal(failures,32);
});
