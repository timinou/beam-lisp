#!/usr/bin/env python3
"""Check owned monitor delivery against the bare kernel before SDK assembly."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

DRIVER = r'''
for path <- BeamLisp.Loader.library_search_paths(), do: Code.append_path(path)
Application.load(:beam_lisp)
BeamLisp.AOT.boot()
tag = make_ref()
{pid, ref} = BeamLisp.Refs.spawn_owned(fn -> exit(:tagged_worker_exit) end,
                                     :monitor, [], [tag: tag])
receive do
  {^tag, ^ref, :process, ^pid, :tagged_worker_exit} -> :ok
  after 3000 -> raise "owned tagged monitor lost the worker exit"
end
{pid, ref} = BeamLisp.Refs.spawn_owned(fn -> :ok end, :monitor, [])
receive do
  {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
  after 3000 -> raise "legacy owned monitor changed its delivery shape"
end
IO.puts("PASS: owned tagged and legacy monitor delivery")
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    image = parser.parse_args().image.resolve()
    with tempfile.TemporaryDirectory(prefix="bl-owned-monitor-") as temporary:
        script = Path(temporary) / "driver.exs"
        script.write_text(DRIVER)
        env = dict(os.environ, BL_ROOT=str(image), BL_DAEMON="off",
                   ELIXIR_ERL_OPTIONS="+S 2:2 +SDcpu 1:1 +SDio 1:1")
        subprocess.run(["elixir", "-pa", str(image / "ebin"), str(script)],
                       cwd=temporary, env=env, timeout=30, check=True)


if __name__ == "__main__":
    main()
