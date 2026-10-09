#!/usr/bin/env bash
set -euo pipefail
# Source-free project pin must name the artifact produced by the verified build.
repo_path=/home/user/code/undefine/beam-lisp--runtime-opportunities
sdk_artifact=/home/user/tmp/runtime-opportunities/release/bl-sdk-merged
export TMPDIR=/home/user/tmp/runtime-opportunities/release
export BL_TEST_SOURCE_ROOT="$repo_path"
unset BL_USE
ulimit -v 8388608
exec timeout 1200 "$sdk_artifact" test \
  "$repo_path/test/bl/system/loading_test.bl" \
  "$repo_path/test/bl/source_graph_test.bl" \
  "$repo_path/test/bl/build_plan_test.bl" \
  "$repo_path/test/bl/loader_queue_admission_test.bl" \
  "$repo_path/test/bl/datom/canonical_snapshot_test.bl" \
  "$repo_path/test/bl/datom/index_publication_test.bl" \
  "$repo_path/test/bl/datom/rank_demand_test.bl" \
  "$repo_path/test/bl/datom/rank_query_test.bl" \
  "$repo_path/test/bl/datom/index_coverage_test.bl" \
  "$repo_path/test/bl/datom/concurrency_test.bl" \
  "$repo_path/test/bl/foundry_env_test.bl" \
  "$repo_path/test/bl/aot_cache_host_test.bl"
