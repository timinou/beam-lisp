#!/bin/sh
# Fresh VM: candidate authority, no previous-generation staging exemption.
set -eu
ROOT=$(pwd -P)
: "${BL_COLD_EBIN:?}" "${BL_CANDIDATE_SEED:?}"
export BL_ROOT="$ROOT" BEAM_LISP_DEV=1 BL_BUILD_ID=src
PA=""
for d in "$ROOT"/deps/*/ebin "$ROOT"/_build/*/lib/*/ebin; do
  [ -d "$d" ] && PA="$PA -pa $d"
done
TAG=$(elixir -e 'IO.write("erts#{:erlang.system_info(:version)}-elixir#{System.version()}")')
for d in "${XDG_CACHE_HOME:-$HOME/.cache}"/beam_lisp/ebin/*-"$TAG"/ebin; do
  [ -d "$d" ] && PA="$PA -pa $d"
done
"$ROOT/bin/bl-stage-hosts" "$BL_CANDIDATE_SEED/manifest.term" "$BL_CANDIDATE_SEED" "$BL_COLD_EBIN"
exec elixir $PA -pa "$BL_COLD_EBIN" -e '
BeamLisp.Bootstrap.install!(System.fetch_env!("BL_COLD_EBIN"), seed_dir: System.fetch_env!("BL_CANDIDATE_SEED"))
if Application.get_env(:beam_lisp, :bootstrap_staging, []) != [], do: raise("candidate is not the current generation")
{:ok, _} = Application.ensure_all_started(:beam_lisp)
IO.inspect({:cold_candidate, BeamLisp.Optimize.version(), BeamLisp.eval("(+ 1 2)"), BeamLisp.eval("(lists/foldl (fn [x a] (+ a x)) 0 (lists/map (fn [x] (* x 2)) (lists/seq 0 31)))"), BeamLisp.AOTCache.current_compiler_key()})
'
