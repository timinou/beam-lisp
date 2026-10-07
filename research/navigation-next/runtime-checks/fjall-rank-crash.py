#!/usr/bin/env python3
"""One capped BEAM child at a time; crash the actual Fjall owner after commit."""
import os, pathlib, signal, subprocess, selectors, time, fcntl, sys
root=pathlib.Path(__file__).resolve().parents[3]
workspace=root.parent
case=workspace/'tmp'/'fjall-rank-crash'
case.mkdir(parents=True,exist_ok=True)
path=case/f'store-{time.time_ns()}'
complete=len(sys.argv)>1 and sys.argv[1]=='complete'
log=root/('!tasks/evidence/rigorous-navigation/fjall-rank-complete-crash.log' if complete else '!tasks/evidence/rigorous-navigation/fjall-rank-crash.log')
env=os.environ.copy();env['NAV_RANK_CRASH_PATH']=str(path)
env['NAV_RANK_CRASH_COMPLETE']='1' if complete else '0'
cmd=[str(workspace/'check.sh'),'run','research/navigation-next/runtime-checks/fjall-rank-crash.bl']
with log.open('w') as receipt:
    env['NAV_RANK_CRASH_PHASE']='stage'
    child=subprocess.Popen(cmd,cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                           text=True,start_new_session=True,bufsize=1)
    select=selectors.DefaultSelector();select.register(child.stdout,selectors.EVENT_READ)
    marker=False;deadline=time.monotonic()+180
    try:
        while time.monotonic()<deadline and child.poll() is None:
            for key,_ in select.select(timeout=1):
                line=key.fileobj.readline();receipt.write(line);receipt.flush()
                if 'NAV-RANK-COMMITTED-CHECKPOINT' in line:
                    marker=True;break
            if marker:break
        if not marker:raise RuntimeError('stage checkpoint was not reached')
        os.killpg(child.pid,signal.SIGKILL);child.wait(timeout=30)
        receipt.write('SUPERVISOR: SIGKILL after committed hidden checkpoint\n');receipt.flush()
    finally:
        if child.poll() is None:os.killpg(child.pid,signal.SIGKILL);child.wait(timeout=30)
        select.close()
    with (workspace/'check.lock').open('a') as runtime_lock:
        deadline=time.monotonic()+10
        while True:
            try:
                fcntl.flock(runtime_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
                fcntl.flock(runtime_lock,fcntl.LOCK_UN)
                break
            except BlockingIOError:
                if time.monotonic()>=deadline:raise RuntimeError('killed runtime did not release its lock')
                time.sleep(.05)
    env['NAV_RANK_CRASH_PHASE']='resume' 
    result=subprocess.run(cmd,cwd=root,env=env,stdout=receipt,stderr=subprocess.STDOUT,timeout=240)
    if result.returncode:raise RuntimeError(f'recovery exited {result.returncode}')
if 'NAV-RANK-RECOVERY-PASSED' not in log.read_text():raise RuntimeError('missing recovery receipt')
print('actual Fjall owner crash/reopen/rebuild passed; receipt:',log)
