import importlib.machinery
import importlib.util
from pathlib import Path
import unittest

PATH = Path(__file__).resolve().parents[1] / "bl-mem"
LOADER = importlib.machinery.SourceFileLoader("bl_mem", str(PATH))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
MEMORY = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(MEMORY)


class TestVmDiscovery(unittest.TestCase):
    def test_launcher_and_direct_component_vms_both_own_memory(self):
        launcher = ["/erts/bin/beam.smp", "-e", "BeamLisp.Launcher.main()", "--", "--cold", "test", "one.bl"]
        component = ["/erts/bin/beam.smp", "-pa", "/private/lib/beam_lisp-0.1.0/ebin", "/private/check.exs"]
        seed = ["/erts/bin/beam.smp", "-pa", "/private/priv/bootstrap/seed", "-e", "BeamLisp.AOT.boot()"]
        for command in (launcher, component, seed):
            self.assertTrue(MEMORY.beam_lisp_vm(command))
        self.assertEqual(("test", "--cold test one.bl"), MEMORY.kind_and_args(launcher))
        self.assertEqual(("other", "Elixir driver check.exs"), MEMORY.kind_and_args(component))

    def test_parents_and_unrelated_elixir_vms_are_not_counted(self):
        for command in (["bash", "-c", "elixir -e BeamLisp.Launcher.main()"],
                        ["systemd-run", "-pa", "/private/lib/beam_lisp-0.1.0/ebin"],
                        ["/erts/bin/beam.smp", "-pa", "/private/lib/unrelated/ebin"],
                        ["/erts/bin/beam.smp", "-e", "IO.puts(1)"], []):
            self.assertFalse(MEMORY.beam_lisp_vm(command))
