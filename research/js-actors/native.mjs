// Share native conversion semantics; checked callbacks enter the actor machine.
import * as H from './host.mjs';
import {createBoundary} from '../../priv/lib/js/native-values.mjs';
const boundary = createBoundary(H.values,
  (fn, args) => H.isFn(fn) || H.isTup(fn) ? H.invokeSynchronous(fn, args) : fn(...args),
  H.listToArray,
  fn => {
    if ((H.isFn(fn) || H.isTup(fn)) && !H.isSynchronousCallable(fn))
      throw new TypeError('JS interop: callback is not proven non-suspending; use an actor event entrypoint');
  });
export const {argument, result, blToJS, jsToBL, propertyKey, convertToJS, convertToBL} = boundary;
