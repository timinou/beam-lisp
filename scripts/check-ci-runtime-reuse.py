#!/usr/bin/env python3
"""Allow an addressed CI runtime to serve a new qualification-only revision.

All unclassified Git changes require a new producer. Test fixtures, qualification
orchestration and prose can change without compiling or restamping the runtime.
The original workflow must separately pass every producer/backend gate.
"""
import argparse
from pathlib import Path
import re
import subprocess

NON_RUNTIME_PREFIXES = ('test/', 'docs/', 'reports/')
NON_RUNTIME_FILES = frozenset((
    'README.md', 'AGENTS.md', '.github/workflows/ci.yml', 'scripts/qualify-candidate.py',
    'scripts/qualify-candidate.bl', 'scripts/ci-test-shard.py',
    'scripts/test-isolation.json', 'scripts/test-durations.json',
    'scripts/check-ci-runtime-reuse.py', 'scripts/wait-ci-producer.py', 'scripts/bl-mem',
))

def runtime_changes(names):
    return [name for name in names
            if name not in NON_RUNTIME_FILES
            and not name.startswith(NON_RUNTIME_PREFIXES + ('scripts/tests/',))]

def producer_configuration(workflow):
    """Native producer steps and toolchain identity stay fixed across reuse."""
    lines = workflow.splitlines()
    start = lines.index('  prepare-linux:')
    end = next((i for i in range(start + 1, len(lines))
                if re.match(r'^  [A-Za-z0-9_-]+:', lines[i])), len(lines))
    producer = [line for line in lines[start:end]
                if not line.startswith('    if:')]
    version = next(line for line in lines if line.startswith('  CI_RUST_VERSION:'))
    return producer, version

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9a-f]{40}(?:[0-9a-f]{24})?', args.base):
        parser.error('base must be an exact producer commit SHA')
    root = Path(__file__).resolve().parent.parent
    subprocess.run(['git', 'cat-file', '-e', args.base + '^{commit}'], cwd=root, check=True)
    # Compare trees, including deletions and rename destinations. No diff
    # heuristic may hide a changed runtime path as a qualification rename.
    raw = subprocess.check_output(['git', 'diff', '--no-renames', '--name-only', '-z', args.base, 'HEAD'], cwd=root)
    names = [name.decode() for name in raw.split(b'\0') if name]
    changed = runtime_changes(names)
    workflow = '.github/workflows/ci.yml'
    previous = subprocess.check_output(['git', 'show', f'{args.base}:{workflow}'], cwd=root, text=True)
    current = subprocess.check_output(['git', 'show', f'HEAD:{workflow}'], cwd=root, text=True)
    if producer_configuration(previous) != producer_configuration(current):
        changed.append(workflow + ' (native producer/toolchain configuration)')
    if changed:
        parser.exit(1, 'A fresh runtime producer is required for: ' + ', '.join(changed) + '\n')
    print(f'Runtime inputs match producer {args.base}; {len(names)} qualification-only paths changed')

if __name__ == '__main__':
    main()
