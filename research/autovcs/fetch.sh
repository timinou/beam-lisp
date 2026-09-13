#!/usr/bin/env bash
# autovcs/fetch.sh — vendor the pinned jj into a cache, verified by sha256.
#
# Prints the binary's path on stdout. Idempotent: a cached, digest-matching
# binary is reused. Nothing here writes into the repository or into PATH —
# research/autovcs/ stays a probe.
#
#   AUTOVCS_CACHE=/somewhere  override the cache root (default ~/.cache/autovcs)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
lock="$here/jj.lock"
cache="${AUTOVCS_CACHE:-$HOME/.cache/autovcs}"

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)          sec=linux.x86_64 ;;
  Linux/aarch64|Linux/arm64) sec=linux.aarch64 ;;
  Darwin/x86_64)         sec=macos.x86_64 ;;
  Darwin/arm64|Darwin/aarch64) sec=macos.aarch64 ;;
  *) echo "autovcs: no pinned jj for $(uname -s)/$(uname -m)" >&2; exit 2 ;;
esac

field() { # field <section> <key>
  awk -v s="[$1]" -v k="$2" '
    $0 == s { in_sec = 1; next }
    /^\[/   { in_sec = 0 }
    in_sec && $1 == k { gsub(/.*= *"/, ""); gsub(/".*/, ""); print; exit }
  ' "$lock"
}

version=$(awk -F'"' '/^version *=/{print $2}' "$lock")
url=$(field "$sec" url)
sha=$(field "$sec" sha256)
[ -n "$url" ] && [ -n "$sha" ] || { echo "autovcs: incomplete lock entry [$sec]" >&2; exit 2; }

dir="$cache/jj-$version-$sec"
bin="$dir/jj"
stamp="$dir/.verified"
# A cache hit means: the binary is there AND the stamp records the digest of the
# artifact that produced it. The extracted tree is never hashed against the
# archive's digest — those are different bytes.
if [ -x "$bin" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$sha" ]; then
  echo "$bin"; exit 0
fi

echo "autovcs: fetching jj $version ($sec)" >&2
mkdir -p "$dir"
archive="$dir/archive.$(basename "$url")"
curl -sSL --fail --max-time 300 -o "$archive" "$url"
got=$(sha256sum "$archive" | cut -d' ' -f1)
if [ "$got" != "$sha" ]; then
  echo "autovcs: digest mismatch for $url" >&2
  echo "  expected $sha" >&2
  echo "  got      $got" >&2
  rm -f "$archive"; exit 1
fi

case "$url" in
  *.tar.gz) tar -xzf "$archive" -C "$dir" ;;
  *.zip)    unzip -qo "$archive" -d "$dir" ;;
esac
rm -f "$archive"
chmod +x "$bin"
printf '%s\n' "$sha" > "$stamp"
echo "$bin"
