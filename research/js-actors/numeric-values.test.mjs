import assert from 'node:assert/strict';
let value;const original=console.log;
try{console.log=x=>{assert.equal(value,undefined);value=x;};await import('./out/numeric-values.mjs');}
finally{console.log=original;}
assert.deepEqual(value,{divisionIsFloat:true,divisionIsInteger:false,sameFloat:true,
 differentInteger:true,floatKey:'float',integerKey:'integer',fraction:3.5,decimal:true,exact:true});
console.log('PASS emitted actors retain canonical numeric identity across native expressions');
