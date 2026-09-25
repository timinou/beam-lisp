import sys,re
sys.path.insert(0,'/tmp/merge')
from sexp import tokens
def span(s, start):
    d=0
    for k,a,b in tokens(s[start:]):
        if k=='open': d+=1
        elif k=='close':
            d-=1
            if d==0: return start+b
    raise ValueError
p=sys.argv[1]; s=open(p).read(); total=0
pat=re.compile(r'\(erlang/apply :([a-z_]+) :([A-Za-z_!?]+)\s+(?=\(list\b)')
while True:
    changed=False
    for m in pat.finditer(s):
        lst=m.end(); le=span(s,lst); oe=span(s,m.start())
        if s[le:oe-1].strip(): continue
        inner=s[lst+len('(list'):le-1]
        s=s[:m.start()]+f'({m.group(1)}/{m.group(2)}{inner})'+s[oe:]; total+=1; changed=True; break
    if not changed: break
open(p,'w').write(s); print('rewrote',total)
