#!/bin/sh
# Build a runnable prototype from the UNCHANGED research sources plus a head
# and a tail: the authority (split-server.bl), the wire (split-wire.bl) and one
# app (apps/groceries.bl) run natively on BEAM with three one-line shims.
#   research/split-beam/proto/assemble.sh s0 > /tmp/s0.bl && bl run /tmp/s0.bl
#   research/split-beam/proto/assemble.sh s1 > /tmp/s1.bl && bl run /tmp/s1.bl   # :8791
set -e
P=research/split-beam/proto J=research/js-actors
head_ns() { if [ "$1" = s1 ]; then sed 's/(ns s0 (:require \[bl.json\]))/(ns s1 (:require [bl.json] [web]))/' $P/s0-head.bl; else cat $P/s0-head.bl; fi; }
head_ns "$1"
sed 's/(boolean? v)/(or (= v true) (= v false))/' $J/split-wire.bl
sed 's#(host/emit #(host-emit #g; s#(host/raise #(throw #g; s#(rt-register-input!)#nil#' $J/split-server.bl
sed 's#^(split/defapp #(defapp-native #' $J/apps/groceries.bl
if [ "$1" = s1 ]; then sed -n '1,/^; ── driver/p' $P/s0-tail.bl | sed '$d'; cat $P/s1-tail.bl; else cat $P/s0-tail.bl; fi
