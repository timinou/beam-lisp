#!/usr/bin/env python3
"""Synchronize TestRT's embedded test library with priv/std/test.bl."""
import argparse
import json
from pathlib import Path
import sys

START = '  ;; @@EMBED-TEST-LIB@@\n'
END = '\n  ;; @@/EMBED-TEST-LIB@@'


def synchronize(root, check=False):
    host = root / 'priv/host/test_rt.bl'
    source = host.read_text()
    if source.count(START) != 1 or source.count(END) != 1:
        raise ValueError('TestRT must contain exactly one embedded-library region')
    before, rest = source.split(START)
    _, after = rest.split(END)
    library = (root / 'priv/std/test.bl').read_text()
    updated = before + START + json.dumps(library, ensure_ascii=False) + END + after
    if source == updated:
        return True
    if check:
        print('Embedded test library differs; run scripts/embed-test-library.py and regenerate the floor.', file=sys.stderr)
        return False
    host.write_text(updated)
    return True


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    raise SystemExit(0 if synchronize(Path(__file__).resolve().parents[1], args.check) else 1)
