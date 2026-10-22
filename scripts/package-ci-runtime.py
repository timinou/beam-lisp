#!/usr/bin/env python3
"""Package a prepared runtime and its consumable cache products for CI."""
import argparse
from pathlib import Path
import tarfile


def native_products(store):
    """The same final cdylibs the native producer looks up under each key."""
    native = store / "native"
    if not native.is_dir():
        return
    for key in sorted(native.iterdir()):
        if not key.is_dir():
            continue
        for crate in sorted(key.iterdir()):
            if not crate.is_dir():
                continue
            for name in (f"lib{crate.name}.so", f"lib{crate.name}.dylib", f"{crate.name}.dll"):
                product = crate / "release" / name
                if product.is_file():
                    yield product


def package_store(store, destination):
    prefix = Path(".cache/beam_lisp")
    products = list(native_products(store))
    with tarfile.open(destination, "w:gz") as archive:
        for entry in sorted(store.iterdir()):
            if entry.name != "native":
                archive.add(entry, arcname=str(prefix / entry.name))
        # Cargo's final output can be a hard link or symlink into release/deps.
        # Materialize its bytes: consumers do not receive that intermediate tree.
        archive.dereference = True
        for product in products:
            archive.add(product, arcname=str(prefix / product.relative_to(store)), recursive=False)
    return len(products)


def package_runtime(root, destination, candidate=None):
    with tarfile.open(destination, "w:gz") as archive:
        for relative in ("build", "priv/native", "priv/z3", "tooling/drop/target/release/drop-launcher"):
            archive.add(root / relative, arcname=relative)
        if candidate is not None:
            archive.add(candidate, arcname=".bl/ci-candidate", recursive=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--store", type=Path, default=Path.home() / ".cache/beam_lisp")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    package_runtime(args.root, args.out / "ci-runtime.tar.gz", args.candidate)
    count = package_store(args.store, args.out / "ci-store.tar.gz")
    print(f"Prepared runtime: {count} native products; Cargo intermediates remain in the producer cache")
    for name in ("ci-runtime.tar.gz", "ci-store.tar.gz"):
        print(f"{name}: {(args.out / name).stat().st_size} bytes")


if __name__ == "__main__":
    main()
