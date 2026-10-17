"""Synthetic two-line source units only; no private product source fixtures."""
import bz2
import gzip
import importlib.util
import io
import lzma
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'check-public-evidence.py'
SPEC = importlib.util.spec_from_file_location('public_evidence', SCRIPT)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)
PRIVATE = b'(ns knowledger.synthetic-fixture)\n(def example 1)\n'
PUBLIC = b'(ns public.synthetic-fixture)\n(def source "(ns knowledger.synthetic-fixture)")\n'

def archive(payload, name='renamed.txt', kind=tarfile.REGTYPE, linkname=''):
    result = io.BytesIO()
    with tarfile.open(fileobj=result, mode='w') as output:
        item = tarfile.TarInfo(name); item.type = kind; item.linkname = linkname
        item.size = len(payload) if kind == tarfile.REGTYPE else 0
        output.addfile(item, io.BytesIO(payload) if kind == tarfile.REGTYPE else None)
    return result.getvalue()

class SourceUnits(unittest.TestCase):
    def test_actual_private_namespace_not_filename(self):
        for name in ('knowledger.synthetic-fixture', 'foundry.synthetic-fixture'):
            with self.subTest(name=name):
                with self.assertRaisesRegex(check.Refusal, 'private Source unit declaration'):
                    check.scan_bytes(('; synthetic license\n(ns ' + name + ')\n(def example 1)\n').encode())
    def test_quoted_snippets_and_public_probe_are_not_units(self):
        for data in (PUBLIC, b'\'(ns knowledger.synthetic-fixture)', b'`(ns foundry.synthetic-fixture)',
                     b'"(ns knowledger.synthetic-fixture)"', b'(quote (ns foundry.synthetic-fixture))',
                     b'; (ns knowledger.synthetic-fixture)\n(ns public.example)',
                     b'(ns knowledgerish.example)\n(def example 1)'):
            with self.subTest(data=data):
                check.scan_bytes(data)
    def test_metadata_and_bom_do_not_hide_source_unit(self):
        for data in (b'\xef\xbb\xbf' + PRIVATE, b'#!/usr/bin/env bl\n' + PRIVATE,
                     b'^{:doc "synthetic"} ' + PRIVATE,
                     b'(ns ^{:doc "synthetic"} foundry.synthetic-fixture)\n(def example 1)'):
            with self.assertRaisesRegex(check.Refusal, 'private Source unit declaration'):
                check.scan_bytes(data)
    def test_renamed_raw_and_compressed_tar_contents(self):
        for wrap in (lambda x: x, gzip.compress, bz2.compress, lzma.compress):
            with self.subTest(compression=wrap.__name__):
                with self.assertRaisesRegex(check.Refusal, 'private Source unit declaration'):
                    check.scan_bytes(wrap(archive(PRIVATE)), 'innocuous.dat')
                check.scan_bytes(wrap(archive(PUBLIC)), 'innocuous.dat')
    def test_nested_known_archive_is_inspected(self):
        with self.assertRaisesRegex(check.Refusal, 'private Source unit declaration'):
            check.scan_bytes(archive(archive(PRIVATE), 'nested.dat'))
    def test_unsafe_paths_and_types_never_extract(self):
        for name, kind in (('../escape', tarfile.REGTYPE), ('/escape', tarfile.REGTYPE),
                           ('C:\\escape', tarfile.REGTYPE), ('link', tarfile.SYMTYPE),
                           ('hardlink', tarfile.LNKTYPE), ('device', tarfile.CHRTYPE),
                           ('fifo', tarfile.FIFOTYPE), ('sparse', tarfile.GNUTYPE_SPARSE)):
            with self.subTest(name=name, kind=kind):
                with self.assertRaisesRegex(check.Refusal, 'unsafe archive'):
                    check.scan_bytes(archive(PUBLIC, name, kind, '/private'))
    def test_unknown_nested_container_refuses(self):
        for payload in (b'\x28\xb5\x2f\xfdsynthetic', b'7z\xbc\xaf\x27\x1csynthetic',
                        b'PK\x03\x04synthetic', b'Rar!synthetic'):
            with self.assertRaisesRegex(check.Refusal, 'unsupported or invalid evidence container'):
                check.scan_bytes(archive(payload, 'renamed.dat'))
    def test_limits_fail_closed(self):
        with patch.object(check, 'MAX_MEMBER', 8):
            with self.assertRaisesRegex(check.Refusal, 'member budget'):
                check.scan_bytes(archive(PUBLIC))
        with patch.object(check, 'MAX_TOTAL', 128):
            with self.assertRaisesRegex(check.Refusal, 'byte budget'):
                check.scan_bytes(gzip.compress(b' ' * 10000))
        with patch.object(check, 'MAX_DEPTH', 1):
            with self.assertRaisesRegex(check.Refusal, 'depth'):
                check.scan_bytes(archive(archive(PUBLIC)))
    def test_concatenated_compression_and_tar_trailing_payload_refuse(self):
        with self.assertRaisesRegex(check.Refusal, 'concatenated'):
            check.scan_bytes(gzip.compress(archive(PUBLIC)) + gzip.compress(archive(PRIVATE)))
        with self.assertRaisesRegex(check.Refusal, 'trailing tar'):
            check.scan_bytes(archive(PUBLIC) + PRIVATE)
    def test_compression_bomb_does_not_expand_unbounded(self):
        with patch.object(check, 'MAX_BLOB', 4096):
            with self.assertRaisesRegex(check.Refusal, 'expanded evidence byte budget'):
                check.scan_bytes(gzip.compress(b' ' * 1000000))

class CommitRanges(unittest.TestCase):
    def setUp(self):
        home = Path.home() / 'tmp'; home.mkdir(exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(prefix='public-evidence-test-', dir=home)
        self.repo = Path(self.directory.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Synthetic fixture')
        self.git('config', 'user.email', 'synthetic@example.invalid')
        (self.repo / 'public.bl').write_bytes(PUBLIC)
        self.commit('public baseline')
        self.base = self.git('rev-parse', 'HEAD').strip()
    def tearDown(self):
        self.directory.cleanup()
    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True, stderr=subprocess.PIPE)
    def commit(self, message):
        self.git('add', '--all'); self.git('commit', '-qm', message)
    def run_check(self, *args, input=None):
        return subprocess.run(['python3', str(SCRIPT), *args], cwd=self.repo, input=input,
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    def test_sanitized_head_still_refuses_intermediate_private_archive(self):
        path = self.repo / 'renamed.bin'
        path.write_bytes(gzip.compress(archive(PRIVATE, 'bench/input.data')))
        self.commit('synthetic historical accident')
        path.write_bytes(gzip.compress(archive(PUBLIC, 'bench/input.data')))
        self.commit('synthetic sanitization')
        result = self.run_check('--base', self.base)
        self.assertEqual(1, result.returncode)
        self.assertIn('private Source unit declaration', result.stderr)
        self.assertNotIn('(def example', result.stderr)
        head_only = self.run_check('--base', self.git('rev-parse', 'HEAD^').strip())
        self.assertEqual(0, head_only.returncode, head_only.stderr)
    def test_pre_push_checks_each_update_and_ignores_deletion(self):
        (self.repo / 'renamed.bin').write_bytes(archive(PRIVATE))
        self.commit('synthetic private input')
        head = self.git('rev-parse', 'HEAD').strip()
        result = self.run_check('--pre-push', 'origin', 'unused',
            input=f'refs/heads/main {head} refs/heads/main {self.base}\n')
        self.assertEqual(1, result.returncode)
        deletion = self.run_check('--pre-push', input=f'refs/heads/gone {"0" * 40} refs/heads/gone {head}\n')
        self.assertEqual(0, deletion.returncode)
    def test_new_branch_scans_unpublished_history(self):
        self.git('update-ref', 'refs/remotes/origin/main', self.base)
        (self.repo / 'archive').write_bytes(archive(PRIVATE))
        self.commit('synthetic private input')
        head = self.git('rev-parse', 'HEAD').strip()
        result = self.run_check('--pre-push', input=f'refs/heads/new {head} refs/heads/new {"0" * 40}\n')
        self.assertEqual(1, result.returncode)
        self.assertIn('private Source unit declaration', result.stderr)
    def test_missing_base_and_invalid_hook_input_refuse(self):
        self.assertEqual(1, self.run_check('--base', 'f' * 40).returncode)
        self.assertEqual(1, self.run_check('--pre-push', input='malformed\n').returncode)
    def test_local_replacement_ref_cannot_hide_published_blob(self):
        (self.repo / 'archive').write_bytes(archive(PRIVATE))
        self.commit('synthetic private input')
        head = self.git('rev-parse', 'HEAD').strip()
        tree = self.git('rev-parse', self.base + '^{tree}').strip()
        replacement = self.git('commit-tree', tree, '-p', self.base, '-m', 'synthetic public replacement').strip()
        self.git('replace', head, replacement)
        result = self.run_check('--base', self.base)
        self.assertEqual(1, result.returncode)
        self.assertIn('private Source unit declaration', result.stderr)
    def test_shallow_history_cannot_hide_intermediate_objects(self):
        (self.repo / '.git/shallow').write_text(self.base + '\n')
        result = self.run_check('--head', 'HEAD')
        self.assertEqual(1, result.returncode)
        self.assertIn('complete Git history required', result.stderr)
    def test_oversized_new_blob_refuses_before_blob_read(self):
        (self.repo / 'data').write_bytes(b'x' * 100)
        self.commit('synthetic bounded input')
        with patch.object(check, 'MAX_BLOB', 32):
            with self.assertRaisesRegex(check.Refusal, 'new Git blob exceeds'):
                check.check_range(['HEAD', '^' + self.base], self.repo)

if __name__ == '__main__':
    unittest.main()
