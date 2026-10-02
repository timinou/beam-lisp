#!/bin/sh
# oversized-worker.sh — a hostile worker that answers with more bytes than the
# output budget allows. The parent must refuse it on SIZE, without reading it
# into the BEAM, and must still delete its temp file.
i=0
while [ "$i" -lt 4096 ]; do printf 'x'; i=$((i + 1)); done
