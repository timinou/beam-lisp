import test from 'node:test';
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const root=process.env.BL_ACTOR_MODULE_OUT||'/tmp/bl-actor-module-prototype';
const load=n=>import(pathToFileURL(root+'/'+n+'.mjs'));
const [F,R,H]=await Promise.all([load('ns/actor-module.fixture'),load('rt'),load('actor/host')]);
test('ordinary namespace exports use the existing actor callable ABI',()=>{
 for(const name of ['values','recursive','iterated','variadic','raises','callback'])assert.equal(F['d_'+name].__blfn,true);
 assert.equal(R.printStr(F.d_values()),'{:applied 6, :first "b", :lookup 42, :mapped [2 3 4], :rest [8], :sorted [{:n 1} {:n 3}]}');
 assert.equal(F.d_variadic(1,2,3,4),10);
 assert.equal(R.printStr(F.d_raises()),'{:n 1}');
 assert.deepEqual(F.d_callback(),[2,3,4]);
});
test('compiled loops yield to the existing turn budget and preserve continuation',()=>{
 const rt=H.newRuntime({input:false}),frames=[H.resolveCallee(F.d_iterated,[10000])(rt,[10000])];
 let result=H.runTurn(rt,frames,100,false,true),turns=1;
 assert.equal(result.status,'yield');assert.ok(frames.length);
 while(result.status==='yield'&&turns++<100000)result=H.runTurn(rt,frames,100,false,true);
 assert.equal(result.status,'done');assert.equal(result.value,50005000);assert.ok(turns>1);
});
test('non-tail recursive compiled calls use frame storage rather than the JS stack',()=>{
 const rt=H.newRuntime({input:false}),frames=[H.resolveCallee(F.d_recursive,[10000])(rt,[10000])];
 let result,turns=0;
 do{result=H.runTurn(rt,frames,200,false,true);}while(result.status==='yield'&&++turns<100000);
 assert.equal(result.status,'done');assert.equal(result.value,50005000);assert.ok(rt.maxFrames>=10000);
});
test('tail calls retain a bounded frame stack',()=>{
 const rt=H.newRuntime({input:false}),frames=[H.resolveCallee(F.d_tail_recursive,[100000])(rt,[100000])];
 let result,turns=0;
 do{result=H.runTurn(rt,frames,200,false,true);}while(result.status==='yield'&&++turns<100000);
 assert.equal(result.status,'done');assert.equal(result.value,42);assert.ok(rt.maxFrames<10);
});
test('protected calls preserve catch semantics across frames',()=>{
 assert.equal(F.d_guarded_return(()=>{throw new Error('expected');}),'caught expected');
});
