#!/usr/bin/python3
"""Non-native command model. Every mutation is confined to this mock case."""
from pathlib import Path
import json,os,shutil,sys,subprocess,hashlib
case=Path(os.environ['CONTINUITY_MOCK_CASE']).resolve();cfg=json.loads((case/'config.json').read_text())
state_path=case/'state.json';s=json.loads(state_path.read_text())
name=Path(sys.argv[0]).name;args=sys.argv[1:]
def event(kind,**extra):
 with (case/'events.jsonl').open('a') as out:out.write(json.dumps({'kind':kind,'args':args,**extra})+'\n')
def save():state_path.write_text(json.dumps(s))
def finish(code=0):save();raise SystemExit(code)
OWN='1'*32;FOREIGN='2'*32
event(name)
if name=='mktemp':
 template=args[-1]
 if 'continuity-evidence-' in template:
  if cfg.get('evidence_alloc_fail'):finish(1)
  p=case/'default-evidence';p.mkdir(mode=0o700);s['evidence']=str(p)
  if cfg.get('default_preflight_collision'):(p/'launcher-input.json').write_text('OWN MOCK COLLISION\n')
 else:
  p=case/'sandbox'/'ct-owned';p.mkdir(mode=0o700,parents=True);s['scratch']=str(p)
 print(p);finish()
if name=='rm':
 target=Path(args[-1]).resolve();allowed={str(case/'sandbox'/'ct-owned'),str(case/'default-evidence')}
 assert str(target) in allowed,'Mock refuses deletion outside its exact owned scratch/default evidence'
 event('deletion',path=str(target),journalAlreadyWritten=(case/'evidence'/'server-journal.jsonl').is_file() or (case/'default-evidence'/'server-journal.jsonl').is_file())
 shutil.rmtree(target,ignore_errors=True);finish()
if name in ['bl','accepted-bl']:
 event('launcher-executed',launcher=str(Path(sys.argv[0]).resolve()),arguments=args);finish()
if name=='bl-mem':print('MOCK ONLY: no native memory probe');finish()
if name=='curl':
 s['curlCalls']+=1
 if s['curlCalls']==1:finish(0 if cfg.get('port_busy') else 1)
 finish(0)
if name=='systemd-run':
 s['launchCalls']+=1;s['invocation']=OWN;s['active']='active';s['loaded']='loaded';s['pid']='777'
 for arg in args:
  if arg.startswith('--setenv=CONTINUITY_ROOT='):
   data=Path(arg.split('=',2)[2]).resolve();assert data.is_relative_to(case/'sandbox'),'Mock payload data escaped case'
   data.mkdir(parents=True,exist_ok=True);(data/'live-data.txt').write_text('POSSIBLE LIVE MOCK DATA\n')
 runtime=Path(args[-3]).resolve();assert runtime in [case/'accepted-bl',case/'repo/bin/bl'],'Mock refuses any real BL launcher'
 assert hashlib.sha256(runtime.read_bytes()).hexdigest()==hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'Only exact mock launcher bytes may execute'
 save();subprocess.run([str(runtime),*args[-2:]],check=True,env=os.environ.copy());finish(1 if cfg.get('launch_lost_reply') else 0)
if name=='playwright':
 s['browserStubCalls']+=1
 if cfg.get('foreign_before_cleanup'):s['invocation']=FOREIGN;s['pid']='999'
 finish(cfg.get('browser_exit',0))
if name=='journalctl':
 print(json.dumps({'scope':'MOCK_ONLY_NOT_NATIVE_ACCEPTANCE','_SYSTEMD_INVOCATION_ID':s['invocation'],'MESSAGE':'modeled service journal'}));finish()
if name=='systemctl':
 if 'stop' in args:
  s['stopCalls']+=1;event('stop-invocation',invocation=s['invocation'])
  if cfg.get('stop_fail'):finish(1)
  s['active']='inactive';s['pid']='0'
  if cfg.get('post_stop_live_pid'):s['pid']='777'
  if cfg.get('collected'):s['invocation']='';s['loaded']='not-found'
  if cfg.get('post_stop_foreign'):s['invocation']=FOREIGN;s['active']='active';s['pid']='999'
  if cfg.get('post_stop_empty_loaded'):s['invocation']='';s['loaded']='loaded'
  finish()
 if 'is-active' in args:finish(0 if s['active']=='active' else 3)
 if 'show' in args:
  if 'InvocationID' in args:
   s['invocationReads']+=1
   if cfg.get('capture_fail') and s['invocationReads']==1:finish(1)
   print(s['invocation']);finish()
  values={'ActiveState':s['active'],'LoadState':s['loaded'],'MainPID':s['pid']}
  for key,value in values.items():
   if key in args:print(value);finish()
  print('MemoryPeak=123\nCPUUsageNSec=456');finish()
 raise AssertionError('Unmodeled systemctl command')
raise AssertionError('Unmodeled mock command '+name)
