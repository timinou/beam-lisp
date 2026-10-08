#!/bin/sh
# dup-worker.sh — barrier fixture for the duplicate-input race.
#
# Two concurrent extractions of IDENTICAL bytes must be handed DISTINCT request
# (and input) paths; a shared path would let one call truncate the file another
# call's native is reading, and let one call's cleanup unlink the other's input.
#
#   $1  the log file for this run (passed through the worker spec's :args)
#   $2  the request JSON path the boundary appended
#
# Each invocation records the request path it was given plus the input path the
# request names, waits until its peer has registered, then proves its OWN input
# still exists. A shared path shows up as two identical log lines; an unlinked
# input shows up as a missing file.
# The boundary prepends --cold before the configured worker arguments.
[ "${1:-}" != "--cold" ] || shift
log="$1"
req="$2"
printf '%s\n' "$req" >> "$log"
uri=$(grep -o 'file://[^"]*' "$req" | head -1 | sed 's#^file://##')
printf '%s\n' "$uri" >> "$log.input"

i=0
while [ "$i" -lt 300 ]; do
  n=$(wc -l < "$log" 2>/dev/null | tr -d ' ')
  [ "${n:-0}" -ge 2 ] && break
  sleep 0.02
  i=$((i + 1))
done

if [ ! -f "$uri" ]; then
  printf '{"__worker_error__":{"xberg":"worker","message":"input vanished"}}'
  exit 0
fi

printf '{"raw":{"results":[]},"engine":{"nif":"sha256:dup"}}'
