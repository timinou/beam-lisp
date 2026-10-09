#!/usr/bin/env python3
"""Summarize mechanism receipts; input is run.bl stdout. No wall-time guarantees."""
import argparse,json,math,pathlib,re,statistics
p=argparse.ArgumentParser();p.add_argument('log',type=pathlib.Path);args=p.parse_args()
lines=args.log.read_text().splitlines();out={}
meta=[json.loads(x.removeprefix('RUNTIME_META ')) for x in lines if x.startswith('RUNTIME_META ')]
if meta:out['runtime']=meta[-1]
raw=[json.loads(x.removeprefix('RUNTIME_JSON ')) for x in lines if x.startswith('RUNTIME_JSON ')]
for size in (128,2048):
 data=[r['data'] for r in raw if r['area']=='metadata' and r['data']['inherited']==size]
 if not data:continue
 b=statistics.median(r['us'] for r in data if r['variant']=='baseline')
 c=statistics.median(r['us'] for r in data if r['variant']=='candidate')
 out[f'definition_selection_{size}']={'baseline_us':b,'candidate_us':c,'ratio':b/c,'operations':100}
for size in (100,1000):
 rows=[r['data'] for r in raw if r['area']=='index-read' and r['data']['entities']==size]
 if not rows:continue
 med={v:statistics.median(r['us']/r['operations'] for r in rows if r['variant']==v)
      for v in sorted({r['variant'] for r in rows})}
 build=next(r['data'] for r in raw if r['area']=='index-build' and r['data']['entities']==size)
 turns=sorted(build['value']['advance-calls-us'])
 ordinary=med.get('ordinary')
 out[f'index_{size}']={'read_us':med,'uncached_scan_ratio':med['baseline']/med['candidate'],
   'build_us':build['us'],'steps':len(turns),'p95_advance_us':turns[math.ceil(.95*len(turns))-1],
   'max_advance_us':max(turns),
   'ordinary_read_amortization':math.ceil(build['us']/(ordinary-med['candidate']))
       if ordinary is not None and ordinary>med['candidate'] else None}
 for area in ['index-baseline-writes','index-maintained-writes']:
  samples=[r['data'] for r in raw if r['area']==area and r['data']['entities']==size]
  if samples:out[f'index_{size}'][area+'_us_per_write']=statistics.median(r['us']/r['operations'] for r in samples)
queries=[];leases=[]
for line in lines:
 if not line.startswith('RUNTIME-BENCH '):continue
 def num(k):return int(re.search(':'+k+r' (\d+)',line)[1])
 if ':area :negative-query-reuse' in line:
  queries.append({'variant':re.search(r':variant :(\w+)',line)[1],
    'us':num('elapsed-us'),'reductions':num('reductions'),'rows':num('rows')})
 if ':area :os-lease' in line:leases.append(num('elapsed-us')/num('operations'))
if queries:
 groups={v:[r for r in queries if r['variant']==v] for v in ['baseline','candidate']}
 med={v:{k:statistics.median(r[k] for r in rs) for k in ['us','reductions','rows']} for v,rs in groups.items()}
 out['negative_reuse']={'medians_per_10_calls':med,
   'wall_ratio':med['baseline']['us']/med['candidate']['us'],
   'caller_reductions_ratio':med['baseline']['reductions']/med['candidate']['reductions']}
if leases:out['lease_median_us_per_acquire_release']=statistics.median(leases)
print(json.dumps(out,indent=2))
