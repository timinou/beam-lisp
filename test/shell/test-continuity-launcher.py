"""Dry orchestration of the shell verifier; NO native VM/browser/service launch."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


class ExplicitContinuityLauncher(unittest.TestCase):
    def test_override_is_the_only_invoked_launcher_and_hash_is_exact(self):
        for override in (True, False):
            with self.subTest(override=override), tempfile.TemporaryDirectory(dir=Path.home() / 'tmp') as scratch:
                root = Path(scratch); repo = root / 'repo'; fake = root / 'tools'; fake.mkdir()
                (repo / 'examples/continuity').mkdir(parents=True); (repo / 'scripts').mkdir()
                (repo / 'bin').mkdir(); (repo / 'test/browser/node_modules/.bin').mkdir(parents=True)
                script = repo / 'examples/continuity/verify.sh'; shutil.copy2(REPO / 'examples/continuity/verify.sh', script)
                def executable(path, body):
                    path.write_text('#!/bin/sh\nset -eu\n' + body); path.chmod(0o755)
                trace = root / 'trace'; count = root / 'curl-count'
                selected = root / 'accepted-bl'
                for path in (selected, repo / 'bin/bl'):
                    executable(path, 'printf "%s\\n" "$0 $*" >> "$TRACE"\n')
                executable(repo / 'scripts/bl-mem', 'exit 0\n')
                executable(repo / 'test/browser/node_modules/.bin/playwright', 'printf "%s\\n" "DRY_BROWSER_ONLY" >> "$TRACE"\n')
                executable(fake / 'systemd-run', '''while [ "$#" -gt 0 ]; do
  case "$1" in /*) exec "$@" ;; esac
  shift
done
exit 2
''')
                executable(fake / 'systemctl', 'printf "%s\\n" "DRY_UNIT_ONLY"\n')
                executable(fake / 'journalctl', 'printf "%s\\n" "DRY_LOG_ONLY"\n')
                executable(fake / 'curl', 'if [ ! -f "$CURL_COUNT" ]; then touch "$CURL_COUNT"; exit 1; fi\nexit 0\n')
                env = {key: os.environ[key] for key in ('HOME', 'LANG') if key in os.environ}
                env.update(PATH=str(fake) + os.pathsep + '/usr/bin:/bin', TRACE=str(trace), CURL_COUNT=str(count),
                           CONTINUITY_EVIDENCE=str(root / 'evidence'))
                if override:
                    env['CONTINUITY_BL'] = str(selected)
                result = subprocess.run(['bash', str(script)], env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                actual = selected if override else repo / 'bin/bl'
                self.assertEqual(trace.read_text().splitlines(), [str(actual) + ' run examples/continuity/main.bl', 'DRY_BROWSER_ONLY'])
                receipt = json.loads((root / 'evidence/launcher-input.json').read_text())
                self.assertEqual(receipt['launcher'], str(actual))
                self.assertEqual(receipt['launcherSha256'], hashlib.sha256(actual.read_bytes()).hexdigest())
                self.assertEqual(receipt['scope'], 'source-continuity-launcher-selection/v1')
                self.assertFalse((root / 'evidence/launcher-input.json').stat().st_mode & 0o077)
                scratch_path = Path(result.stdout.split('Logs: ')[1].splitlines()[0])
                self.assertTrue(str(scratch_path).startswith(str(Path.home() / 'tmp') + '/ct-'))
                shutil.rmtree(scratch_path)  # Only the directory this dry run returned.

    def test_relative_or_missing_override_refuses_before_any_command(self):
        script = REPO / 'examples/continuity/verify.sh'
        for value in ('relative-bl', str(Path.home() / 'tmp/nonexistent-continuity-sdk')):
            result = subprocess.run(['bash', str(script)], env={**os.environ, 'CONTINUITY_BL': value}, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(b'Sandbox stopped', result.stdout)


if __name__ == '__main__':
    unittest.main()
