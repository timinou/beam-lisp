"""Immutable named evidence checkpoint regression tests.

Run: python3 -m unittest discover -s '!tasks/artifacts' -p 'performance_archive_evidence_test.py'
"""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class EvidenceArchiveTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="optimizer-evidence-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.script = self.root / "archive.py"
        shutil.copyfile(Path(__file__).with_name("performance-archive-evidence.py"), self.script)
        self.log = self.root / "observed.log"
        self.log.write_text("observed evidence\n")
        self.command = ["python3", str(self.script), "--checkpoint", "prototype", "--logs", str(self.log)]

    def run_archive(self, args=None):
        return subprocess.run(args or self.command, capture_output=True, text=True)

    def test_creation_and_idempotence(self):
        self.assertEqual(0, self.run_archive().returncode)
        self.assertEqual(0, self.run_archive().returncode)
        out = self.root / "performance-evidence/prototype"
        self.assertEqual(self.log.read_bytes(), (out / self.log.name).read_bytes())
        index = json.loads((out / "index.json").read_text())
        self.assertEqual("prototype", index["checkpoint"])
        self.assertEqual(1, len(index["logs"]))
        self.assertEqual(64, len(index["logs"][0]["sha256"]))

    def test_distinct_evidence_cannot_replace_a_checkpoint(self):
        self.assertEqual(0, self.run_archive().returncode)
        self.log.write_text("different evidence\n")
        self.assertNotEqual(0, self.run_archive().returncode)
        out = self.root / "performance-evidence/prototype/observed.log"
        self.assertEqual("observed evidence\n", out.read_text())

    def test_unsafe_checkpoint_and_unpaired_arguments_are_refused(self):
        bad = ["python3", str(self.script), "--checkpoint", "../escape", "--logs", str(self.log)]
        self.assertEqual(2, self.run_archive(bad).returncode)
        missing = ["python3", str(self.script), "--checkpoint", "missing"]
        self.assertEqual(2, self.run_archive(missing).returncode)

    def test_duplicate_names_and_empty_logs_are_refused(self):
        self.assertNotEqual(0, self.run_archive(self.command + [str(self.log)]).returncode)
        self.log.write_text("")
        self.assertNotEqual(0, self.run_archive().returncode)


if __name__ == "__main__":
    unittest.main()
