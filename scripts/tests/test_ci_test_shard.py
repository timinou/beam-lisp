import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("ci_test_shard", Path(__file__).resolve().parents[1] / "ci-test-shard.py")
SHARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHARD)


class TestPartitions(unittest.TestCase):
    def test_every_conventional_test_appears_exactly_once(self):
        root = Path(__file__).resolve().parents[2]
        groups = SHARD.partitions(root, 8)
        flat = [name for group in groups for name in group]
        expected = {str(path.relative_to(root)) for path in (root / "test").rglob("*")
                    if path.is_file() and path.name.endswith(("_test.bl", "_test.exs"))
                    and not any(part.startswith(".") for part in path.relative_to(root / "test").parts[:-1])}
        self.assertEqual(expected, set(flat))
        self.assertEqual(len(flat), len(set(flat)))
        self.assertLessEqual(max(map(len, groups)) - min(map(len, groups)), 1)
        self.assertTrue(all(groups))

    def test_fixtures_and_hidden_directories_are_not_suites(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ["test/a_test.bl", "test/nested/b_test.exs", "test/helper.bl", "test/.private/c_test.bl"]:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            self.assertEqual([["test/a_test.bl"], ["test/nested/b_test.exs"]], SHARD.partitions(root, 2))

    def test_partition_count_must_be_positive(self):
        with self.assertRaises(ValueError):
            SHARD.partitions(Path("."), 0)
