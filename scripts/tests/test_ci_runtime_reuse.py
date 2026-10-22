import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('runtime_reuse', Path(__file__).parents[1] / 'check-ci-runtime-reuse.py')
REUSE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(REUSE)

class RuntimeReuseTests(unittest.TestCase):
    def test_qualification_changes_do_not_rebuild_a_runtime(self):
        paths = ['test/fixtures/actor.bl', 'scripts/qualify-candidate.bl',
                 'scripts/tests/test_ci_runtime_reuse.py', '.github/workflows/ci.yml',
                 'reports/qualification.org']
        self.assertEqual([], REUSE.runtime_changes(paths))

    def test_every_runtime_and_unknown_input_requires_a_new_producer(self):
        paths = ['priv/std/test.bl', 'priv/lib/source.bl.md', 'env.bl',
                 'native/lazy_memo/src/lib.rs', 'tooling/drop/src/launcher.rs',
                 'scripts/embed-test-library.py', 'bin/bl', 'flake.nix', '.github/workflows/build-drop.yml', 'unknown.input']
        self.assertEqual(paths, REUSE.runtime_changes(paths))

if __name__ == '__main__':
    unittest.main()

class ProducerGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('producer_gates', Path(__file__).parents[1] / 'wait-ci-producer.py')
        cls.gates = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.gates)

    def test_complete_backend_proof_is_required(self):
        rows = [{'name': name, 'status': 'completed', 'conclusion': 'success'}
                for name in self.gates.REQUIRED]
        self.assertTrue(self.gates.result(rows))
        self.assertFalse(self.gates.result(rows[:-1]))
        rows[0]['status'] = 'in_progress'
        self.assertFalse(self.gates.result(rows))

    def test_a_failed_backend_cannot_be_hidden_by_other_successes(self):
        with self.assertRaises(RuntimeError):
            self.gates.result([{'name': 'nix-drop', 'status': 'completed', 'conclusion': 'failure'}])

class ProducerConfigurationTests(unittest.TestCase):
    def test_orchestration_can_change_but_native_steps_and_version_cannot(self):
        before = 'env:\n  CI_RUST_VERSION: "1.99.1"\njobs:\n  prepare-linux:\n    if: true\n    steps:\n      - run: build-native\n  test:\n    steps: []\n'
        after = before.replace('if: true', 'if: !inputs.runtime_run').replace('  test:', '  reuse-linux:\n    steps: []\n  test:')
        self.assertEqual(REUSE.producer_configuration(before), REUSE.producer_configuration(after))
        self.assertNotEqual(REUSE.producer_configuration(before), REUSE.producer_configuration(before.replace('1.99.1', '1.99.2')))
        self.assertNotEqual(REUSE.producer_configuration(before), REUSE.producer_configuration(before.replace('build-native', 'another-build')))
