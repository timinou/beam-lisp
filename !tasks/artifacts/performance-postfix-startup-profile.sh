#!/bin/sh
# Instrumented fresh startup; wall-only samples use performance-postfix-cli.py.
set -eu
ROOT=$(pwd -P)
export BL_ROOT="$ROOT" BL_EBIN="$ROOT/.bl/lib/beam_lisp-0.1.0/ebin"
export BEAM_LISP_DEV=1 BL_BUILD_ID=src
PA=""
for d in "$ROOT"/deps/*/ebin "$ROOT"/_build/*/lib/*/ebin; do
  [ -d "$d" ] && PA="$PA -pa $d"
done
TAG=$(elixir -e 'IO.write("erts#{:erlang.system_info(:version)}-elixir#{System.version()}")')
for d in "${XDG_CACHE_HOME:-$HOME/.cache}"/beam_lisp/ebin/*-"$TAG"/ebin; do
  [ -d "$d" ] && PA="$PA -pa $d"
done
PA="$PA -pa $BL_EBIN"
exec elixir $PA -e '
measure = fn label, f, args ->
  t = System.monotonic_time(:microsecond)
  {:reductions, r0} = Process.info(self(), :reductions)
  answer = apply(f, args)
  {:reductions, r1} = Process.info(self(), :reductions)
  IO.inspect({label, Enum.map(args, fn x -> if is_binary(x), do: x, else: :arg end),
              System.monotonic_time(:microsecond)-t, r1-r0}, label: "POSTFIX-PHASE")
  answer
end
keys = [:install_hosts, :manifest, :key_now, :boot_namespaces, :provenance,
        :start_app, :ensure_loaded, :fetch, :invoke]
seams = Map.new(keys, fn k ->
  f = BeamLisp.Launcher.default_seam(k)
  {:arity, n} = :erlang.fun_info(f, :arity)
  wrapped = case n do
    0 -> fn -> measure.(k, f, []) end
    1 -> fn a -> measure.(k, f, [a]) end
    2 -> fn a,b -> measure.(k, f, [a,b]) end
    3 -> fn a,b,c -> measure.(k, f, [a,b,c]) end
  end
  {k, wrapped}
end)
seams = Map.put(seams, :halt, fn code -> IO.inspect(code, label: "EXIT"); code end)
:cprof.start()
t = System.monotonic_time(:microsecond)
code = BeamLisp.Launcher.boot(["version"], seams)
IO.inspect(System.monotonic_time(:microsecond)-t, label: "POSTFIX-INSTRUMENTED-BOOT-US")
:cprof.pause()
{_total, modules} = :cprof.analyse()
wanted = [:eval_string, :eval_form, :do_load, :compile_source, :ns_closure_hash]
counts = for {_m, _n, calls} <- modules, {{m,f,a}, n} <- calls, f in wanted, do: {{m,f,a},n}
IO.inspect(counts, label: "POSTFIX-LOAD-COUNTERS", limit: :infinity)
loaded = BeamLisp.Env.namespaces() |> Enum.filter(&BeamLisp.Env.loaded_ns?/1)
IO.inspect(loaded, label: "POSTFIX-INITIALIZED-NAMESPACES", limit: :infinity)
IO.inspect(length(loaded), label: "POSTFIX-INITIALIZED-COUNT")
System.halt(code)
'
