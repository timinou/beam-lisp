#!/usr/bin/env python3
"""Additional controls, separate from previously collected timing samples."""
import argparse,json,os,pathlib,resource,signal,subprocess
p=argparse.ArgumentParser();p.add_argument('root',type=pathlib.Path);a=p.parse_args();root=a.root
here=pathlib.Path(__file__).resolve().parent;neutral=root/'neutral';source=root/'source';package=root/'package'
release=json.loads((package/'manifest.json').read_text());compiler=release['compiler']
def limit():resource.setrlimit(resource.RLIMIT_AS,(8*1024**3,8*1024**3))
checks=[]
def run(label,script,paths,compiler_key,success):
 mark=root/f'guard-{label}.mark';mark.unlink(missing_ok=True)
 (neutral/'env.bl').write_text('{:bl "build:24db70e9" :env {"BL_DAEMON" "off"} :paths '+json.dumps(paths)+'}\n')
 env=os.environ.copy();env.pop('BL_USE',None)
 env.update(TMPDIR=str(root),FOLLOWUP_ROOT=str(root),FOLLOWUP_MODE='artifact',FOLLOWUP_MARK=str(mark),FOLLOWUP_VALUE='guard-target',FOLLOWUP_COMPILER=compiler_key,BEAM_LISP_AOT_STRICT='1')
 log=root/f'guard-{label}.log'
 with log.open('w') as out:
  child=subprocess.Popen(['bl','run',str(here/script)],cwd=neutral,env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True,preexec_fn=limit)
  try:code=child.wait(timeout=600)
  finally:
   try:os.killpg(child.pid,signal.SIGTERM)
   except ProcessLookupError:pass
   if child.poll() is None:
    try:child.wait(timeout=10)
    except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
 assert (code==0)==success,(label,code,log)
 if not success:assert not mark.exists(),label
 checks.append({'control':label,'exit':code,'log':str(log)})
# Producer compiler and exact inventory are independently checked before launching.
original=(package/'manifest.json').read_text()
wrong=json.loads(original);wrong['compiler']='wrong'
(package/'manifest.json').write_text(json.dumps(wrong))
try:assert json.loads((package/'manifest.json').read_text())['compiler']!=compiler
finally:(package/'manifest.json').write_text(original)
run('compiler-match','application-aot.bl',[],compiler,True)
run('compiler-mismatch','application-aot.bl',[],'wrong',False)
fixture=source/'followups/fixture/application.bl';raw=fixture.read_text()
try:
 assert '(leaf/f255 0)' in raw
 fixture.write_text(raw.replace('(leaf/f255 0)','(leaf/f254 0)'))
 run('stale-source','application-negative.bl',[str(source)],compiler,True)
finally:fixture.write_text(raw)
result={'status':'passed','checks':checks,'scope':'additional release compiler/runtime mismatch and stale live-source controls, not benchmark trials'}
(root/'guard-results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
