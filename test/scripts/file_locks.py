#!/usr/bin/env python3
"""Exercise kernel custody across a BEAM and an independent OS process.

Run under a process-tree memory cap, with --image APP (ebin/ and priv/).
One VM serves all assertions; kill it to verify crash release as well.
"""
import argparse
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile

DRIVER = r'''
BeamLisp.LazyMemo.ensure_loaded!()
IO.puts("READY")
loop = fn loop, held ->
  case IO.gets("") do
    "lock\n" ->
      {status, handle} = BeamLisp.LazyMemo.nif_file_lock(System.fetch_env!("LOCK_PATH"), false, false)
      IO.puts(Atom.to_string(status))
      loop.(loop, if(status == :ok, do: handle, else: held))
    "unlock\n" ->
      BeamLisp.LazyMemo.nif_file_unlock(held)
      IO.puts("released")
      loop.(loop, nil)
    nil -> :ok
  end
end
loop.(loop, nil)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    args = parser.parse_args()
    image = args.image.resolve()
    with tempfile.TemporaryDirectory(prefix="bl-file-locks-") as temp:
        root = Path(temp)
        script = root / "driver.exs"
        script.write_text(DRIVER)
        anchor = root / "anchor"
        env = dict(os.environ, LOCK_PATH=str(anchor), ERL_FLAGS="+S 2:2 +SDcpu 1:1 +SDio 1:1")
        vm = subprocess.Popen(["elixir", "-pa", str(image / "ebin"), str(script)],
                              cwd=root, env=env, text=True, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE)
        def answer(command):
            vm.stdin.write(command + "\n")
            vm.stdin.flush()
            return vm.stdout.readline().strip()
        try:
            assert vm.stdout.readline().strip() == "READY"
            with anchor.open("a+") as independent:
                fcntl.flock(independent, fcntl.LOCK_EX | fcntl.LOCK_NB)
                assert answer("lock") == "busy", "a foreign owner must exclude BEAM"
                fcntl.flock(independent, fcntl.LOCK_UN)
                assert answer("lock") == "ok"
                try:
                    fcntl.flock(independent, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    raise AssertionError("BEAM custody did not exclude a foreign writer")
                assert answer("unlock") == "released"
                fcntl.flock(independent, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(independent, fcntl.LOCK_UN)
                assert answer("lock") == "ok"
                vm.kill()
                vm.wait(timeout=10)
                fcntl.flock(independent, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print("PASS: cross-process exclusion, explicit release, and VM crash release")
        finally:
            if vm.poll() is None:
                vm.kill()
            vm.wait(timeout=10)


if __name__ == "__main__":
    main()
