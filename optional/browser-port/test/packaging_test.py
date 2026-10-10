"""Release-boundary gate; runs without Chromium, a compositor, Nix or BEAM."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PACKAGE = Path(__file__).resolve().parents[1]
ROOT = PACKAGE.parents[1]

class Packaging(unittest.TestCase):
    def test_outside_core_native_scan_and_release_priv(self):
        self.assertIn(PACKAGE.parent.name, ('optional', 'vendor'))
        self.assertFalse((ROOT / 'native/browser_port').exists())
        self.assertFalse((ROOT / 'priv/lib/browser/port.bl').exists())
        self.assertTrue((PACKAGE / 'bl/browser/port.bl').is_file())

    def test_default_build_has_no_dependencies_or_executable(self):
        result = subprocess.run(['cargo', 'metadata', '--offline', '--locked',
            '--format-version=1', '--no-default-features', '--manifest-path',
            str(PACKAGE / 'Cargo.toml')], check=True, capture_output=True, text=True)
        metadata = json.loads(result.stdout)
        root = metadata['resolve']['root']
        node = next(n for n in metadata['resolve']['nodes'] if n['id'] == root)
        self.assertEqual(node['deps'], [])
        with tempfile.TemporaryDirectory(prefix='bl-browser-disabled-') as target:
            subprocess.run(['cargo', 'build', '--offline', '--locked', '--release',
                '--no-default-features', '--manifest-path', str(PACKAGE / 'Cargo.toml'),
                '--target-dir', target], check=True, capture_output=True)
            self.assertFalse((Path(target) / 'release/bl-browser-port').exists())

if __name__ == '__main__':
    unittest.main()
