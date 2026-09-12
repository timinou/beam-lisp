#!/usr/bin/env bash
# W0-P5 — hand-assemble a release tree whose ONLY generated piece is the boot
# script, then boot it. Everything else (lib tree, ERTS, bin/bl, sys.config,
# vm.args, env.sh, elixir, iex) is reused verbatim from the shipped drop, so a
# pass isolates release assembly to exactly the part under test.
#
# Notable by construction: the tree has NO `consolidated/` directory — this is
# also the unconsolidated-boot probe.
#
# Usage: p5_handbuilt_release.sh <payload-root> <tree-dir>
set -euo pipefail

P="${1:?payload root}"
T="${2:?tree dir}"
VS=0.1.0
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "P5  payload=$P tree=$T"
rm -rf "$T"
mkdir -p "$T/bin" "$T/releases/$VS"

# lib/ and erts/ are read-only for this probe: hardlink to keep it cheap.
cp -al "$P/lib" "$T/lib"
cp -al "$P/erts-17.0.1" "$T/erts-17.0.1"

# The release shell entry, and the per-release templates Mix emits.
cp "$P/bin/bl" "$T/bin/bl"
chmod +x "$T/bin/bl"
for f in sys.config vm.args remote.vm.args env.sh elixir iex; do
  cp "$P/releases/$VS/$f" "$T/releases/$VS/$f"
done
chmod +x "$T/releases/$VS/elixir" "$T/releases/$VS/iex" 2>/dev/null || true
cp "$P/releases/$VS/start_clean.script" "$T/releases/$VS/"
cp "$P/releases/$VS/start_clean.boot"   "$T/releases/$VS/"
cp "$P/releases/COOKIE" "$T/releases/COOKIE"
printf '17.0.1 %s' "$VS" > "$T/releases/start_erl.data"

# Generate start.script + start.boot from the shipped .rel, in the drop's VM.
BL_PAYLOAD="$P" BL_OUT="$T/releases/$VS" \
  "$P/bin/bl" eval "Code.eval_file(\"$HERE/gen_start_boot.exs\")"

echo "P5  tree contents:"
ls -A "$T" "$T/releases" "$T/releases/$VS"

echo "P5  consolidated dir present? $([ -d "$T/releases/$VS/consolidated" ] && echo yes || echo NO)"

echo "P5  --- BOOT TEST: Elixir eval through the release script ---"
"$T/bin/bl" eval 'IO.puts("P5  BOOT OK elixir=#{System.version()}")'

echo "P5  --- BOOT TEST: the language, through the release script ---"
"$T/bin/bl" eval 'BeamLisp.Ns.Bl.Cli.main(["eval","(+ 40 2)"])'

echo "P5  --- BOOT TEST: exit code of a failing expression ---"
set +e
"$T/bin/bl" eval 'IO.puts("P5  still alive")' >/dev/null 2>&1
echo "P5  eval exit=$?"
set -e

echo "P5  DONE"
