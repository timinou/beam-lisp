#!/usr/bin/env sh
# check-pins.sh — the build's nixpkgs must be the rev the servers run.
#
# beam-lisp/flake.nix pins `nixpkgs` by rev; ../foundry/infra/flake.lock pins the
# servers' nixpkgs. The drop's glibc floor is only "<= the host" while they agree
# (docs/native-bundler.md §16). Exits 1 on drift, 2 when a pin cannot be read.
#
#   tooling/drop/check-pins.sh
#   FOUNDRY_LOCK=/path/flake.lock FLAKE_NIX=/path/flake.nix tooling/drop/check-pins.sh
set -eu
here=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd -P)
flake_nix=${FLAKE_NIX:-$here/flake.nix}
if [ -n "${FOUNDRY_LOCK:-}" ]; then
  lock=$FOUNDRY_LOCK
elif [ -f "$here/../foundry/infra/flake.lock" ]; then
  lock=$here/../foundry/infra/flake.lock
else
  # Older combined checkouts still keep Foundry under apps/.
  lock=$here/apps/foundry/infra/flake.lock
fi

mine=$(sed -n 's|^ *nixpkgs\.url *= *"github:NixOS/nixpkgs/\([0-9a-f]\{40\}\)";.*|\1|p' "$flake_nix")
[ -n "$mine" ] || { echo "check-pins: no 40-hex nixpkgs rev in $flake_nix" >&2; exit 2; }
[ -f "$lock" ] || { echo "check-pins: $lock not found" >&2; exit 2; }
theirs=$(python3 -c '
import json,sys
l=json.load(open(sys.argv[1]))
n=l["nodes"]; r=l["nodes"][l["root"]]["inputs"]["nixpkgs"]
print(n[r]["locked"]["rev"] if isinstance(r,str) else n["nixpkgs"]["locked"]["rev"])' "$lock") \
  || { echo "check-pins: cannot read nixpkgs rev from $lock" >&2; exit 2; }

if [ "$mine" = "$theirs" ]; then
  echo "pins ok: nixpkgs $mine"
else
  echo "PIN DRIFT: beam-lisp flake.nix nixpkgs=$mine  but  foundry flake.lock nixpkgs=$theirs" >&2
  echo "fix: nix flake lock --override-input nixpkgs github:NixOS/nixpkgs/$theirs (and edit flake.nix url)" >&2
  exit 1
fi
