#!/usr/bin/env bash
# W0-P1 — does a launcher built from HEAD export BL_BIN, and can `drop pack`
# round-trip a hand-assembled release into a working drop?
#
# BL_BIN is the design's mechanism for recovering the launcher prefix from
# inside a running drop (`bl self-build` must graft itself). The SHIPPED binary
# does not have it (strings: 0 occurrences, built 15:55); launcher.rs does
# (lines 270/297/340/456, modified 18:41). This probe settles whether the
# current source produces an artifact that carries it.
#
# Usage: p1_launcher.sh <drop-bin-dir> <release-tree> <workdir>
set -euo pipefail

BIN="${1:?dir containing drop + drop-launcher}"
REL="${2:?release tree}"
WORK="${3:?workdir}"
mkdir -p "$WORK"

echo "P1  launcher=$BIN/drop-launcher release=$REL"

echo "=== P1a: does the launcher binary carry BL_BIN? ==="
echo -n "  BL_BIN: ";  strings -a "$BIN/drop-launcher" | grep -c BL_BIN || true
echo -n "  BL_BIN in drop(pack tool): "; strings -a "$BIN/drop" | grep -c BL_BIN || true
echo -n "  BL_DAEMON (control): "; strings -a "$BIN/drop-launcher" | grep -c BL_DAEMON || true

echo "=== P1b: pack the hand-assembled tree into a drop ==="
rm -f "$WORK/bl-p1a" "$WORK/bl-p1b"
"$BIN/drop" pack --release "$REL" --out "$WORK/bl-p1a" --launcher "$BIN/drop-launcher"
"$BIN/drop" inspect "$WORK/bl-p1a"

echo "=== P1c: deterministic? pack again, compare sha256 ==="
"$BIN/drop" pack --release "$REL" --out "$WORK/bl-p1b" --launcher "$BIN/drop-launcher" >/dev/null
sha256sum "$WORK/bl-p1a" "$WORK/bl-p1b" | awk '{print "  " $0}'
a=$(sha256sum "$WORK/bl-p1a" | cut -d' ' -f1)
b=$(sha256sum "$WORK/bl-p1b" | cut -d' ' -f1)
echo "  identical=$([ "$a" = "$b" ] && echo YES || echo NO)"

echo "=== P1d: does the new drop run, and is BL_BIN the drop path? ==="
echo -n "  eval (+ 1 2) -> "; BL_DAEMON=off "$WORK/bl-p1a" eval '(+ 1 2)' 2>&1 | tail -1
echo -n "  BL_BIN -> "; BL_DAEMON=off "$WORK/bl-p1a" eval '(System/get_env "BL_BIN")' 2>&1 | tail -1
echo -n "  HOME (control) -> "; BL_DAEMON=off "$WORK/bl-p1a" eval '(System/get_env "HOME")' 2>&1 | tail -1

echo "=== P1e: trailer golden vectors vs the shipped tool ==="
"$BIN/drop" inspect "$WORK/bl-p1a" | sed 's/^/  new: /'
"$BIN/drop" inspect /home/user/code/undefine/beam-lisp/bl | sed 's/^/  shipped: /'

echo "P1  DONE"
