import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('embed_test_library', Path(__file__).resolve().parents[1] / 'embed-test-library.py')
EMBED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EMBED)


class EmbeddedLibrary(unittest.TestCase):
    def test_round_trip_and_read_only_drift_check(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'priv/host').mkdir(parents=True)
            (root / 'priv/std').mkdir()
            host = root / 'priv/host/test_rt.bl'
            original = 'before\n' + EMBED.START + '"old"' + EMBED.END + '\nafter\n'
            host.write_text(original)
            library = '(ns core)\n(def text "backslash \\\\ and ☃")\n'
            (root / 'priv/std/test.bl').write_text(library)
            self.assertFalse(EMBED.synchronize(root, check=True))
            self.assertEqual(original, host.read_text())
            self.assertTrue(EMBED.synchronize(root))
            generated = host.read_text()
            literal = generated.split(EMBED.START)[1].split(EMBED.END)[0]
            self.assertEqual(library, json.loads(literal))
            self.assertTrue(generated.startswith('before\n'))
            self.assertTrue(generated.endswith('\nafter\n'))
            self.assertTrue(EMBED.synchronize(root, check=True))
