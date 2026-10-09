// Same canonical arithmetic and native conversions; only execution differs.
import assert from 'node:assert/strict';
import * as H from './host.mjs';
import * as J from './native.mjs';
import * as I from '../../priv/lib/js/interop.mjs';
const rt=H.newRuntime();
const actor=H.blFn('increment',new Map([[1,function*(rt,[x]){return H.arith('add',x,1);}]]),null,rt,true);
const routes={
  direct:I.argument(x=>H.values.add(x,1)),
  actor:J.argument(actor),
};
const results=[];
for(const [name,fn] of Object.entries(routes)){
  assert.equal(fn(1.25),2.25);
  for(let warm=0;warm<2000;warm++)fn(1.25);
  const cpuStart=process.cpuUsage(),samples=[];
  for(let batch=0;batch<40;batch++){
    const started=performance.now();
    for(let call=0;call<1000;call++)assert.equal(fn(1.25),2.25);
    samples.push((performance.now()-started)*1000/1000);
  }
  samples.sort((a,b)=>a-b);
  const cpu=process.cpuUsage(cpuStart);
  results.push({route:name,calls:40000,medianUs:samples[19],p95BatchMeanUs:samples[37],cpuMs:(cpu.user+cpu.system)/1000});
}
console.log(JSON.stringify({node:process.version,description:'batched CPU microbenchmark; not end-to-end media latency',results},null,2));
