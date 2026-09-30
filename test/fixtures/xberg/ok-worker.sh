#!/bin/sh
# ok-worker.sh — a canned, protocol-shaped answer with the SAME fields a real
# worker sends, so the two can be compared for artifact semantics (the real one
# swaps the engine identity and the body).
printf '%s' '{"raw":{"results":[{"content":"مادة","mime_type":"text/plain","extraction_method":"native","counts":{"pages":0,"tables":0,"images":0},"processing_warnings":[],"chunks":[{"content":"ما","chunk_type":"unknown","metadata":{"byte_start":0,"byte_end":4,"chunk_index":0,"page_spans":[]}},{"content":"دة","chunk_type":"unknown","metadata":{"byte_start":4,"byte_end":8,"chunk_index":1,"page_spans":[]}}]}],"errors":[],"summary":{"inputs":1,"results":1,"errors":0}},"engine":{"xberg":"1.0.14","crate":"xberg_nif","arch":"fixture","nif":"sha256:fixture"}}'
