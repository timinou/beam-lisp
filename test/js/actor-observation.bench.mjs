// Build observation-actor-bench.bl as out/observation-bench.mjs first.
import {pathToFileURL} from 'node:url';
const root=process.env.BL_ACTOR_OBSERVATION_OUT;
if(!root)throw Error('Set BL_ACTOR_OBSERVATION_OUT');
let result;const log=console.log;
console.log=value=>{
 try{const row=JSON.parse(value);if(row.kind==='actor-observation'){result=row;return;}}catch{}
 // Expected owned shutdowns are omitted from the measurement output.
 if(!String(value).includes('exited: :shutdown'))log(value);
};
try{await import(pathToFileURL(root+'/out/observation-bench.mjs'));}finally{console.log=log;}
if(!result)throw Error('No actor snapshot measurements returned');
const samples=result.samples.slice(20).sort((a,b)=>a-b);
console.log(JSON.stringify({kind:result.kind,actors:result.actors,rows:result.rows,
 samples:samples.length,units:'ms',warmupReads:20,node:process.version,
 rawSamplesMs:result.samples.slice(20),p50:samples[Math.floor(samples.length*.50)],
 p95:samples[Math.floor(samples.length*.95)],p99:samples[Math.floor(samples.length*.99)],
 max:samples.at(-1),scope:'in-actor read only; excludes conversion, DOM and audio output'},null,2));
