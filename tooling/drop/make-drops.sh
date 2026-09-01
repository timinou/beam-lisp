#!/usr/bin/env sh
# make-drops.sh — build `drop` bundles for every target with a staged release.
#
# The only packaging decision is bundled-OTP-or-not:
#   * no OTP bundled   → `MIX_ENV=prod mix escript.build`   (4 MB, needs OTP on host)
#   * OTP bundled      → `drop pack` (this script)          (~100 MB, self-contained)
#
# v1 matrix (docs/native-bundler.md §5):
#   linux/x86_64  — full end-to-end on a linux x86_64 host (verified).
#   linux/aarch64 — pack works once datom/explorer NIFs are built for
#                   aarch64-musl (the beam-machine linux bundles are static
#                   musl; OTP libs are taken from the bundle automatically).
#   macos/*       — pack works; the LAUNCHER needs a darwin build:
#                   `cargo zigbuild --target x86_64-apple-darwin` (or a mac runner).
#   windows/x64   — same; launcher triple x86_64-pc-windows-gnu + 7z for the
#                   OTP installer unpack.
#
# usage: ./make-drops.sh [RELEASE_DIR]   (default: MIX_ENV=prod mix release output)
set -e
cd "$(dirname "$0")"

RELEASE_DIR="${1:-}"
DROP_BIN="${CARGO_TARGET_DIR:-$HOME/.cache/cargo-target}/release/drop"

if [ -z "$RELEASE_DIR" ]; then
  echo "make-drops: building host release (MIX_ENV=prod mix release bl)…"
  MIX_ENV=prod mix release bl --path /tmp/drop-rel >/dev/null
  RELEASE_DIR=/tmp/drop-rel/bl
fi

echo "make-drops: building launcher + pack tool (host)…"
cargo build --release

HOST_TARGET="linux/x86_64"
[ "$(uname -s)" = Darwin ] && HOST_TARGET="macos/$(uname -m)"
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ] && HOST_TARGET="linux/aarch64"

echo "make-drops: packing host drop (host ERTS, full tier)…"
"$DROP_BIN" pack --release "$RELEASE_DIR" --out ./bl.drop

echo "make-drops: packing cross-target drops from the erts.lock (needs per-target NIFs for a green run)…"
for T in linux/x86_64 linux/aarch64 macos/universal windows/x64; do
  [ "$T" = "$HOST_TARGET" ] && continue
  OUT="./bl.$(echo "$T" | tr '/' '-').drop"
  echo "── $T → $OUT"
  "$DROP_BIN" pack --release "$RELEASE_DIR" --target "$T" --erts auto --out "$OUT" || \
    echo "make-drops: $T failed (missing per-target NIFs? see docs/native-bundler.md §5)"
done

echo "make-drops: done — artifacts in $(pwd)"
