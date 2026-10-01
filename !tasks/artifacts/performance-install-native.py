#!/usr/bin/env python3
"""Install the verified cargo release on a fresh inode, retaining the prior NIF.

Run after cargo test/build and after new calling hosts have been emitted with
load? false. No VM upgrade: already-running VMs retain their mapped prior inode.
"""
import json
from pathlib import Path
import os
import shutil
import subprocess
import time

root = Path.cwd()
meta = json.loads(subprocess.check_output(['cargo', 'metadata', '--format-version', '1',
             '--no-deps', '--manifest-path', 'native/lazy_memo/Cargo.toml']))
src = Path(meta['target_directory']) / 'release/liblazy_memo.so'
dest = root / 'priv/native/lazy_memo.so'
backup = root / '.local' / ('native-prior-' + str(time.time_ns()) + '.so')
backup.parent.mkdir(parents=True, exist_ok=True)
if dest.exists():
    shutil.copy2(dest, backup)
tmp = dest.with_name(dest.name + '.next-' + str(os.getpid()))
shutil.copy2(src, tmp)
os.replace(tmp, dest)
print({'installed': str(dest), 'cargo_release': str(src), 'recoverable_prior': str(backup)}, flush=True)
