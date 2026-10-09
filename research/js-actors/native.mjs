// Native expressions use the actor profile's existing values. There is no
// transport, callback scheduler, or second value runtime at this boundary.
import * as H from './host.mjs';
export function argument(value) {
  if(value instanceof H.Flt)return value.v;
  if(value instanceof H.Dec)throw new TypeError("JS interop: decimal needs explicit conversion");
  if (H.isVec(value) || H.isBMap(value) || H.isSet(value) || H.isList(value))
    throw new TypeError('JS interop: BL collection needs #js or bl->js');
  if (H.isFn(value) || H.isTup(value))
    throw new TypeError('JS interop: actor functions cannot be synchronous JS callbacks');
  return value;
}
export const result = value => typeof value === "number" && !Number.isSafeInteger(value) ? H.flt(value) : value;
export const propertyKey = value => {
  const key=argument(value);
  if(typeof key!=='string' && typeof key!=='number' && typeof key!=='symbol')
    throw new TypeError('JS interop: property key must be a string, number or symbol');
  return key;
};
export function blToJS(value) {
  const seen=new WeakSet();
  function convert(x){
    if(H.isKw(x))return H.kwName(x);
    if(x===null || typeof x!=='object')return argument(x);
    if(seen.has(x))throw new TypeError('bl->js: cyclic value');
    seen.add(x);
    try{
      if(H.isVec(x))return H.vecItems(x).map(convert);
      if(H.isList(x))return H.listToArray(x).map(convert);
      if(H.isBMap(x)){
        const out={};
        for(const key of H.listToArray(H.mapKeys(x))){
          const k=H.isKw(key)?H.kwName(key):key;
          if(typeof k!=='string')throw new TypeError('bl->js: object keys must be keywords or strings');
          if(Object.hasOwn(out,k))throw new TypeError('bl->js: duplicate object property');
          Object.defineProperty(out,k,{value:convert(H.mapGet(x,key)),enumerable:true,writable:true,configurable:true});
        }
        return out;
      }
      return argument(x);
    }finally{seen.delete(x);}
  }
  return convert(value);
}
export function jsToBL(value,...options){
  if(options.length%2)throw new TypeError('js->bl: expected option pairs');
  let keywordize=false;
  for(let i=0;i<options.length;i+=2){
    if(!H.isKw(options[i])||H.kwName(options[i])!=='keywordize-keys'||typeof options[i+1]!=='boolean')throw new TypeError('js->bl: unsupported option');
    keywordize=options[i+1];
  }
  const seen=new WeakSet();
  function convert(x){
    if(x===null||typeof x!=='object')return result(x);
    if(seen.has(x))throw new TypeError('js->bl: cyclic value');
    seen.add(x);
    try{
      if(Array.isArray(x))return H.vec(x.map(convert));
      if(Object.getPrototypeOf(x)===Object.prototype||Object.getPrototypeOf(x)===null)
        return H.bmap(Object.entries(x).map(([k,v])=>[keywordize?H.kw(k):k,convert(v)]));
      return x;
    }finally{seen.delete(x);}
  }
  return convert(value);
}
export const convertToJS=blToJS,convertToBL=jsToBL;
