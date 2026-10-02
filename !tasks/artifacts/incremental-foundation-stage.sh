#!/bin/sh
# Run from the repo root in a bounded systemd scope.
# Caller creates an isolated lib/beam_lisp-0.1.0/{ebin,priv} layout first;
# priv points at this checkout's priv directory, never at a copied old source.
# Required: BL_EBIN, BL_STAGE_PHASE; seed phase also needs BL_STAGE_SEED.
set -eu
ROOT=$(pwd -P)
export BL_ROOT="$ROOT" BEAM_LISP_DEV=1 BL_BUILD_ID=src
: "${BL_EBIN:?isolated ebin required}" "${BL_STAGE_PHASE:?phase required}"
PA=""
for d in "$ROOT"/deps/*/ebin "$ROOT"/_build/*/lib/*/ebin; do
  [ -d "$d" ] && PA="$PA -pa $d"
done
TAG=$(elixir -e 'IO.write("erts#{:erlang.system_info(:version)}-elixir#{System.version()}")')
for d in "${XDG_CACHE_HOME:-$HOME/.cache}"/beam_lisp/ebin/*-"$TAG"/ebin; do
  [ -d "$d" ] && PA="$PA -pa $d"
done
PA="$PA -pa $BL_EBIN"
if [ "$BL_STAGE_PHASE" = hosts ]; then
  "$ROOT/bin/bl-stage-hosts" "$ROOT/priv/bootstrap/seed/manifest.term" \
    "$ROOT/priv/bootstrap/seed" "$BL_EBIN"
fi
export BL_STAGE_PROGRAM="$ROOT/!tasks/artifacts/incremental-foundation-stage.bl"
exec elixir $PA -e '
ebin = System.fetch_env!("BL_EBIN")
staging_file = Path.join(ebin, ".bootstrap_staging.term")
if System.fetch_env!("BL_STAGE_PHASE") == "hosts" do
  BeamLisp.Bootstrap.install!(ebin)
  ns = Application.get_env(:beam_lisp, :bootstrap_staging, [])
  File.write!(staging_file, :io_lib.format("~p.~n", [ns]))
else
  # Only the namespace authority produced by the verified previous floor is
  # carried into the next generation; no manifest hash or compiler key is forged.
  {:ok, [ns]} = :file.consult(String.to_charlist(staging_file))
  Application.put_env(:beam_lisp, :bootstrap_staging, ns)
end
{:ok, _} = Application.ensure_all_started(:beam_lisp)
BeamLisp.eval(File.read!(System.fetch_env!("BL_STAGE_PROGRAM")))
'
