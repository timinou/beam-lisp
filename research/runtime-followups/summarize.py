#!/usr/bin/env python3
"""Extract observed medians; preserve samples and avoid treating warmup as a trial."""
import argparse, collections, json, pathlib, statistics
p=argparse.ArgumentParser();p.add_argument('logs',nargs='+',type=pathlib.Path);a=p.parse_args()
rows=[]
for file in a.logs:
 for line in file.read_text().splitlines():
  if line.startswith('FOLLOWUP_JSON '):
   row=json.loads(line.split('FOLLOWUP_JSON ',1)[1])
   if 'area' not in row or 'data' not in row:continue # AOT has its own result schema
   row['log']=file.name;rows.append(row)
groups=collections.defaultdict(list); realm_warmup=True
for row in rows:
 area,d=row['area'],row['data']
 if row['log']=='realm-probe.log':continue # diagnostic compile trace, not timed ABBA trials
 if area=='realm' and realm_warmup:
  realm_warmup=False;continue
 if 'variant' in d:
  groups[(area,d.get('entities',d.get('inherited')),d['variant'])].append(d)
summary=[]
for (area,size,variant),samples in groups.items():
 entry=dict(area=area,size=size,variant=variant,samples=len(samples))
 for key in ['us','reductions','store-rows','operations']:
  if all(key in s for s in samples):entry[key]=statistics.median(s[key] for s in samples)
 summary.append(entry)
break_even=[]
for row in rows:
 if row['area']!='index-build':continue
 d=row['data'];n=d['entities']
 ss={x['variant']:x for x in summary if x['area']=='index-read' and x['size']==n}
 if len(ss)==2:
  saved=ss['baseline']['us']/ss['baseline']['operations']-ss['candidate']['us']/ss['candidate']['operations']
  break_even.append(dict(entities=n,stage_build_us=d['us'],saving_us_per_read=saved,read_only_break_even=d['us']/saved if saved>0 else None,max_writer_step_us=d['value']['max-writer-step-us']))
print(json.dumps(dict(medians=summary,index_economics=break_even,observations=rows),indent=2))
