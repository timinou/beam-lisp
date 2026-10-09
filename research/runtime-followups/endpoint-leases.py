#!/usr/bin/env python3
"""Private OS-owned endpoint prototype; never touches product endpoints."""
import fcntl,json,os,pathlib,signal,socket,statistics,subprocess,sys,tempfile,time,uuid

def acquire(root):
 fd=os.open(root/'lease.lock',os.O_CREAT|os.O_RDWR,0o600)
 try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
 except BlockingIOError:os.close(fd);return None
 return fd

def manifest(root):
 try:return json.loads((root/'endpoint.json').read_text())
 except FileNotFoundError:return None

def cleanup(root,token,inode):
 current=manifest(root)
 if not current or current['token']!=token:return False
 p=root/current['socket']
 if p.name!=token+'.sock' or p.parent!=root:raise ValueError('outside private endpoint')
 try:
  if p.lstat().st_ino!=inode:return False
  p.unlink()
 except FileNotFoundError:pass
 (root/'endpoint.json').unlink(missing_ok=True);return True

def owner(root):
 fd=acquire(root)
 if fd is None:print('busy',flush=True);return
 old=manifest(root)
 if old:
  token=old['token'];p=root/old['socket']
  if p.name!=token+'.sock' or len(token)!=16 or any(c not in '0123456789abcdef' for c in token):raise ValueError('invalid stale identity')
  p.unlink(missing_ok=True)
 token=uuid.uuid4().hex[:16];p=root/(token+'.sock');sock=socket.socket(socket.AF_UNIX);sock.bind(str(p));sock.listen(1);inode=p.lstat().st_ino
 tmp=root/(token+'.json');tmp.write_text(json.dumps({'token':token,'socket':p.name}));os.replace(tmp,root/'endpoint.json')
 print(json.dumps({'token':token,'inode':inode}),flush=True)
 try:
  for line in sys.stdin:
   if line.strip()=='stop':break
   if line.startswith('stale '):print(json.dumps({'cleaned':cleanup(root,line.split()[1],inode),'current':manifest(root)['token']}),flush=True)
 finally:
  cleanup(root,token,inode);sock.close();os.close(fd)

def start(root):
 p=subprocess.Popen([sys.executable,__file__,'--owner',str(root)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 line=p.stdout.readline()
 if not line:raise RuntimeError(p.stderr.read())
 return p,json.loads(line)

def stop(p):
 if p.poll() is None:
  p.stdin.write('stop\n');p.stdin.flush();p.wait(timeout=5)
 assert p.returncode==0,p.stderr.read()

if len(sys.argv)>1:
 owner(pathlib.Path(sys.argv[2]));sys.exit(0)
root=pathlib.Path(tempfile.mkdtemp(prefix='endpoint-lease-',dir=pathlib.Path.home()/'tmp'));os.chmod(root,0o700)
owned=[];checks=[];recovery=[]
try:
 first,identity=start(root);owned.append(first)
 # A paused live owner must not be evicted by elapsed time or a PID guess.
 os.kill(first.pid,signal.SIGSTOP)
 fd=acquire(root);assert fd is None;checks.append('paused live owner refuses concurrent acquisition')
 os.kill(first.pid,signal.SIGCONT)
 oldtoken=identity['token'];first.kill();first.wait(timeout=5)
 assert manifest(root)['token']==oldtoken
 for i in range(8):
  started=time.perf_counter_ns();current,identity=start(root);owned.append(current)
  recovery.append((time.perf_counter_ns()-started)/1e6)
  assert identity['token']!=oldtoken
  current.stdin.write('stale '+oldtoken+'\n');current.stdin.flush();reply=json.loads(current.stdout.readline())
  assert reply=={'cleaned':False,'current':identity['token']}
  probe=socket.socket(socket.AF_UNIX);probe.connect(str(root/(identity['token']+'.sock')));probe.close()
  oldtoken=identity['token']
  if i<7:current.kill();current.wait(timeout=5)
  else:stop(current)
 checks+=['crash releases OS lease without TTL','new identity published atomically','stale cleanup preserves replacement','graceful cleanup removes manifest/socket']
 assert not (root/'endpoint.json').exists()
 samples=[]
 for _ in range(8):
  t=time.perf_counter_ns()
  for i in range(1000):
   fd=acquire(root);assert fd is not None;os.close(fd)
  samples.append((time.perf_counter_ns()-t)/1000/1000)
 result={'status':'passed','scope':'private Linux flock + Unix socket adapter, not production vm endpoint integration','checks':checks,'acquisition_us_per_op':samples,'acquisition_median_us':statistics.median(samples),'recovery_including_new_python_process_ms':recovery,'recovery_median_ms':statistics.median(recovery),'lease_file_never_unlinked':(root/'lease.lock').exists(),'scratch':str(root)}
 (root/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
finally:
 for p in owned:
  if p.poll() is None:p.kill();p.wait(timeout=5)
