#!/usr/bin/env bash
# W1 acceptance (G8) — the amplifier is gone.
#
# Before the tier split, `compiler_key/0` hashed the whole of `priv/boot/`,
# which held the build driver too. Editing a build-tool file therefore moved the
# toolchain key, invalidated every manifest entry, and forced a full prelude
# rebuild (~300 beams) — measured as 8 key generations in ~21h.
#
# After the split: codegen (`priv/boot/`) keys the codegen, the driver
# (`priv/build/`) keys itself, and the driver's key folds the codegen key in.
# This script PROVES both directions with throwaway probe sources that it
# creates and deletes, so the tree is left exactly as it was found.
#
# Usage: research/selfbuild/w1_amplifier.sh
set -euo pipefail

TREE="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TREE"

PROBE_BUILD="priv/build/w1probe.bl"
PROBE_BOOT="priv/boot/w1probe.bl"
MANIFEST="_build/dev/lib/beam_lisp/.mix/compile.beam_lisp"

cleanup() { rm -f "$PROBE_BUILD" "$PROBE_BOOT"; }
trap cleanup EXIT

keys() {
  mix run --no-compile --no-start -e '
BeamLisp.AOTCache.reset_keys()
IO.puts("codegen=" <> BeamLisp.AOTCache.compiler_key())
IO.puts("driver=" <> BeamLisp.AOTCache.build_key())
' 2>/dev/null | grep -E '^(codegen|driver)='
}

# Which sources does the build consider stale, given the manifest on disk and
# the LIVE keys? Asks the driver's own `fresh?/5`, the predicate `run` uses.
stale() {
  mix run --no-compile --no-start -e '
BeamLisp.AOT.boot()
BeamLisp.Loader.ensure_loaded("build")
out = "_build/dev/lib/beam_lisp/ebin"
m = File.read!("'"$MANIFEST"'") |> :erlang.binary_to_term()
ck = BeamLisp.AOTCache.compiler_key()
bk = BeamLisp.AOTCache.build_key()
fresh? = BeamLisp.Env.fetch!("build", "fresh?")

check = fn path, tkey ->
  e = m[path]
  {path, BeamLisp.RT.invoke(fresh?, [m, path, e[:hash], tkey, out])}
end

boot = check.("priv/boot/compiler.bl", ck)
drv = check.("priv/build/build.bl", bk)
std = check.("priv/std/errors.bl", ck)
IO.puts("stale? boot/compiler.bl=#{not elem(boot, 1)} driver/build.bl=#{not elem(drv, 1)} std/errors.bl=#{not elem(std, 1)}")
' 2>/dev/null | grep -E '^stale\?'
}

echo "== 1. baseline =="
keys
echo -n "   "; stale

echo "== 2. add a DRIVER source (priv/build/w1probe.bl) =="
printf '(ns w1probe)\n' > "$PROBE_BUILD"
echo -n "   "
keys
echo -n "   "; stale
mix compile 2>&1 | grep -E "building [0-9]+ source" || echo "   (no rebuild reported)"
echo -n "   after the build: "; stale

echo "== 3. remove it again =="
rm -f "$PROBE_BUILD"
keys
mix compile 2>&1 | grep -E "building [0-9]+ source" || echo "   (no rebuild reported)"

echo "== 4. add a CODEGEN source (priv/boot/w1probe.bl) =="
printf '(ns w1probe)\n' > "$PROBE_BOOT"
echo -n "   "
keys
echo -n "   "; stale

echo "== 5. remove it again =="
rm -f "$PROBE_BOOT"
keys

echo "== expected =="
cat <<'EOF'
   1: baseline keys, nothing stale
   2: codegen UNCHANGED, driver MOVED; ONLY the driver source goes stale, and a
      build touches 1 source  <-- THIS IS THE FIX
   3: back to the step-1 keys
   4: codegen MOVED and the driver MOVED with it (the driver folds the codegen
      key in, because the codegen compiles the driver), so EVERYTHING goes
      stale -- correct, and the exact opposite of step 2
   5: back to the step-1 keys
EOF
