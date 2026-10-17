"""Owned shell command models only; no native BL, browser or service launch."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
STUB = Path(__file__).resolve().parent / 'fixtures/continuity-command-stub.py'
CASES = [
    ('failed_preflight_external_evidence', {'invalid_external_evidence': True}, False, 0),
    ('failed_preflight_default_evidence', {'default_preflight_collision': True}, False, 0),
    ('default_evidence_allocation_failure', {'evidence_alloc_fail': True}, False, 0),
    ('occupied_foreign_port', {'port_busy': True}, False, 0),
    ('foreign_unit_invocation', {'foreign_before_cleanup': True}, True, 0),
    ('lost_launch_reply_possible_live_data', {'launch_lost_reply': True}, True, 0),
    ('invocation_capture_failure', {'capture_fail': True}, True, 0),
    ('stop_failure', {'stop_fail': True}, True, 1),
    ('stop_claims_success_but_live_pid', {'post_stop_live_pid': True}, True, 1),
    ('foreign_invocation_after_stop', {'post_stop_foreign': True}, True, 1),
    ('empty_invocation_still_loaded', {'post_stop_empty_loaded': True}, True, 1),
    ('successful_own_stop', {}, False, 1),
    ('successful_collected_own_stop', {'collected': True}, False, 1),
]


class ExplicitContinuityLauncher(unittest.TestCase):
    def setUp(self):
        (Path.home() / 'tmp').mkdir(exist_ok=True)

    def run_owned_model(self, root, config, override=False):
        """Every fake process, artifact and retained data cell belongs to root."""
        repo = root / 'repo'
        tools = root / 'commands'
        tools.mkdir()
        for rel in ['examples/continuity', 'bin', 'scripts', 'test/browser/node_modules/.bin']:
            (repo / rel).mkdir(parents=True)
        script = repo / 'examples/continuity/verify.sh'
        shutil.copyfile(REPO / 'examples/continuity/verify.sh', script)
        for path in [*(tools / name for name in ['mktemp', 'rm', 'curl', 'systemd-run', 'systemctl', 'journalctl']),
                     repo / 'bin/bl', root / 'accepted-bl', repo / 'scripts/bl-mem',
                     repo / 'test/browser/node_modules/.bin/playwright']:
            shutil.copyfile(STUB, path)
            path.chmod(0o700)
        initial = {'scratch': None, 'evidence': None, 'invocation': '', 'active': 'inactive',
                   'loaded': 'not-found', 'pid': '0', 'curlCalls': 0, 'launchCalls': 0,
                   'browserStubCalls': 0, 'stopCalls': 0, 'invocationReads': 0}
        (root / 'config.json').write_text(json.dumps(config))
        (root / 'state.json').write_text(json.dumps(initial))
        env = {key: os.environ[key] for key in ['HOME', 'LANG'] if key in os.environ}
        env.update(PATH=str(tools) + ':/usr/bin:/bin', CONTINUITY_MOCK_CASE=str(root))
        if override:
            env['CONTINUITY_BL'] = str(root / 'accepted-bl')
        env.update(config.get('launcher_env', {}))
        if not config.get('default_preflight_collision') and not config.get('evidence_alloc_fail'):
            evidence = root / 'evidence'
            evidence.mkdir(mode=0o700)
            if config.get('invalid_external_evidence'):
                evidence.chmod(0o777)
                (evidence / 'foreign-sentinel.txt').write_text('EXTERNAL EVIDENCE MUST SURVIVE\n')
            env['CONTINUITY_EVIDENCE'] = str(evidence)
        result = subprocess.run(['/bin/bash', str(script)], env=env, cwd=repo,
                                text=True, capture_output=True, timeout=20)
        state = json.loads((root / 'state.json').read_text())
        events_file = root / 'events.jsonl'
        events = [json.loads(line) for line in events_file.read_text().splitlines()] if events_file.exists() else []
        return result, state, events

    def test_override_is_the_only_invoked_launcher_and_hash_is_exact(self):
        for override in (True, False):
            with self.subTest(override=override), tempfile.TemporaryDirectory(dir=Path.home() / 'tmp') as temporary:
                root = Path(temporary)
                result, state, events = self.run_owned_model(root, {}, override)
                self.assertEqual(result.returncode, 0, result.stderr)
                actual = root / 'accepted-bl' if override else root / 'repo/bin/bl'
                calls = [event for event in events if event['kind'] == 'launcher-executed']
                self.assertEqual([(event['launcher'], event['arguments']) for event in calls],
                                 [(str(actual), ['run', 'examples/continuity/main.bl'])])
                self.assertEqual(state['browserStubCalls'], 1)
                unit = next(event for event in events if event['kind'] == 'systemd-run')
                for flag in ('--setenv=BL_DAEMON=off', '--setenv=BL_AUTOBUILD=off',
                             '--setenv=BEAM_LISP_AOT_CACHE_DIR=' + state['scratch'] + '/aot-cache'):
                    self.assertIn(flag, unit['args'])
                receipt = json.loads((root / 'evidence/launcher-input.json').read_text())
                self.assertEqual(receipt['launcher'], str(actual))
                self.assertEqual(receipt['launcherRealpath'], str(actual.resolve()))
                self.assertEqual(receipt['launcherSha256'], hashlib.sha256(actual.read_bytes()).hexdigest())
                self.assertEqual(receipt['scope'], 'source-continuity-launcher-selection/v1')
                self.assertFalse((root / 'evidence/launcher-input.json').stat().st_mode & 0o077)
                self.assertFalse(Path(state['scratch']).exists())
                self.assertTrue((root / 'evidence/server-journal.jsonl').is_file())
                self.assertIn('Evidence: ', result.stdout)

    def test_explicit_private_cache_copy_and_finite_readiness_are_only_input_candidates(self):
        with tempfile.TemporaryDirectory(dir=Path.home() / 'tmp') as temporary:
            root = Path(temporary); cache = root / 'candidate-cache'; cache.mkdir(mode=0o700)
            candidate = cache / 'manifest.term'; candidate.write_bytes(b'UNIT-ONLY-UNTRUSTED-CODE-CANDIDATE')
            original = hashlib.sha256(candidate.read_bytes()).hexdigest()
            result, state, events = self.run_owned_model(root, {'launcher_env': {
                'CONTINUITY_AOT_CACHE_SOURCE': str(cache), 'CONTINUITY_READY_TIMEOUT': '600', 'CONTINUITY_RUNTIME_SECONDS': '900'}})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(hashlib.sha256(candidate.read_bytes()).hexdigest(), original)
            receipt = json.loads((root / 'evidence/launcher-input.json').read_text())
            self.assertEqual(receipt['cacheCandidates']['kind'], 'untrusted-exact-private-byte-copy')
            self.assertEqual(receipt['cacheCandidates']['files'], 1)
            self.assertEqual(receipt['cacheCandidates']['authority'], 'NONE; native canonical producer revalidation required')
            unit = next(event for event in events if event['kind'] == 'systemd-run')
            self.assertIn('--property=RuntimeMaxSec=900', unit['args'])
        # Invalid timing refuses BEFORE any modeled command or native start.
        for env in ({'CONTINUITY_READY_TIMEOUT': 'infinity'}, {'CONTINUITY_RUNTIME_SECONDS': '300'},
                    {'CONTINUITY_READY_TIMEOUT': '1801', 'CONTINUITY_RUNTIME_SECONDS': '2700'}):
            with tempfile.TemporaryDirectory(dir=Path.home() / 'tmp') as temporary:
                root = Path(temporary)
                result, state, events = self.run_owned_model(root, {'launcher_env': env})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(state['launchCalls'], 0)
                self.assertEqual(events, [])
        # Symlink candidate roots cannot alias mutable host state into the VM.
        with tempfile.TemporaryDirectory(dir=Path.home() / 'tmp') as temporary:
            root = Path(temporary); real = root / 'real'; real.mkdir(); (real / 'x').write_bytes(b'x')
            alias = root / 'alias'; alias.symlink_to(real, target_is_directory=True)
            result, state, events = self.run_owned_model(root, {'launcher_env': {'CONTINUITY_AOT_CACHE_SOURCE': str(alias)}})
            self.assertNotEqual(result.returncode, 0); self.assertEqual(state['launchCalls'], 0)
            self.assertEqual((real / 'x').read_bytes(), b'x')

    def test_relative_or_missing_override_refuses_before_any_command(self):
        script = REPO / 'examples/continuity/verify.sh'
        for value in ('relative-bl', str(Path.home() / 'tmp/nonexistent-continuity-sdk')):
            with self.subTest(value=value), tempfile.TemporaryDirectory(dir=Path.home() / 'tmp') as temporary:
                root = Path(temporary)
                tools = root / 'commands'
                tools.mkdir()
                for name in ['mktemp', 'rm', 'curl', 'systemd-run', 'systemctl', 'journalctl']:
                    path = tools / name
                    shutil.copyfile(STUB, path)
                    path.chmod(0o700)
                env = {key: os.environ[key] for key in ['HOME', 'LANG'] if key in os.environ}
                env.update(PATH=str(tools) + ':/usr/bin:/bin', CONTINUITY_BL=value,
                           CONTINUITY_MOCK_CASE=str(root))
                result = subprocess.run(['/bin/bash', str(script)], env=env, capture_output=True, timeout=20)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((root / 'events.jsonl').exists(), 'Refusal must precede any modeled command')
                self.assertNotIn(b'Evidence: ', result.stdout)

    def check_custody_case(self, label, config, retain, stops):
        # Even modeled unknown retention is only fixture data. TemporaryDirectory
        # always removes that owned test tree after assertions, including failures.
        with tempfile.TemporaryDirectory(dir=Path.home() / 'tmp') as temporary:
            root = Path(temporary)
            result, state, events = self.run_owned_model(root, config)
            scratch = Path(state['scratch'])
            self.assertTrue(scratch.is_relative_to(root))
            self.assertEqual(scratch.exists(), retain, (label, result.stderr))
            self.assertEqual(state['stopCalls'], stops, label)
            for event in events:
                if event['kind'] == 'stop-invocation':
                    self.assertEqual(event['invocation'], '1' * 32, 'Foreign invocation must never be stopped')
            if state['launchCalls']:
                evidence = root / 'evidence'
                self.assertTrue((evidence / 'server-journal.jsonl').is_file())
                self.assertTrue((evidence / 'service-invocation.txt').is_file())
                if retain:
                    self.assertEqual((scratch / 'data/live-data.txt').read_text(), 'POSSIBLE LIVE MOCK DATA\n')
                else:
                    deletions = [event for event in events if event['kind'] == 'deletion']
                    self.assertTrue(deletions)
                    self.assertTrue(all(event['journalAlreadyWritten'] for event in deletions))
            if config.get('invalid_external_evidence'):
                self.assertTrue((root / 'evidence/foreign-sentinel.txt').is_file())
            if config.get('default_preflight_collision'):
                self.assertFalse((root / 'default-evidence').exists())
            if label.startswith('successful_'):
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((root / 'evidence/launcher-input.json').is_file())
            else:
                self.assertNotEqual(result.returncode, 0, 'Unsafe/unconfirmed cleanup must be reported')


def custody_test(case):
    def test(self):
        self.check_custody_case(*case)
    return test


for case in CASES:
    setattr(ExplicitContinuityLauncher, 'test_custody_' + case[0], custody_test(case))


if __name__ == '__main__':
    unittest.main()
