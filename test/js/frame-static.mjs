import assert from 'node:assert/strict';
import path from 'node:path';import {pathToFileURL} from 'node:url';
const out=process.argv[2];
await import(pathToFileURL(path.join(out,'ns/js.frame.mjs')));
const {requireNamespace}=await import(pathToFileURL(path.join(out,'interop.mjs')));
const frame=requireNamespace('js.frame'),prior={};
for(const name of ['requestAnimationFrame','cancelAnimationFrame','setTimeout','clearTimeout'])prior[name]=globalThis[name];
let id=0;const callbacks=new Map(),cancelled=[];
globalThis.requestAnimationFrame=f=>{callbacks.set(++id,f);return id;};
globalThis.setTimeout=(f,ms)=>{assert.ok(ms>16&&ms<17);callbacks.set(++id,f);return id;};
globalThis.cancelAnimationFrame=globalThis.clearTimeout=value=>cancelled.push(value);
try{
 let calls=0;const first=frame.request(()=>calls++),raf=callbacks.get(1),timer=callbacks.get(2);
 assert.ok(first instanceof AbortController);timer();raf(100);assert.equal(calls,1);assert.ok(first.signal.aborted);assert.deepEqual(cancelled,[1,2]);
 const second=frame.request(()=>calls++);callbacks.get(3)(101);callbacks.get(4)();assert.equal(calls,2);assert.ok(second.signal.aborted);
 const third=frame.request(()=>calls++);frame.cancel(third);callbacks.get(5)(102);callbacks.get(6)();assert.equal(calls,2);assert.ok(third.signal.aborted);
 delete globalThis.requestAnimationFrame;delete globalThis.cancelAnimationFrame;
 const fourth=frame.request(()=>calls++);callbacks.get(7)();assert.equal(calls,3);assert.ok(fourth.signal.aborted);frame.cancel(null);
 console.log('compiled BL frame scheduler: RAF, timer race and cancellation pass');
}finally{for(const [name,value]of Object.entries(prior)){if(value===undefined)delete globalThis[name];else globalThis[name]=value;}}
