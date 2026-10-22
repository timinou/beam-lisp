import importlib.util
import json
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("qualify_candidate", Path(__file__).resolve().parents[1] / "qualify-candidate.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class Receipts(unittest.TestCase):
    def run_process_control(self, fail_first=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "scripts/test-isolation.json").write_text('{"fault.bl": "isolated"}')
            candidate = root / "candidate"
            candidate.write_text("#!/usr/bin/env python3\n" + f"fail_first = {fail_first!r}\n" + '''
import json, os
files = os.environ['BL_QUALIFY_FILES'].splitlines()
report = files if fail_first else files[:1]
for name in report:
    print('BL-QUALIFY ' + json.dumps({'file': name, 'fail': 0, 'error': 0}))
if len(report) < len(files):
    print('BL-QUALIFY-HANDOVER ' + json.dumps({'completed': len(report)}))
raise SystemExit(70 if fail_first and len(files) > 1 else 0)
''')
            candidate.chmod(0o755)
            results = root / "results.jsonl"
            argv = ["qualify", "--candidate", str(candidate), "--results", str(results),
                    "a.bl", "b.bl", "fault.bl"]
            with patch.object(RUNNER, "ROOT", root), patch.object(RUNNER, "source_digest", return_value="source"), \
                    patch.object(sys, "argv", argv), contextlib.redirect_stdout(io.StringIO()):
                status = RUNNER.main()
            return status, [json.loads(line) for line in results.read_text().splitlines()]

    def test_handover_finishes_remaining_files_and_retains_isolated_processes(self):
        status, rows = self.run_process_control()
        self.assertEqual(0, status)
        self.assertEqual(["a.bl", "b.bl", "fault.bl"], [row["file"] for row in rows if "file" in row])
        self.assertEqual(3, sum(row.get("type") == "process" for row in rows))
        self.assertEqual(1, sum(row.get("type") == "handover" for row in rows))
        self.assertEqual(0, rows[-1]["process_status"])

    def test_later_success_cannot_hide_an_earlier_failed_process(self):
        status, rows = self.run_process_control(fail_first=True)
        self.assertEqual(1, status)
        self.assertEqual([70, 0], [row["process_status"] for row in rows if row.get("type") == "process"])
        self.assertEqual(70, rows[-1]["process_status"])

    def test_interrupted_last_record_does_not_swallow_the_next_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.jsonl"
            identity = {"candidate": "new", "source": "current"}
            path.write_text('{"interrupted":')
            RUNNER.separate_last_record(path)
            with path.open("a") as out:
                out.write(json.dumps({"identity": identity, "file": "next.bl", "fail": 0}) + "\n")
            self.assertEqual(["next.bl"], list(RUNNER.completed(path, identity)))

    def test_privileged_fixtures_get_own_processes_without_coverage_changes(self):
        files = ["a.bl", "fault.bl", "b.bl", "policy.bl"]
        groups = RUNNER.process_groups(files, {"fault.bl": "SDK lease", "policy.bl": "retained custody"})
        self.assertEqual([["a.bl", "b.bl"], ["fault.bl"], ["policy.bl"]], groups)
        self.assertCountEqual(files, [name for group in groups for name in group])

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
