#!/usr/bin/env python3
"""A build cache hit in a fresh VM must restore SDK evidence before init.

Run under systemd-run with MemoryMax/MemorySwapMax. Only two SDK sources are
built, in dependency order; the second VM must compile neither source.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
args = parser.parse_args()
root = args.root.resolve()

with tempfile.TemporaryDirectory(prefix='bl-sdk-build-cache-') as temporary:
    scratch = Path(temporary)
    script = scratch / 'probe.bl'
    script.write_text('''(ns sdk-build-cache.probe (:require [build :as build]))
(let [[root scratch phase] (BeamLisp/argv)
      out (str scratch "/ebin")
      trace (tuple :Elixir.BeamLisp.AOT :compile_file 2)]
  (erlang/trace_pattern trace true (list :local :call_count))
  (doseq [leaf ["std/vm/native.bl" "lib/datom/vector.bl"]]
    (let [result (build/run {:sources [(str root "/priv/" leaf)]
                             :root (str root "/priv") :out out :scope :scoped :jobs 1})]
      (when (seq (:errors result))
        (throw (ex-info "SDK build failed" {:phase phase :result result})))))
  (when-not (BeamLisp.AOT/sdk_unit_compiled? "vm.native")
    (throw (ex-info "Cache hit lost the SDK producer" {})))
  (when-not (= :public (BeamLisp.AOT/sdk_declaration_kind "vm.native" "host-module"))
    (throw (ex-info "Cache hit lost public declaration metadata" {})))
  (when-not (= :private (BeamLisp.AOT/sdk_declaration_kind "vm.native" "rep-bin"))
    (throw (ex-info "Cache hit lost private declaration metadata" {})))
  (let [calls (elem (erlang/trace_info trace :call_count) 1)]
    (when (and (= phase "warm") (not= 0 calls))
      (throw (ex-info "Cache hit recompiled source" {:calls calls})))
    (println (str "SDK-CACHE " phase " compile-calls=" calls))))
''')
    env = {**os.environ, 'BEAM_LISP_AOT_CACHE_DIR': str(scratch / 'cache'),
           'BEAM_LISP_AOT_CACHE': 'on', 'BL_DAEMON': 'off'}
    for phase in ('cold', 'warm'):
        # Destroy all build state: only the immutable shared cache survives.
        shutil.rmtree(scratch / 'ebin', ignore_errors=True)
        start = time.monotonic()
        result = subprocess.run([str(root / 'bin/bl'), '--cold', 'run', str(script),
                                 '--', str(root), str(scratch), phase],
                                cwd=root, env=env, text=True, capture_output=True,
                                timeout=300)
        print(f'{phase}: {time.monotonic() - start:.3f}s', flush=True)
        print(result.stdout, end='', flush=True)
        if result.returncode:
            raise RuntimeError(result.stderr)
        assert f'SDK-CACHE {phase} ' in result.stdout, result.stdout
