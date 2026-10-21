import importlib.util
import os
from pathlib import Path
import tarfile
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("ci_runtime_package", Path(__file__).resolve().parents[1] / "package-ci-runtime.py")
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class TestRuntimePackage(unittest.TestCase):
    def test_native_products_restore_without_their_cargo_link_targets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = root / "store"
            for crate, link in (("hard", os.link), ("symbolic", os.symlink)):
                release = store / "native" / "content-key" / crate / "release"
                (release / "deps").mkdir(parents=True)
                target = release / "deps" / f"lib{crate}.so"
                target.write_bytes(b"native executable product")
                target.chmod(0o755)
                link(target, release / target.name)
                (release / "unneeded.o").write_bytes(b"compiler intermediate")
            dependency = store / "ebin" / "dependency" / "ebin" / "dependency.app"
            dependency.parent.mkdir(parents=True)
            dependency.write_bytes(b"application metadata")
            bundle = root / "store.tar.gz"
            self.assertEqual(2, PACKAGE.package_store(store, bundle))
            with tarfile.open(bundle) as archive:
                names = archive.getnames()
                self.assertFalse(any("/deps/" in name or name.endswith(".o") for name in names))
                archive.extractall(root / "restored", filter="data")
            for crate in ("hard", "symbolic"):
                product = root / "restored/.cache/beam_lisp/native/content-key" / crate / "release" / f"lib{crate}.so"
                self.assertFalse(product.is_symlink())
                self.assertEqual(b"native executable product", product.read_bytes())
                self.assertTrue(product.stat().st_mode & 0o111)
            self.assertEqual(b"application metadata", (root / "restored/.cache/beam_lisp/ebin/dependency/ebin/dependency.app").read_bytes())

    def test_runtime_projection_keeps_the_prepared_inputs_and_modes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inputs = ("build/runtime.beam", "priv/native/runtime.so", "priv/z3/bin/z3",
                      "tooling/drop/target/release/drop-launcher")
            for name in inputs:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(name.encode())
                path.chmod(0o755)
            (root / "unrelated").write_text("not a runtime input")
            bundle = root / "runtime.tar.gz"
            candidate = root / "candidate"
            candidate.write_bytes(b"qualified immutable drop")
            candidate.chmod(0o755)
            PACKAGE.package_runtime(root, bundle, candidate)
            with tarfile.open(bundle) as archive:
                self.assertNotIn("unrelated", archive.getnames())
                self.assertFalse(any(name.endswith(".o") for name in archive.getnames()))
                for name in inputs:
                    self.assertEqual(name.encode(), archive.extractfile(name).read())
                    self.assertTrue(archive.getmember(name).mode & 0o111)
                self.assertEqual(b"qualified immutable drop", archive.extractfile(".bl/ci-candidate").read())
                self.assertTrue(archive.getmember(".bl/ci-candidate").mode & 0o111)
