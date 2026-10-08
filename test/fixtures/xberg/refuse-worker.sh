#!/bin/sh
# refuse-worker.sh — speaks the protocol and refuses in-band: the envelope the
# shipped worker sends when it has no runtime to load. Exit 0 — a refusal is a
# response, and the parent must surface the WORKER's kind, not its own.
printf '%s' '{"__worker_error__":{"xberg":"runtime","message":"no runtime for the worker","worker":"fixture"}}'
