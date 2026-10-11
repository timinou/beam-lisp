#!/usr/bin/env bash
# Sequential source -> checked JS -> actual runtime contract checks.
# Run under the repository's usual memory cap. Optional: BL_OBSERVATION_BENCH=1.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
observation_stage=$(mktemp -d /tmp/bl-observation-check.XXXXXX)
trap 'rm -rf "$observation_stage"' EXIT
cd "$root"
bl_bin=${BL_BIN_UNDER_TEST:-$root/bin/bl}
export BL_GATEWAY=off BL_SOURCE_ROOT="$root"
export BL_OBSERVATION_OUT="$observation_stage/browser"
export BL_ACTOR_OBSERVATION_OUT="$observation_stage/actor"
"$bl_bin" --cold test test/bl/vm/observation_test.bl test/bl/proc/work_test.bl test/bl/js_actor_observation_test.bl
"$bl_bin" --cold js build js.observation -p priv/lib --out "$BL_OBSERVATION_OUT"
node --test test/js/observation.test.mjs
"$bl_bin" --cold run -p priv/lib test/js/build-observation-fixture.bl
node --test test/js/actor-observation.test.mjs
if [ "${BL_OBSERVATION_BENCH:-0}" = 1 ]; then
  node test/js/actor-observation.bench.mjs
fi
