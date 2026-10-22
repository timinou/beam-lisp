#!/usr/bin/env python3
"""Require every backend gate for an unchanged, reused CI executable."""
import argparse
import json
import os
import subprocess
import time

REQUIRED = frozenset(('public-evidence', 'prepare-linux', 'qualify-linux', 'nix-drop'))

def result(jobs):
    selected = {job['name']: job for job in jobs if job['name'] in REQUIRED}
    failed = [name for name, job in selected.items()
              if job['status'] == 'completed' and job['conclusion'] != 'success']
    if failed:
        raise RuntimeError('Producer backend gate failed: ' + ', '.join(failed))
    return (set(selected) == REQUIRED
            and all(job['status'] == 'completed' and job['conclusion'] == 'success'
                    for job in selected.values()))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', required=True, type=int)
    args = parser.parse_args()
    repo = os.environ['GITHUB_REPOSITORY']
    for _ in range(125):
        data = json.loads(subprocess.check_output(
            ['gh', 'api', f'repos/{repo}/actions/runs/{args.run}/jobs?per_page=100']))
        if result(data['jobs']):
            print(f'All runtime producer/backend gates passed: https://github.com/{repo}/actions/runs/{args.run}')
            return
        print('Waiting for original runtime backend gates', flush=True)
        time.sleep(60)
    raise SystemExit('Producer backend gates did not complete within their qualification ceiling')

if __name__ == '__main__':
    main()
