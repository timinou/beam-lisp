import {test} from 'node:test';
import assert from 'node:assert/strict';
test('emitted BL callbacks use checked arities, closures and suspension evidence',async()=>{
 const log=console.log,seen=[];
 console.log=value=>seen.push(value);
 try{await import('./out/callback-values.mjs');}finally{console.log=log;}
 assert.deepEqual(seen,[{global:3,closure:5,arities:6,refused:true,mixedRefused:true}]);
});
