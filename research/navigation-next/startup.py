"""One capped cold VM, then 20 evals inside it; no daemon left running."""
import json
import re
import subprocess
import time
from pathlib import Path
root=Path(__file__).resolve().parents[2]
start_ms=time.time_ns()//1000000
result=subprocess.run([
 'systemd-run','--user','--collect','--wait','--pipe',
 '--unit=bl-next-startup-prototype-1007',f'--working-directory={root}',
 '--property=MemoryMax=8G','--property=MemorySwapMax=2G','--property=RuntimeMaxSec=300',
 'env','TMPDIR=/home/user/.cache/bl-authorized-navigation-tmp',
 './bin/bl','test','research/navigation-next/startup.bl','research/navigation-next/emitted-descriptor-test.bl'],text=True,capture_output=True)
output=result.stdout+result.stderr
(root/'!tasks/evidence/navigation-next/startup-raw.log').write_text(output)
if result.returncode:
 print(output);raise SystemExit(result.returncode)
entry=re.search(r'NEXT-ENTRY-MS\s+(\d+)',output)
warm=re.search(r'NEXT-WARM-20-US\s+(\d+)',output)
if not entry or not warm:raise RuntimeError('measurement markers missing')
print(json.dumps({'launch_to_user_entry_ms':int(entry[1])-start_ms,
                  'warm_20_eval_us':int(warm[1]),
                  'total_process_ms':time.time_ns()//1000000-start_ms,
                  'cold_samples':1,'browser_latency':False,
                  'note':'includes launcher/systemd/module loading; warm eval still compiles expressions'}))
