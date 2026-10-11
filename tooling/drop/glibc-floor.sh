#!/usr/bin/env sh
# glibc-floor.sh DROP|DIR — the highest GLIBC_2.N symbol version any ELF in a
# drop (or an unpacked payload dir) needs. A host whose glibc is older than this
# cannot run the drop (`version 'GLIBC_2.N' not found`). docs/native-bundler.md,
# "Nix-built server drop — glibc floor = host".
#
#   tooling/drop/glibc-floor.sh result/bl.drop        → "2.40  erts-17.0.1/bin/beam.smp"
#   tooling/drop/glibc-floor.sh /path/to/payload      (already unpacked)
#
# Needs `readelf` (binutils). For a .drop it needs the `drop` tool
# (cargo build --release --manifest-path tooling/drop/Cargo.toml) on PATH or in
# $DROP_BIN, to unpack into a temporary directory.
set -eu
target=${1:?usage: glibc-floor.sh DROP|DIR}
command -v readelf >/dev/null || { echo "glibc-floor: readelf not found (binutils)" >&2; exit 2; }

dir=$target
tmp=""
if [ -f "$target" ]; then
  drop=${DROP_BIN:-$(command -v drop || true)}
  [ -n "$drop" ] || { echo "glibc-floor: no 'drop' tool (set DROP_BIN)" >&2; exit 2; }
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  "$drop" unpack "$target" --dir "$tmp/payload" >/dev/null
  dir=$tmp/payload
fi

best=0.0; bestfile="(no dynamic glibc ELF)"
# The executable launcher is outside the payload and may have a higher floor.
# Inspect it too: checking only unpacked files can approve an unstartable drop.
if [ -f "$target" ]; then
  v=$(readelf -V --wide "$target" 2>/dev/null | grep -oE 'GLIBC_2\.[0-9]+' | sed 's/GLIBC_//' | sort -t. -k2 -n | tail -1)
  if [ -n "$v" ]; then best=$v; bestfile="(launcher)"; fi
fi
# every regular file whose first bytes are the ELF magic
for f in $(find "$dir" -type f -size +0); do
  [ "$(head -c4 "$f" | od -An -c | tr -d ' \n')" = '177ELF' ] || continue
  v=$(readelf -V --wide "$f" 2>/dev/null | grep -oE 'GLIBC_2\.[0-9]+' | sed 's/GLIBC_//' | sort -t. -k2 -n | tail -1)
  [ -n "$v" ] || continue
  if [ "${v#2.}" -gt "${best#*.}" ] 2>/dev/null; then best=$v; bestfile=${f#"$dir"/}; fi
done
printf '%s  %s\n' "$best" "$bestfile"
