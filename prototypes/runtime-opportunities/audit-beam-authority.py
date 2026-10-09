#!/usr/bin/env python3
"""Offline evidence probe: compare BEAM Attr stamps with latest build facts.
Does not execute code or establish source freshness. Run before/after refresh.
"""
import argparse, json, pathlib, re, struct

class ETF:
 def __init__(self, data): self.data=data; self.pos=0
 def take(self,n):
  r=self.data[self.pos:self.pos+n];self.pos+=n
  if len(r)!=n:raise ValueError('truncated ETF')
  return r
 def integer(self,n):return int.from_bytes(self.take(n),'big')
 def term(self):
  tag=self.integer(1)
  if tag==97:return self.integer(1)
  if tag==98:return int.from_bytes(self.take(4),'big',signed=True)
  if tag in (100,118,119):return self.take(self.integer(1 if tag==119 else 2)).decode('utf-8' if tag!=100 else 'latin1')
  if tag in (104,105):return tuple(self.term() for _ in range(self.integer(1 if tag==104 else 4)))
  if tag==106:return []
  if tag==107:return list(self.take(self.integer(2)))
  if tag==108:
   values=[self.term() for _ in range(self.integer(4))]
   if self.term()!=[]:raise ValueError('improper ETF list')
   return values
  if tag==109:return self.take(self.integer(4)).decode('utf-8')
  if tag in (110,111):
   size=self.integer(1 if tag==110 else 4);sign=self.integer(1)
   return int.from_bytes(self.take(size),'little')*(-1 if sign else 1)
  if tag==70:return struct.unpack('>d',self.take(8))[0]
  raise ValueError(f'unsupported ETF tag {tag}')

def attributes(path):
 data=path.read_bytes()
 if data[:4]!=b'FOR1' or data[8:12]!=b'BEAM':raise ValueError('not BEAM')
 pos=12
 while pos+8<=len(data):
  tag=data[pos:pos+4];size=int.from_bytes(data[pos+4:pos+8],'big');chunk=data[pos+8:pos+8+size]
  if tag==b'Attr':
   etf=ETF(chunk)
   if etf.integer(1)!=131:raise ValueError('unsupported ETF version')
   result=dict(etf.term())
   if etf.pos!=len(chunk):raise ValueError('trailing ETF bytes')
   return result
  pos+=8+(size+3)//4*4
 return {}

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('log',type=pathlib.Path);parser.add_argument('ebin',type=pathlib.Path)
 args=parser.parse_args();latest={}
 pattern=re.compile(r'^\[:build/built "([^"]+)" "([^"]+)" "([^"]+)" \[([^\]]*)\] (true|false)\]')
 for line in args.log.read_text().splitlines():
  match=pattern.match(line)
  if match:latest[match[1]]=match.groups()
 checked=[];mismatches=[];unstamped=[]
 for path,key,compiler,modules,cached in latest.values():
  for mod in re.findall(r'"([^"]+)"',modules):
   attrs=attributes(args.ebin/(mod+'.beam'))
   if 'bl_source_hash' not in attrs:unstamped.append(mod);continue
   row=dict(path=path,module=mod,expected_source=key,actual_source=attrs['bl_source_hash'],expected_compiler=compiler,actual_compiler=attrs.get('bl_compiler_key'),cached=cached=='true')
   checked.append(row)
   if attrs['bl_source_hash'] not in (key,[key]) or attrs.get('bl_compiler_key') not in (compiler,[compiler]):mismatches.append(row)
 print(json.dumps(dict(scope='Artifact stamps against recorded build facts only; not live source or strict execution validation.',checked=len(checked),mismatches=mismatches,unstamped_count=len(unstamped)),indent=2))

if __name__=='__main__':main()
