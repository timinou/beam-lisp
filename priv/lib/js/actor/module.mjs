// Compiler control adapter: all language semantics remain compiled BL.
import * as H from './host.mjs';
import * as V from '../rt.mjs';
const moduleRuntime=H.newRuntime({input:false});
function makeFn(name,arity,body,runtime=moduleRuntime,synchronous=false){
 const callable=H.blFn(name,new Map([[arity,body]]),null,runtime,synchronous,
  (frame,args)=>H.invokeImmediate(frame,args.length>arity?args.slice(0,arity):args,runtime,50000000));
 Object.defineProperty(callable,'length',{value:arity});
 return callable;
}
export function multi(name,arms,min,rest,runtime=moduleRuntime){
 const factories=new Map([...arms].map(([n,f])=>[n,H.resolveCallee(f,new Array(n))]));
 const variadic=rest?[min,H.resolveCallee(rest,new Array(min+1))]:null;
 const proven=[...arms.values()].every(H.isSynchronousCallable)&&(!rest||H.isSynchronousCallable(rest));
 const callable=H.blFn(name,factories,variadic,runtime,proven,
  (frame,args)=>H.invokeImmediate(frame,args,runtime,50000000));
 if(rest)callable.v=rest;
 return callable;
}
export function* call(f,args,invoke,src=null,tail=false){
 if(typeof f==='function'||V.isMultiCallable(f))return yield {__step:true,k:tail?'tail':'call',f,args,src};
 return yield {__step:true,k:tail?'tail':'call',f:invoke,args:[f,V.listFromArray(args)],src};
}
export function* callList(f,args,invoke,src=null,tail=false){return yield* call(f,H.listToArray(args),invoke,src,tail);}

export const exceptionKind=H.exKind,exceptionTrace=H.exTrace;
export function exceptionValue(error){return H.isRaise(error)?error.reason:error;}

export function fn(name,arity,body,synchronous=false){return makeFn(name,arity,body,moduleRuntime,synchronous);}

export function bind(runtime){return {fn:(name,arity,body,synchronous=false)=>makeFn(name,arity,body,runtime,synchronous),multi:(...args)=>multi(...args,runtime),call,callList,exceptionKind,exceptionValue,exceptionTrace};}
