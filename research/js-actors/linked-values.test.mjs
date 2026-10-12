import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
test('linked BL calls retain canonical collections, decimals and float identity',async()=>{
 const original=console.log,seen=[];console.log=value=>seen.push(value);
 try{await import('./out/linked-values.mjs');}finally{console.log=original;}
 assert.deepEqual(seen,[{same:true,indirect:true,vector:true,decimal:true,float:true}]);
 const source=await readFile(new URL('./out/linked-values.mjs',import.meta.url),'utf8');
 assert.match(source,/C\.call\(N_[A-Za-z0-9_$]+, \[v_/);
 assert.doesNotMatch(source,/args\.map\(J\.argument\)/);
 assert.doesNotMatch(source,/k:'call', f: N_/);
});
