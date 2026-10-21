import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("qualify_candidate", Path(__file__).resolve().parents[1] / "qualify-candidate.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class Receipts(unittest.TestCase):
    def test_resume_rejects_other_artifacts_and_preserves_latest_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.jsonl"
            identity = {"candidate": "new", "source": "current"}
            rows = [
                {"file": "a.bl", "identity": {"candidate": "old", "source": "current"}, "fail": 0},
                {"file": "b.bl", "identity": identity, "fail": 0},
                {"file": "b.bl", "identity": identity, "fail": 1},
                {"file": "c.bl", "identity": {"candidate": "new", "source": "edited"}, "fail": 0},
            ]
            path.write_text("\n".join(map(json.dumps, rows)) + '\n{"interrupted":')
            found = RUNNER.completed(path, identity)
            self.assertEqual(["b.bl"], list(found))
            self.assertEqual(1, found["b.bl"]["fail"])
