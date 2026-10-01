#!/bin/sh
# Fresh VM, actual launcher boot, verified candidate floor; no staging bypass.
set -eu
ROOT=$(pwd -P)
export BL_ROOT="$ROOT" BEAM_LISP_DEV=1 BL_BUILD_ID=src
: "${BL_EBIN:?}" "${BL_STAGE_SEED:?}"
PA=""
TAG=$(elixir -e 'IO.write("erts#{:erlang.system_info(:version)}-elixir#{System.version()}")')
for d in "${XDG_CACHE_HOME:-$HOME/.cache}"/beam_lisp/ebin/*-"$TAG"/ebin; do
  [ -d "$d" ] && PA="$PA -pa $d"
done
PA="$PA -pa $BL_EBIN"
exec elixir $PA -e '
ebin = System.fetch_env!("BL_EBIN")
seed = System.fetch_env!("BL_STAGE_SEED")
{:ok, [manifest]} = :file.consult(String.to_charlist(Path.join(seed, "manifest.term")))
t = System.monotonic_time(:microsecond)
BeamLisp.Bootstrap.install!(ebin, seed_dir: seed)
seams = %{install_hosts: fn dir -> BeamLisp.Bootstrap.install_hosts!(dir, seed_dir: seed) end,
          manifest: fn -> manifest end,
          halt: fn code -> code end}
code = BeamLisp.Launcher.boot(["version"], seams)
IO.inspect(%{exit: code, boot_us: System.monotonic_time(:microsecond)-t,
             compiler_key: BeamLisp.AOTCache.compiler_key()}, label: "RESULT")
loaded = BeamLisp.Env.namespaces() |> Enum.filter(&BeamLisp.Env.loaded_ns?/1)
IO.inspect(loaded, label: "INITIALIZED-NAMESPACES", limit: :infinity)
IO.inspect(length(loaded), label: "INITIALIZED-COUNT")
System.halt(code)
'
