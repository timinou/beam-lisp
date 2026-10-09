let last,calls=0;
export function identity(value){last=value;calls++;return value;}
export const lastInput=()=>last;
export const callCount=()=>calls;
