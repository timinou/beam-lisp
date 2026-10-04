#!/usr/bin/env sh
# server-drop.sh — build the nix server drop and publish it where Foundry looks.
#
# Builds `.#bl-drop`, copies bl.drop to ~/.cache/foundry/drops/bl-nix-<sha8>.drop
# (<sha8> = first 8 hex of its sha256) and prints the two lines a Foundry deploy
# spec `:runtime {:path … :sha256 …}` needs. Idempotent: same inputs → same drop →
# same file, rewritten only if absent or different.
set -eu
cd "$(dirname "$0")/../.."
out=$(nix build .#bl-drop --no-link --print-out-paths)
src=$out/bl.drop
sha=$(sha256sum "$src" | cut -d' ' -f1)
dir=${FOUNDRY_DROP_DIR:-$HOME/.cache/foundry/drops}
dest=$dir/bl-nix-$(printf %s "$sha" | cut -c1-8).drop
mkdir -p "$dir"
if [ ! -f "$dest" ] || [ "$(sha256sum "$dest" | cut -d' ' -f1)" != "$sha" ]; then
  cp "$src" "$dest.tmp.$$" && chmod 755 "$dest.tmp.$$" && mv -f "$dest.tmp.$$" "$dest"
fi
echo "path=$dest"
echo "sha256=$sha"
