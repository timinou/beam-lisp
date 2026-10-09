#!/usr/bin/env python3
"""Real compiler/loader prototype. Fresh VMs; source/artifact ABBA; home scratch."""
import argparse,hashlib,json,os,pathlib,resource,shutil,signal,statistics,subprocess,tempfile,time
P=argparse.ArgumentParser();P.add_argument('--app',type=pathlib.Path,required=True);P.add_argument('--samples',type=int,default=4);P.add_argument('--reuse',type=pathlib.Path);args=P.parse_args()
HERE=pathlib.Path(__file__).resolve().parent
OUT=args.reuse or pathlib.Path(tempfile.mkdtemp(prefix='application-aot-',dir=pathlib.Path.home()/'tmp'))
SOURCE=OUT/'source';SOURCE.mkdir(exist_ok=True);neutral=OUT/'neutral';neutral.mkdir(exist_ok=True)
(neutral/'env.bl').write_text('{:bl "build:24db70e9" :env {"BL_DAEMON" "off"}}\n')
for p in [args.app/'apps/knowledger/src/knowledger/dates.bl',args.app/'apps/knowledger/src/knowledger/i18n.bl',*sorted((args.app/'apps/knowledger/src/knowledger/i18n/lexicon').glob('*.bl'))]:
 dest=SOURCE/'knowledger'/p.relative_to(args.app/'apps/knowledger/src/knowledger');dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dest)
f=SOURCE/'followups/fixture';f.mkdir(parents=True,exist_ok=True)
(f/'leaf.bl').write_text('(ns followups.fixture.leaf)\n'+''.join(f'(defn f{i} [x] (+ x {i}))\n' for i in range(256)))
(f/'application.bl').write_text('''(ns followups.fixture.application (:require [followups.fixture.leaf :as leaf]))
(def setting (do (File/write! (System/get_env "FOLLOWUP_MARK") "init\\n" (list :append)) (System/get_env "FOLLOWUP_VALUE")))
(defn answer [] [setting (leaf/f255 0)])
''')
def limit():resource.setrlimit(resource.RLIMIT_AS,(8*1024**3,8*1024**3))
def run(mode,number):
 mark=OUT/f'{mode}-{number}.mark';mark.unlink(missing_ok=True);env=os.environ.copy();env.pop('BL_USE',None)
 (neutral/'env.bl').write_text('{:bl \"build:24db70e9\" :env {\"BL_DAEMON\" \"off\"} :paths '+ ('['+json.dumps(str(SOURCE))+']' if mode!='artifact' else '[]')+'}\n')
 env.update(TMPDIR=str(OUT),FOLLOWUP_MODE=mode,FOLLOWUP_ROOT=str(OUT),FOLLOWUP_VALUE=f'target-{number}',FOLLOWUP_MARK=str(mark),BEAM_LISP_AOT_STRICT='1' if mode=='artifact' else '0',BEAM_LISP_AOT_REPAIR='off' if mode=='source' else 'on')
 logfile=OUT/f'{mode}-{number}.log';started=time.monotonic()
 with logfile.open('w') as log:
  proc=subprocess.Popen(['bl','run',str(HERE/'application-aot.bl')],cwd=neutral,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,preexec_fn=limit)
  try:code=proc.wait(timeout=600)
  finally:
   try:os.killpg(proc.pid,signal.SIGTERM)
   except ProcessLookupError:pass
   if proc.poll() is None:
    try:proc.wait(timeout=10)
    except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
 if code:raise RuntimeError(f'{mode} failed: {logfile}')
 records=[json.loads(line.split('FOLLOWUP_JSON ',1)[1]) for line in logfile.read_text().splitlines() if line.startswith('FOLLOWUP_JSON ')]
 assert records,(mode,logfile)
 return {'mode':mode,'process_seconds':time.monotonic()-started,'records':[r for r in records if r['mode']!='diagnostic'],'diagnostics':[r for r in records if r['mode']=='diagnostic'],'log':str(logfile)}
print('Evidence:',OUT,flush=True)
try:
 build=run('build',0) if not args.reuse else {'records':[json.loads(x.split('FOLLOWUP_JSON ',1)[1]) for x in (OUT/'build-0.log').read_text().splitlines() if x.startswith('FOLLOWUP_JSON ')]}
 # Producer directory is not used by relocated consumers.
 package=OUT/'package';manifest={str(p.relative_to(package)):hashlib.sha256(p.read_bytes()).hexdigest() for p in package.rglob('*.beam')}
 assert manifest
 (package/'manifest.json').write_text(json.dumps({'compiler':build['records'][0]['compiler'],'files':manifest},indent=2)+'\n')
 relocated=OUT/'relocated';shutil.copytree(package,relocated);shutil.rmtree(package);shutil.move(relocated,package)
 def validate():
  declared=json.loads((package/'manifest.json').read_text())['files'];actual={str(p.relative_to(package)):hashlib.sha256(p.read_bytes()).hexdigest() for p in package.rglob('*.beam')}
  return declared==actual
 assert validate();beam=next(package.rglob('*.beam'));raw=beam.read_bytes();beam.write_bytes(raw+b'tamper');assert not validate();beam.write_bytes(raw);assert validate()
 samples=[]
 for i,mode in enumerate((['source','artifact','artifact','source']*((args.samples+1)//2))[:args.samples*2]):
  assert validate();sample=run(mode,i+1);samples.append(sample);print(mode,sample['records'][0],flush=True)
 med={}
 for mode in ['source','artifact']:
  ss=[s for s in samples if s['mode']==mode]
  med[mode]={'load_us':statistics.median(s['records'][0]['us'] for s in ss),'reductions':statistics.median(s['records'][0]['reductions'] for s in ss),'process_seconds':statistics.median(s['process_seconds'] for s in ss)}
 result={'status':'passed','sdk':'24db70e9','app_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=args.app,text=True).strip(),'scope':'16 real Knowledger date/i18n libraries plus two generated fixture namespaces, not full app/server startup','build':build,'samples':samples,'medians':med,'package_beams':len(manifest),'package_bytes':sum(p.stat().st_size for p in package.rglob('*') if p.is_file()),'checks':['relocated package','source-free strict artifact load','target-environment value','initializer once after repeated require','byte tamper rejected before launch','unchanged build compiles zero'],'cache':'fresh VM, existing SDK cache; source control explicitly disables AOT repair (compilation baseline), artifact is source-free; shared filesystem cache may warm'}
 (OUT/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result['medians']),flush=True)
except BaseException as exc:
 (OUT/'failure.json').write_text(json.dumps({'status':'failed','error':repr(exc)},indent=2)+'\n');raise
