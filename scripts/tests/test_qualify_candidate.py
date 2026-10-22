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

    def test_successful_files_do_not_hide_a_failed_worker_or_missing_batch_end(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.jsonl"
            identity = {"candidate": "new", "source": "current"}
            path.write_text(json.dumps({"file": "a.bl", "identity": identity, "fail": 0}) + "\n")
            self.assertEqual(-1, RUNNER.batch_status(path, identity))
            with path.open("a") as out:
                out.write(json.dumps({"type": "batch", "identity": identity, "process_status": 70}) + "\n")
            self.assertEqual(70, RUNNER.batch_status(path, identity))
            self.assertEqual(["a.bl"], list(RUNNER.completed(path, identity)))
