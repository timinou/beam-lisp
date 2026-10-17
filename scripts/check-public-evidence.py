#!/usr/bin/env python3
"""Bounded new-Git-blob check for accidentally archived private Lisp source units.

This is a deliberately narrow publication gate, not a secret scanner or a Lisp
interpreter. It never extracts archives, evaluates source, or prints source text.
"""
from __future__ import annotations
import argparse
import bz2
import io
import lzma
import os
from pathlib import PurePosixPath
import re
import subprocess
import sys
import tarfile
import zlib

PRIVATE_ROOTS = frozenset(('knowledger', 'foundry'))
MAX_BLOB = 64 * 1024 * 1024
MAX_MEMBER = 16 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024
MAX_MEMBERS = 16384
MAX_DEPTH = 3
MAX_OBJECTS = 65536
MAX_GIT_OUTPUT = 8 * 1024 * 1024
MAX_TOKENS = 262144
SHA = re.compile(r'^[0-9a-f]{40}(?:[0-9a-f]{24})?$')
ARCHIVE_SUFFIXES = ('.tar', '.tar.gz', '.tgz', '.gz', '.bz2', '.xz', '.zip', '.jar', '.whl', '.zst', '.7z', '.rar')
UNKNOWN_MAGIC = (b'\x28\xb5\x2f\xfd', b'7z\xbc\xaf\x27\x1c', b'Rar!')

class Refusal(Exception):
    pass

class Budget:
    def __init__(self):
        self.bytes = 0
        self.members = 0
    def account(self, size):
        self.bytes += size
        if size > MAX_BLOB or self.bytes > MAX_TOTAL:
            raise Refusal('evidence byte budget exceeded')
    def member(self, size):
        self.members += 1
        if self.members > MAX_MEMBERS or size > MAX_MEMBER:
            raise Refusal('archive member budget exceeded')

def private_namespace(data):
    """Find an actual leading unquoted (ns NAME ...) unit, not quoted snippets.

    Source units may have license/comments/BOM and namespace metadata. Ordinary
    probe units declare their own namespace first; strings/quoted Ns examples
    later in the unit do not count as the unit's declaration.
    """
    try:
        text = data.decode('utf-8-sig')
    except UnicodeDecodeError:
        return None
    if text.startswith('#!'):
        text = text.partition('\n')[2]
    i, steps = 0, 0
    def token():
        nonlocal i, steps
        steps += 1
        if steps > MAX_TOKENS:
            raise Refusal('source token budget exceeded')
        while i < len(text):
            if text[i].isspace() or text[i] == ',':
                i += 1
            elif text[i] == ';':
                end = text.find('\n', i)
                i = len(text) if end < 0 else end + 1
            else:
                break
        if i >= len(text):
            return None
        c = text[i]
        if c in '()[]{}\'`^~@':
            i += 1
            return c
        if c == '"':
            i += 1
            while i < len(text):
                c = text[i]; i += 1
                if c == '\\':
                    i += 1
                elif c == '"':
                    return ('string',)
            return ('invalid-string',)
        start = i
        while i < len(text) and not text[i].isspace() and text[i] not in ',;()[]{}\'`^~@"':
            i += 1
        return text[start:i]
    def metadata():
        first = token()
        if first not in ('(', '[', '{'):
            return first is not None
        pending = [ {'(': ')', '[': ']', '{': '}'}[first] ]
        while pending:
            t = token()
            if t is None:
                return False
            if isinstance(t, str) and t in ('(', '[', '{'):
                pending.append({'(': ')', '[': ']', '{': '}'}[t])
                if len(pending) > 128:
                    raise Refusal('source metadata depth exceeded')
            elif isinstance(t, str) and t in (')', ']', '}'):
                if pending.pop() != t:
                    return False
        return True
    t = token()
    while t == '^':
        if not metadata():
            return None
        t = token()
    if t != '(' or token() != 'ns':
        return None
    name = token()
    while name == '^':
        if not metadata():
            return None
        name = token()
    if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z_][\w.!?+*/-]*', name):
        return None
    if name.split('.', 1)[0] in PRIVATE_ROOTS:
        return name
    return None

def safe_member(name):
    path = PurePosixPath(name)
    if (not name or path.is_absolute() or '..' in path.parts or '\\' in name
            or any(ord(c) < 32 or ord(c) == 127 for c in name)
            or re.match(r'^[A-Za-z]:', name)):
        raise Refusal('unsafe archive member path')

def unpack(data, kind, remaining):
    decoder = {'gzip': lambda: zlib.decompressobj(16 + zlib.MAX_WBITS),
               'bzip2': bz2.BZ2Decompressor, 'xz': lzma.LZMADecompressor}[kind]()
    try:
        output = decoder.decompress(data, max(0, remaining) + 1)
    except (zlib.error, OSError, EOFError, lzma.LZMAError) as error:
        raise Refusal('invalid compressed evidence') from error
    if len(output) > remaining:
        raise Refusal('expanded evidence byte budget exceeded')
    if not decoder.eof or decoder.unused_data:
        raise Refusal('truncated or concatenated compressed evidence')
    return output

def tar_header(data):
    if len(data) < 512 or not any(data[:512]):
        return False
    try:
        tarfile.TarInfo.frombuf(data[:512], 'utf-8', 'surrogateescape')
        return True
    except tarfile.TarError:
        return False

def scan_bytes(data, label='blob', budget=None, depth=0):
    budget = budget or Budget()
    budget.account(len(data))
    ns = private_namespace(data)
    if ns:
        raise Refusal('private Source unit declaration: ' + ns)
    kind = next((kind for magic, kind in ((b'\x1f\x8b', 'gzip'), (b'BZh', 'bzip2'), (b'\xfd7zXZ\x00', 'xz'))
                 if data.startswith(magic)), None)
    is_tar, is_zip = tar_header(data), data.startswith((b'PK\x03\x04', b'PK\x05\x06', b'PK\x07\x08'))
    known_name = label.lower().endswith(ARCHIVE_SUFFIXES)
    if kind or is_tar or is_zip or known_name or data.startswith(UNKNOWN_MAGIC):
        if depth >= MAX_DEPTH:
            raise Refusal('nested evidence archive depth exceeded')
        if kind:
            output = unpack(data, kind, min(MAX_BLOB, MAX_TOTAL - budget.bytes))
            # A compressed text unit is inspected too; unknown binary payloads
            # cannot silently count as inspected archive contents.
            if not tar_header(output) and not output.startswith(b'PK'):
                ns = private_namespace(output)
                if ns:
                    raise Refusal('private Source unit declaration: ' + ns)
                try:
                    output.decode('utf-8')
                except UnicodeDecodeError as error:
                    raise Refusal('unsupported compressed evidence payload') from error
            scan_bytes(output, label.removesuffix('.gz').removesuffix('.bz2').removesuffix('.xz'), budget, depth + 1)
            return
        if is_tar:
            try:
                with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as archive:
                    names = set()
                    for entry in archive:
                        safe_member(entry.name)
                        if entry.name in names:
                            raise Refusal('duplicate archive member')
                        names.add(entry.name)
                        if entry.type not in (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE) or (entry.isdir() and entry.size):
                            raise Refusal('unsafe archive member type')
                        budget.member(entry.size)
                        if entry.isreg():
                            source = archive.extractfile(entry)
                            if source is None:
                                raise Refusal('unreadable archive member')
                            payload = source.read(entry.size + 1)
                            if len(payload) != entry.size:
                                raise Refusal('truncated archive member')
                            scan_bytes(payload, entry.name, budget, depth + 1)
                    if any(data[archive.offset:]):
                        raise Refusal('uninspected trailing tar payload')
            except (tarfile.TarError, OSError) as error:
                raise Refusal('invalid tar evidence') from error
            return
        raise Refusal('unsupported or invalid evidence container')

def git_environment():
    # Inspect the actual publishable graph, not local replacement/graft views;
    # missing promisor blobs refuse instead of silently fetching new material.
    return {**os.environ, 'GIT_NO_REPLACE_OBJECTS': '1',
            'GIT_GRAFT_FILE': os.devnull, 'GIT_NO_LAZY_FETCH': '1'}

def git(args, repo=None, input=None):
    result = subprocess.run(['git', *(['-C', str(repo)] if repo else []), *args], input=input,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, env=git_environment())
    if result.returncode:
        raise Refusal('Git range/object lookup failed')
    if len(result.stdout) > MAX_GIT_OUTPUT:
        raise Refusal('Git metadata budget exceeded')
    return result.stdout

def object_ids(revisions, repo=None):
    # rev-list traverses intermediate commits, so a later sanitization/deletion
    # cannot remove an earlier introduced private blob from this check.
    command = ['git', *(['-C', str(repo)] if repo else []), 'rev-list', '--objects', '--no-object-names', *revisions]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=git_environment())
    ids, size = set(), 0
    try:
        for line in process.stdout:
            size += len(line)
            if size > MAX_GIT_OUTPUT or len(ids) >= MAX_OBJECTS:
                raise Refusal('Git object/range budget exceeded')
            oid = line.strip().decode('ascii')
            if not SHA.fullmatch(oid):
                raise Refusal('invalid Git object identity')
            ids.add(oid)
        if process.wait():
            raise Refusal('Git range lookup failed')
        return sorted(ids)
    finally:
        if process.poll() is None:
            process.kill(); process.wait()
        process.stdout.close()

def check_range(revisions, repo=None):
    if git(['rev-parse', '--is-shallow-repository'], repo).strip() != b'false':
        raise Refusal('complete Git history required; shallow publication range refused')
    ids = object_ids(revisions, repo)
    metadata = git(['cat-file', '--batch-check=%(objectname) %(objecttype) %(objectsize)'], repo,
                   ''.join(oid + '\n' for oid in ids).encode())
    blobs = []
    for row in metadata.splitlines():
        oid, kind, size = row.split()
        if kind == b'blob':
            if int(size) > MAX_BLOB:
                raise Refusal('new Git blob exceeds evidence budget: ' + oid.decode())
            blobs.append(oid.decode())
    budget = Budget()
    # One bounded blob at a time. No extraction or subprocess ever sees source
    # as code; diagnostics include object identity and fixed refusal only.
    for oid in blobs:
        result = subprocess.run(['git', *(['-C', str(repo)] if repo else []), 'cat-file', 'blob', oid],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, env=git_environment())
        if result.returncode or len(result.stdout) > MAX_BLOB:
            raise Refusal('Git blob lookup/size failed: ' + oid)
        try:
            scan_bytes(result.stdout, budget=budget)
        except Refusal as error:
            raise Refusal('blob ' + oid + ': ' + str(error)) from error
    return len(blobs)

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', help='exclusive already-published commit')
    parser.add_argument('--head', default='HEAD', help='inclusive candidate commit')
    parser.add_argument('--pre-push', action='store_true', help='read Git pre-push update lines')
    parser.add_argument('remote', nargs='?', default='origin')
    parser.add_argument('remote_url', nargs='?')
    opts = parser.parse_args(argv)
    try:
        ranges = []
        if opts.pre_push:
            for line in sys.stdin:
                parts = line.split()
                if len(parts) != 4 or not SHA.fullmatch(parts[1]) or not SHA.fullmatch(parts[3]):
                    raise Refusal('invalid pre-push update')
                _, local, _, remote = parts
                if not int(local, 16):
                    continue
                ranges.append([local, '^' + remote] if int(remote, 16)
                              else [local, '--not', '--remotes=' + opts.remote])
        else:
            head = git(['rev-parse', '--verify', opts.head + '^{commit}']).decode().strip()
            base = opts.base
            if base and SHA.fullmatch(base) and not int(base, 16):
                base = None
            ranges.append([head, '^' + git(['rev-parse', '--verify', base + '^{commit}']).decode().strip()] if base else [head])
        count = sum(check_range(revisions) for revisions in ranges)
        print('public-evidence: inspected', count, 'new blobs; no private Source units found')
        return 0
    except (Refusal, ValueError, UnicodeError) as error:
        print('public-evidence: REFUSED:', str(error), file=sys.stderr)
        return 1

if __name__ == '__main__':
    raise SystemExit(main())
