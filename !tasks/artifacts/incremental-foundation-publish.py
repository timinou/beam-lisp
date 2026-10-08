#!/usr/bin/env python3
"""Publish an officially generated candidate without truncating cache hardlinks.

The old floor and overwritten build entries remain recoverable under .local.
Run from the repository root after cold candidate verification. No source or
manifest hashes are synthesized here. Verification is delegated to Bootstrap
and bl-stage-hosts before this publication; no manifest bytes are synthesized
or rewritten, and the destination's own build state is never overwritten.

The image's build STATE (`build.log`, `compile.beam_lisp`) is NOT published: it
is keyed by the absolute source paths of the tree the image was built in, so a
staged image's state does not describe this tree. The destination keeps its own
state (or none) and the next full build reconciles it.
"""
import argparse
import os
from pathlib import Path
import shutil
import time

p = argparse.ArgumentParser()
p.add_argument('image', type=Path)
p.add_argument('seed', type=Path)
p.add_argument('--publish', action='store_true')
a = p.parse_args()
root = Path.cwd()
dest = (root / 'build').resolve()
seed = root / 'priv/bootstrap/seed'
# The image's build STATE is keyed by the absolute source paths of the tree it was
# built in. A staged image is built over another tree, so publishing its
# `build.log`/`compile.beam_lisp` would leave the destination's build state
# describing paths that do not exist here — and the next full build reads every
# recorded path it is not handed as DELETED, so it would delete the beams it has
# just built under the real paths. The destination keeps its own state; a
# destination that has none rebuilds once, honestly.
STATE_FILES = {'build.log', 'compile.beam_lisp'}
image_files = [x for x in a.image.iterdir()
               if x.is_file() and not x.name.startswith('.bootstrap_staging')]
state_files = [x.name for x in image_files if x.name in STATE_FILES]
files = sorted(x for x in image_files if x.name not in STATE_FILES)
print({'build_link': str(root / 'build'), 'build_target': str(dest),
       'lib_target': str((root / '.bl/lib/beam_lisp-0.1.0/ebin').resolve()),
       'image_files': len(files), 'state_files_kept_local': sorted(state_files),
       'seed_files': len(list(a.seed.iterdir()))}, flush=True)
if not a.publish:
    raise SystemExit(0)
backup = root / '.local' / ('foundation-publication-' + str(time.time_ns()))
backup.mkdir(parents=True)
next_seed = seed.with_name('seed.next-' + str(os.getpid()))
shutil.copytree(a.seed, next_seed)
# Retain the old floor; its move and the new floor's move are same-filesystem.
os.rename(seed, backup / 'seed')
try:
    os.rename(next_seed, seed)
except BaseException:
    os.rename(backup / 'seed', seed)
    raise
(backup / 'build').mkdir()
dest.mkdir(parents=True, exist_ok=True)
for src in files:
    out = dest / src.name
    if out.exists():
        if out.read_bytes() == src.read_bytes():
            continue
        shutil.copy2(out, backup / 'build' / src.name)
    tmp = out.with_name(out.name + '.publication-' + str(os.getpid()))
    shutil.copy2(src, tmp)
    os.replace(tmp, out)  # new inode; never changes a hardlinked AOT cache entry
print({'published': str(dest), 'recoverable_prior_floor_and_entries': str(backup)}, flush=True)
