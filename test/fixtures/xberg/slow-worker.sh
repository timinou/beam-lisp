#!/bin/sh
# slow-worker.sh — never answers, so the boundary's hard-kill is what ends it.
# An OS worker's timeout is only honest if the thing it killed is PROVEN dead;
# this fixture is the proof that `timeout -s KILL` (and the whole group) ran.
sleep 60
