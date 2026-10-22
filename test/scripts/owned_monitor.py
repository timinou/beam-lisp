#!/usr/bin/env python3
"""Check native lifetime and solver contracts before SDK assembly."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
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
scope=BeamLisp.Env.fork()
token=BeamLisp.Env.with_env(scope,fn -> BeamLisp.Env.capture_native_context!() end)
true=token==BeamLisp.Env.with_env(scope,fn -> BeamLisp.Env.capture_native_context!() end)
^scope=BeamLisp.Env.resolve_native_context!(token)[:env]
false=Agent.get(BeamLisp.Env, &Map.has_key?(&1, :"native-contexts"))
try do
 :ets.lookup(:beam_lisp_source_lease_domains, {scope, :native_context_index})
 raise "native context index is publicly readable"
rescue _ in ArgumentError -> :ok end
BeamLisp.Env.with_env(scope,fn ->
 value=%{callback: fn -> :private_metadata end}
 lease=BeamLisp.Env.retain_code!([BeamLisp.Env])
 argument=BeamLisp.Env.register_code_metadata!(lease,value)
 ^value=BeamLisp.Env.code_callback_metadata!(lease,argument)
 false=BeamLisp.Env.code_callback_active?(lease,argument)
 BeamLisp.Env.release_code!(lease)
 try do BeamLisp.Env.code_callback_metadata!(lease,argument);raise "released metadata accepted"
 rescue e in ErlangError -> :invalid_code_metadata=e.original end
 for n<-1..255, do: BeamLisp.Env.with_ns("native.context.#{n}",fn -> BeamLisp.Env.capture_native_context!() end)
 try do BeamLisp.Env.with_ns("over-cap",fn -> BeamLisp.Env.capture_native_context!() end);raise "capacity accepted"
 rescue e in ErlangError -> :native_context_capacity=e.original end
end)
true=Process.alive?(Process.whereis(BeamLisp.Env))
BeamLisp.Env.destroy(scope)
try do BeamLisp.Env.resolve_native_context!(token);raise "retired context accepted"
rescue e in ErlangError -> :retired_native_context=e.original end
try do
 BeamLisp.Loader.Server.agent_get_and_update(self(),fn state -> {:forged,state} end,100)
 raise "unattested SDK Agent action accepted"
rescue e in ErlangError -> :unattested_sdk_callback=e.original end
port=Port.open({:spawn_executable, String.to_charlist(System.fetch_env!("BL_KERNEL_PYTHON"))},
               [:binary, :exit_status, args: [System.fetch_env!("BL_KERNEL_FAKE_SOLVER")]])
try do
 "error"=BeamLisp.Z3Port.raw_check(port, "(invalid)\n", false).status
 "unsat"=BeamLisp.Z3Port.raw_check(port, "(assert false)\n", false).status
 "sat"=BeamLisp.Z3Port.raw_check(port, "(assert true)\n", false).status
 after if Port.info(port), do: Port.close(port) end
IO.puts("PASS: owned monitors, private context lifetime and solver error recovery")

'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    image = parser.parse_args().image.resolve()
    with tempfile.TemporaryDirectory(prefix="bl-owned-monitor-") as temporary:
        script = Path(temporary) / "driver.exs"
        script.write_text(DRIVER)
        solver = Path(temporary) / "solver.py"
        solver.write_text("import sys, time\nanswer = 'sat'\nfor line in sys.stdin:\n"
                          " if line.startswith('(reset)'): answer = 'sat'\n"
                          " if line.startswith('(invalid)'):\n"
                          "  print('(error \"rejected\")', flush=True); time.sleep(0.02)\n"
                          " if line.startswith('(assert false)'): answer = 'unsat'\n"
                          " if line.startswith('(check-sat)'): print(answer, flush=True)\n")
        env = dict(os.environ, BL_ROOT=str(image), BL_DAEMON="off",
                   BL_KERNEL_FAKE_SOLVER=str(solver), BL_KERNEL_PYTHON=sys.executable,
                   ELIXIR_ERL_OPTIONS="+S 2:2 +SDcpu 1:1 +SDio 1:1")
        subprocess.run(["elixir", "-pa", str(image / "ebin"), str(script)],
                       cwd=temporary, env=env, timeout=30, check=True)


if __name__ == "__main__":
    main()
