# Startup performance review — source-free migration + lazy-engine integration

**Scope.** Read-only review of the startup path introduced/reshaped by
`856d49c7` (*Cut over repository Elixir sources to pinned BL hosts*),
`13659b7d` (*Integrate versioned lazy engine …*) and merged at `801ebbbc`.
No source was modified; no bookkeeping (org/memory) was written.
Working tree inspected at `52f0a50d` (main), `build/` image dated 09-30 05:06.

**Method.** Static read of `bin/bl`, `bin/bl-stage-hosts`,
`priv/host/{launcher,bootstrap,aot_cache,aot,loader,tiers,application,beam_lisp}.bl`,
`priv/build/{build,build-log,build-plan}.bl`, plus `git show` of the
pre-migration twins (`lib/beam_lisp/{aot,aot_cache,bootstrap,env,loader}.ex`,
old `bin/bl`). Dynamic measurement with:
(1) `bin/bl version` wall-clock, (2) `bin/bl-stage-hosts` cold/warm,
(3) a seam-timed boot (`BeamLisp.Launcher.boot/2` driven with instrumented
seams — the launcher's own test door), (4) `erlang:trace_pattern(…, call_time)`
per-function call counts, (5) beam-attribute and on-disk state inspection.

**Caveats.** This host is heavily contended (every measured run has
`user+sys` ≈ 1.5–2× wall), so **wall times are upper bounds**; the call counts,
byte counts, key comparisons and code paths are the load-bearing evidence.
No historical multi-minute figure is inferred from source — every number below
was measured this session on this checkout, or is quoted from a measurement the
repository itself records, named as such. Nothing here claims a general
speed-up factor for the lazy-engine integration.

---

## Current startup: pay for needed work

An alias declaration records names and captured search roots. Initialization
waits for a real use: call, var access, macro expansion or protocol extension.
Bare requires and `:refer :all` stay eager. This lets a metadata command avoid
initializing unrelated application features.

Freshness asks cheap generation questions before hashing source closures. A
validation pass shares one source snapshot; the next pass sees edits. Keys
separate ordinary dependency bodies from interfaces, while macro expansion
requires stronger invalidation. Scoped repair preserves unrelated artifacts.

A complete inventory includes literate files. The seed and library image are
published as one verified generation; a direct cold namespace entry boots its
registry before asking whether that namespace is ready.

Final fresh `version` wall samples: **9.454097, 7.465494, 8.072850 s**
(median **8.072850 s**). Strict version: **8.720416 s**. All exits were zero.
The checkpoint instrumentation initialized 21 namespaces; interpretation counters
alone do not identify source fallback because bootstrap explicitly registers
data readers. See [final measurements](performance-final-measurements.json).

The measurements and findings below retain the original review checkpoint.
Their reproduction snippets are historical; current drivers are
`performance-postfix-cli.py` and `performance-postfix-startup-profile.sh`.

## 1. Boot anatomy (measured)

`bin/bl version` on this checkout: **110 s** and **132 s** (two runs).
A seam-instrumented boot (`BL_EBIN=build`, same code path as `bin/bl`) gave the
per-step split below. Times are two independent runs.

| # | Step | Cost | Nature |
|---|------|------|--------|
| 0 | `bin/bl-stage-hosts` (escript VM, unconditional) | 0.45–0.67 s wall / 1.4–2.3 s CPU | extra VM, every invocation |
| 0b | `elixir -e` runtime-TAG probe (`bin/bl:65–70`, fires when the deps cache is non-empty — it is) | 0.53 s | extra VM, every invocation |
| 1 | `Bootstrap.install_hosts!` (launcher step 1) | 160–385 ms | verifies 66 seed beams (~0.51 MB) against sha256, re-reads/hashes the 66 destination beams, loads all 66 modules |
| 2 | launcher tier verdict: `manifest` + `current_compiler_key` + `boot_namespaces` + `AOT.beam_provenance` × 10 | 3–19 ms + 1 ms + 108–156 ms | tier-key computation (reads all `priv/boot/**/*.bl`, `priv/self/**/*.bl` + 7 pinned host sources ≈ 760 KB) and 10 beam loads |
| 3 | `start_app!` → `Application.ensure_all_started(:beam_lisp)` | 3.9–6.0 s | supervisor + `BeamLisp.init/0`: AOT loads of `rt`, `core`, `multi`, `sugar`, core seeding, data-reader eval |
| 4 | `ensure_loaded "vm.native"` + `build-all!` | 1.5–2.6 s (`build-all!` itself ≈ 0 ms) | every boot |
| 5 | `ensure_loaded "bl.cli"` (dispatch) | **144.0 s / 161.5 s** | **dominant** — see F1 |
| 6 | `bl.cli/run-argv` invoked | 11.1 s / 16.0 s | interpreted closure; see F1 |

Trace counts for the same boot (call_time, per function, this session):

| function | calls | exclusive time |
|---|---|---|
| `BeamLisp.AOT.ensure_loaded/1` | 144 | 0.60 s |
| `BeamLisp.AOT.ns_closure_hash/1` | 120 | **16.89 s** |
| `BeamLisp.AOT.beam_provenance/1` | 152 | 0.10 s |
| `BeamLisp.AOT.stale_by_provenance?/2` | 143 | 0.007 s |
| `BeamLisp.Ns.Reader.read_string/2` | 135 | 4.36 s |
| `BeamLisp.Ns.Body.Compiler.eval_form/2` | 3118 | 51.1 s |

Reading: **144 namespaces are loaded to print `bl version`**; **120 of them**
are declared stale and re-read from source; the drift gate spends **16.9 s**
deciding that; interpretation (`read_string` + `eval_form` + the untraced
interpreter/loader frames) is a major source-supported cost within the remaining load time. Init replay, hashing, dependency traversal, and other untraced work were not separately apportioned; the whole remainder is not attributed to interpretation.

Fixed per-invocation overhead — before any language work — is therefore
**≈ 1.0–1.2 s of shell-side process time** (step 0 + 0b), plus 0.16–0.39 s of
in-VM host staging, plus 3.9–6.0 s of application start: **≈ 5–7 s floor**,
as a measured subtotal, not a repaired-startup estimate. A coherent image still pays library validation/init replay and command work; their repaired latency is unmeasured.

---

## 2. Ranked findings

### F1 — A stale library tier silently degrades every boot to full source interpretation, with no cache write-back and no message

**Mechanism.** `Loader.ensure_loaded/1` (`priv/host/loader.bl:239`) →
`ensure_loaded_locked/1` (`:273`) asks `AOT.ensure_loaded/1`
(`priv/host/aot.bl:1088`). That function has exactly two outcomes: serve the
beam, or return `:no_module`; the loader then takes `ensure_loaded_source/1`
(`loader.bl:295`) → `do_load/3` (`:325`) → `Compiler.eval_string`. The source
path neither consults nor populates the AOT cache (the only `AOTCache/fetch`
caller in the tree is `priv/build/build.bl:162`), so **the same sources are
re-read and re-interpreted on the next boot, forever**, until someone runs
`bl build`.

The staleness verdict is `AOT.stale_by_provenance?/2` (`aot.bl:1238`), and for
the `:library` tier (`= priv/lib/**` + `priv/std/**`, 231 sources) it is:

```
beam_key == compiler_key   AND   beam_hash == live closure hash
```

**Observed state (this checkout).** `build/` holds 826 namespace beams:

| stamped `bl_compiler_key` | beams |
|---|---|
| *(none — Body/Init companions)* | 522 |
| `330d4b72…` (previous generation) | **273** |
| `ee85c8a3…` (the 21 build-driver namespaces, `priv/build/*`) | 21 |
| `2693fef9…` (current; the 10 boot-tier namespaces) | 10 |

The seed manifest's `compiler_key` is `2693fef9…`, so the 273 library beams can
never satisfy the gate — the key comparison fails before the source hash is even
consulted. The launcher's tier verdict only covers `Tiers.boot_namespaces/0`
(10 codegen namespaces, `priv/host/tiers.bl:132`), so it sees a healthy image
and does **not** rebuild.

**Evidence.** Trace: 144 `AOT.ensure_loaded` calls, 120 `ns_closure_hash`
calls (only taken on the `:library` branch), 135 `Reader.read_string` calls and
3118 `eval_form` calls — source interpretation at scale, on a tree with beams
for all of them. Deterministic proof: `bl.cli`'s beam carries key `330d4b72…`
≠ `2693fef9…`, and `src_hash` is non-nil (the sources exist), so
`stale_by_provenance?` returns `true` and `Loader` loads the source.

**Complexity / blast radius.** Per boot: O(loaded namespaces × interpreted
source bytes) with no memo across boots. 231 sources / 4.9 MB of `priv/lib` +
`priv/std` are exposed; a `bl version` reaches 144 of them. Measured cost of the
degraded boot: 144–161 s for one namespace load alone.

**Why it is silent.** The only diagnostic on this path is
`note_mixed_generation/0` (`aot.bl:1202`), which fires for
`:bootstrap_staging` namespaces (seed-staged names) and not for a library key
mismatch. `BEAM_LISP_AOT_STRICT=1` turns it into a raise, but nothing in the
default configuration says "this tree's library beams are a previous
generation".

**Repair directions** (in ascending cost):
1. Cheapest, highest value: in `stale_by_provenance?`, compare the **tier key
   first** (it is a memoized 0 ms read) and return stale *without* the live
   closure hash when it differs — this alone removes the 16.9 s gate term from
   the degraded case (F2) and makes the failure cheaper to reach.
2. Print the degradation once per VM (the `stale?` branch already has the
   message machinery in `note_mixed_generation`): "N namespaces in `build/` are
   from a previous toolchain; run `bl build`". Silence here is the actual
   defect: the user has no signal that the 110 s command is taking a degraded fallback path. The post-repair total latency is not measured.
3. Make the response self-healing rather than interpretive: on a stale verdict,
   emit the namespace into the ebin (the emitter is already on the code path —
   `AOT.emit_module`, `aot.bl:841`) or `AOTCache.store` it, so the next boot
   is fast. Needs a decision about write-ownership of `build/` (the build driver
   owns it today) — a store into the cache (not into `build/`) is the safer half.
4. Make the launcher's tier verdict or its rebuild cover the library tier, not
   just `boot_namespaces` — see F4 for the reason this is not free.

---

### F2 — The drift gate hashes the full live closure before asking the question that would answer it for free

**Mechanism.** `stale_by_provenance?` (`aot.bl:1238`) computes
`src_hash = ns_closure_hash(ns)` **first**, then compares
`beam_hash == src_hash and beam_key == compiler_key`. `beam_key` is stamped in
the beam and `compiler_key` is memoized in `:persistent_term`
(`aot_cache.bl:228`, measured 6–19 ms for the unmemoized `current_compiler_key`
form), so the cheap clause is available before the expensive one — and
`ns_closure_hash` (`aot.bl:1155`) walks the require closure by name, builds a
plan node per member, and re-plans/hashes per namespace
(`build-plan/key-for`, `build-plan.bl:322`).

**Evidence.** 120 calls / **16.89 s** in one boot — 12 % of the load budget
spent deciding staleness in a case whose answer was already determined by the
key comparison. The parse is memoized (a VM-wide content-keyed ETS table,
`build-plan.bl:300`, added by migration commit `21a28635` precisely to fix this
class of cost), but the closure walk, the plan traversal, the covered-edge map
and the per-line sha256 are **replayed per namespace**, not shared.

The repository records the pre-memo figure itself (`build-plan.bl` header,
commit `21a28635`): *"Measured on a ninety-namespace application: 71.7 s of a
72.5 s load was this gate; the beams' own `__bl_init__` replay was under a
second."* That historical measurement demonstrates a cost in the design; its exact durations remain host/workload-specific and are not this review's measurements.

**Complexity.** Σ over loaded namespaces of O(|closure| · log) — quadratic-ish
in application size, paid on **every** boot, healthy or not.

**Repair directions.** (a) Key-test first, closure hash only when the key
matches (avoids that work for compiler-incompatible artifacts; a healthy source-present image still hashes every requested library closure unless a separate sound memoization scheme skips it); (b) memoize `key-for` results per VM keyed
on the closure's content hashes — a namespace's key only changes when a member's
bytes change; (c) keep `:library` namespaces out of the gate for a release/drop
image where no source exists (`is_nil(src_hash) → false` already handles that).

---

### F3 — `bin/bl-stage-hosts` runs on **every** invocation (migration regression), duplicating work the launcher then repeats in-VM

**Mechanism.** `bin/bl:84` calls `bl-stage-hosts` unconditionally, before the
VM: one full escript VM (ERTS start), `file:consult` of the 15.8 KB
`manifest.term`, then for each of the 66 `hosts`
(`bin/bl-stage-hosts:135,241`): read seed beam + sha256, read destination beam +
sha256, write only on drift. Plus the `beam_lisp.app` verify.

**Before the migration this was cold-path-only.** `856d49c7^:bin/bl` called
`bl-stage-hosts` *inside* `if substrate_stale; then …` — i.e. only when
`lib/**/*.ex` was absent or newer than `Elixir.BeamLisp.Application.beam`. The
migration deleted the Elixir substrate (`lib/beam_lisp/{aot,aot_cache,bootstrap,
env,loader}.ex`) and with it `substrate_stale()`, and moved the call to the
unconditional path. Nothing else in the file's control flow gates it.

**Evidence.** `time bin/bl-stage-hosts priv/bootstrap/seed/manifest.term
priv/bootstrap/seed /tmp/probe-ebin`: **0.668 s** cold (empty dest) / **0.448 s**
warm. A bare `elixir -e ':ok'` on the same host is 0.539 s, and hashing the whole
4.19 MB seed is 0.20 s (python, sha256) — so the wall cost *is* the extra VM,
and the substantive work (≈1.0 MB read, 132 digests, 66 dest opens) is ~0.1–0.2 s
of it. Steady-state cost: one extra BEAM VM + one full verify pass per `bl`
command, including `bl test` and every daemon `bl` invocation.

**Also** the same rule is implemented a second time inside the VM:
`Bootstrap.install_hosts!/2` (`priv/host/bootstrap.bl:565`) re-reads the same
manifest, re-verifies the same 66 hosts against the same shas, copies with the
same verify-then-publish discipline, and loads them — measured 160–385 ms per
boot. Two implementations of one rule (`host_entries/3` in Erlang vs
`host_names/1` in BL) is a drift hazard as well as double work.

**Repair directions.** (a) Gate the escript on a cheap sentinel: it exists to
put `Elixir.BeamLisp.Launcher.beam` (and its host peers) on the code path before
`elixir -e 'BeamLisp.Launcher.main()'` can start. On a warm tree that is one
`File.exists?`/`sha` on the launcher beam; on a cold one the full pass. (b) Or
drop the escript entirely and let the launcher stage from a *pre-launcher*
trampoline… which is precisely what the escript is, so (a) is the honest fix.
(c) Or delete the in-VM duplicate, but only if the ordering constraint that
created it (host beams needed by `elixirc`, now gone) is genuinely gone.

Note the `bin/bl:65–70` runtime-TAG probe (0.53 s VM, fires because
`~/.cache/beam_lisp/ebin` is populated) is **not** migration-introduced — it is
byte-identical in `856d49c7^:bin/bl` — but it is the same class of cost and
belongs in the same fix: the tag can be computed from `erts`/Elixir version
files, or the cache directory can carry a `.runtime` stamp.

---

### F4 — The launcher's self-heal rebuild is a *partial* build that compacts the whole build log to the boot tier

**Mechanism.** `Launcher.rebuild_step!` (`priv/host/launcher.bl:309`) runs a
child VM whose `build_args` (`:267`) passes `build_sources` (`:254`) — the flat
`priv/boot/*.bl`, `priv/std/multi.bl`, `priv/boot/*.bl.md`, `priv/boot/*.bl.org`
— into `build/run`. `run` (`priv/build/build.bl:665`) treats `:sources` as the
**whole world**:

```
keep (set sources)
gone (vec (remove (fn [path] (contains? keep path)) (keys (:sources st0))))   ; :717
gone-beams (vec (map … ))                                                    ; :721
(doseq [mods gone-beams] (doseq [mod mods] (delete-beam out mod)))           ; :727
(blog/write! lpath (blog/facts-of st))                                       ; :731
(write-manifest mpath projection)                                            ; :732
```

So every source outside the boot tier is recorded as *dropped*: its beams are
deleted (when the log still knows them) and its freshness facts are removed from
the log and the manifest. `blog/fresh?` (`build-log.bl:316`) subsequently finds
no fact for them, so the next full `bl build` must rebuild them all — the
partial rebuild discards the incrementality of the 231-namespace library tier.

**Evidence.** `build/.beam_lisp/build.log` holds exactly **13 facts**: 1 run,
11 built (`10 × priv/boot/*.bl` + `priv/std/multi.bl`), 1 end — i.e. the log has
already been compacted to the launcher's source list, while **273 library beams
still sit in `build/` as orphans** (undocumented by the log and manifest, and
unusable by the drift gate because of F1). The current generation of the AOT
cache (`…/aot/2693fef9…`, 33 entries) contains only boot-tier namespaces —
consistent with a launcher rebuild at 05:06 having stored precisely those.

**Why it matters.** (i) The "self-limiting, one rebuild per boot-source edit"
claim in the launcher's docstring is true for the boot tier *and* is destructive
to the rest of the image: after a launcher rebuild, the tree is in exactly the
worst state for startup (library beams present but stale → F1). (ii) Any repair
that widens the launcher's rebuild to cover the library tier must also fix the
drop rule, or the first automatic rebuild deletes the library beams outright.

**Repair directions.** (a) `run` should take an explicit "this source set is
partial; do not drop" flag (the drop rule is a *full-build* invariant, not a
general one), or `Launcher` should call a driver entry that builds without
compaction. (b) Failing that, the launcher's rebuild should re-plan the full
tier set rather than the boot subset. Either way the drop rule and the partial
caller need to be reconciled explicitly — today they are silently incompatible.

---

### F5 — Fixed per-boot cost in the seeded-host install path

`Bootstrap.install_hosts!/2` runs on **every** boot as the launcher's first step
(`launcher.bl:410`) and is sha-authoritative for all 66 hosts: read seed (0.51 MB)
+ sha256, read destination (0.51 MB) + sha256, then `File/read!` the destination
a **third** time for the bytes it loads, `beam_lib:md5` them, and
`code:load_binary` all 66 (`bootstrap.bl:565–620`). Measured 160–385 ms, and it
eagerly loads 66 modules for verbs that need none of them (`bl version` needs
none of `Z3Port`, `WebSocket`, `Server`, …). `~`-cost, not dominant, but it is
pure per-invocation overhead, it duplicates F3, and `Socket`/`Z3Port`-class
leaves could be loaded on first use from the code path the escript already
populated.

Note `install!/1` (`bootstrap.bl:450`) — the *full* 93-beam verify + load — is
correctly confined to the rebuild child; it is not on the hot path.

---

### F6 — A toolchain-key rotation invalidates the entire build image *and* the entire AOT cache by address

`AOTCache.compiler_key/0` folds the Elixir version, OTP release, AOT backend,
a digest of the 7 codegen host sources, and the contents of **every**
`priv/boot/**/*.bl` + `priv/self/**/*.bl` (`aot_cache.bl:243,365,490`) — ≈760 KB
of the most actively edited sources in this repository. One edit to `rt.bl` or
`core.bl` rotates the key; the key is `(a)` the beam provenance stamp and `(b)`
half the AOT cache address (`entry_dir/2`, `aot_cache.bl:815`).

Consequence, measured: the only large cache generation present is
`efb24928…` (570 entries, 61 MB, 09-28); the current generation
`2693fef9…` holds 33 entries (boot tier only). Retained history is 2.1 GB across
8 generations (`cleanup_obsolete_generations`, `aot_cache.bl:627`, keeps 8 by
mtime, ≤4 deletions per sweep, throttled to 1/hour). So a key rotation costs
(a) recompilation of every library namespace on the next full build and (b) a
fresh cache generation — while the *runtime* response to the same rotation is the
unbounded interpretation of F1. The invalidation rule itself is defensible
(correctness first); the imbalance is that the cache exists but the runtime
never consults it.

---

### F7 — Loads are serialized through one process

Every namespace load is funnelled through `Loader.Server.run/1`
(`loader.bl:239–271`, `BeamLisp.Loader.Server` is a single supervised
GenServer), and `AOT.ensure_loaded` takes a `:global.trans` lock per module. On a
boot this makes 144 loads strictly sequential; in the daemon it serializes
concurrent requests behind one lock. Not the dominant term here, but it removes
the only parallelism the cold path could have had and makes the F1 cost
unavoidably cumulative.

---

### F8 — `Loader.Server`'s per-process source cache is dropped per call

`ns_closure_hash` installs a per-*call* `:bl_source_info_cache` and deletes it
in `finally` (`aot.bl:1161–1174`); with the VM-wide node memo this is now largely
redundant parse-wise, but the same closure is still re-walked and re-planned for
every namespace that requires it, 120 times in the measurement above. This is the
same defect as F2 seen from the loader side; the fix belongs with F2.

### F9 — The drift gate's own dependency (the build driver) is inside the invalidation domain it gates

A codegen edit rotates `compiler_key`, and `build_key` folds `compiler_key`
(`aot_cache.bl:271`), so the same edit also invalidates the 21 `priv/build/*`
namespaces — verified: the stale set stamped `ee85c8a3…` is exactly
`Build, Build-log, Build-plan, Claim, Deps, Deps-compile, Drop, Embed-asset,
Hex, Mix-shim, Ns-interface, Pristine, Provenance, Release, Seed, Selfbuild,
Source-graph, Store, Substrate, Z3-asset, App-resource`.

`ns_closure_hash` reaches the key computation *through* that driver:
`Loader.ensure_loaded "build-plan"` (`aot.bl:1166`) → `Env.fetch!
"build-plan" "key-for"`, and `build-plan` requires `source-graph` and
`ns-interface`. So the first `:library` namespace the gate vets after a key
rotation interprets **the gate's own tooling** (three driver namespaces) before
it can answer for anyone else — the invalidation domain and the measurement
apparatus are the same domain. F2's key-first short-circuit removes the gate's
need to load the driver at all in the rotated case, which is what makes it the
highest-leverage single change in this report.

### F10 — “Warm cache hydration” exists only on the build path, and it re-verifies and re-inits per source

`AOTCache.fetch/3` (`aot_cache.bl:531`) → `valid_entry/1` (`:581`) reads the entry
manifest and re-hashes **every** beam against its recorded digest before
accepting the entry; a hit is then hydrated by `run_init_modules/2` (`:783`),
which loads each module and runs its `__bl_init__/0`. So a cache hit is not a
free link: it is a per-source digest pass plus a per-source init replay, and
`link_beams/3` (`:836`) removes and re-links each beam. This is the only place
a cache entry is ever consumed — the launcher's cold rebuild pays it for the
boot tier (33 entries in the current generation), a full `bl build` pays it for
every fresh source.

It is not a boot-time cost today because the runtime load path never calls
`fetch` (F1). It becomes one the moment F1's repair direction 3 is taken, so the
repair should either address the entry by namespace (avoiding a re-hash of beams
the code server is about to load anyway) or reuse the digest already computed by
`valid_beam?` (`:604`).

---

## 3. Always vs. rebuild-only vs. degraded

| Path | When | Cost |
|---|---|---|
| `bin/bl-stage-hosts` | **always** (every `bl` invocation) | 0.45–0.67 s wall, extra VM, ~1 MB read + 132 sha256 |
| runtime-TAG `elixir -e` | **always** (deps cache non-empty) | 0.53 s wall, extra VM |
| `install_hosts!` | **always** (launcher step 1) | 0.16–0.39 s, 66 verifies + 66 loads |
| tier verdict (`provenance` × 10) | **always** | 0.11–0.16 s (+ 3–19 ms key computation) |
| `start_app!` (`init/0`: `rt`,`core`,`multi`,`sugar`, seed core) | **always** (once per VM) | 3.9–6.0 s |
| `vm.native build-all!` | **always** | 1.5–2.6 s |
| drift gate (`ns_closure_hash`) | **always**, once per `:library` namespace loaded | measured 16.9 s / 120 loads |
| source interpretation | **degraded only** — when the beam is absent or its key ≠ current | measured 144–161 s for `bl.cli` |
| launcher boot-tier child rebuild + re-exec | **rebuild-only** (static verdict false) | once per boot-tier key change; **compacts the log, drops other tiers' facts** (F4) |
| `bl build` / `bl seed` | explicit | re-emits library tier, repopulates the current cache generation |
| AOT cache fetch/store, generation GC | build-only | `store` per source + hourly-bounded sweep |

The launcher's rebuild loop is genuinely self-limiting (`BL_BOOT_REEXECED`
guard, `launcher.bl:335`); the *library* tier has no equivalent — it degrades
and stays degraded.

---

## 4. Migration-introduced vs. pre-existing (git-evidenced)

| Item | Verdict |
|---|---|
| F3 unconditional `bl-stage-hosts` | **introduced** by `856d49c7` (call moved out of the `substrate_stale` branch; `substrate_stale()` deleted with the Elixir half) |
| F1 library-driven source fallback | **pre-existing semantics, newly load-bearing** — `stale?/2`, `ns_closure_hash/1`, `stale_by_provenance?/2` are clause-for-clause ports of `856d49c7^:lib/beam_lisp/aot.ex:1551–1630`; what the migration changed is that the whole application is now in the AOT-stamped tier (the Elixir half used to be `elixirc`-compiled with no `__bl_provenance__`, which `beam_provenance → nil → not stale` served unconditionally) |
| F2 key-after-hash ordering | **pre-existing** (same order in `aot.ex:1588`) — but the migration's memo work (`21a28635`) has already removed the parse term, so the residual ordering cost is now the whole gate |
| F4 partial rebuild + log compaction | **pre-existing mechanism** (the pre-migration heredoc child passed the same partial source list; `build/run`'s drop rule is unchanged) — newly load-bearing because the launcher's rebuild is now the only automatic rebuild in the tree |
| F5 host install on every boot | **pre-existing port** (`bootstrap.ex` `install_hosts!/1`), host inventory grew to 66 |
| F6 key invalidation scope | **pre-existing design**, unchanged by the migration |
| F7/F8 serialized loads, per-call caches | **pre-existing** ports |
| F9 driver tier inside the gate's invalidation domain | **pre-existing design** (`build_key` folding `compiler_key` is unchanged); newly load-bearing because the gate is now on the CLI's critical path |
| F10 per-source cache hydration (`valid_entry` re-hash + `run_init_modules`) | **pre-existing** (same layout and checks in `aot_cache.ex`); build-path only today |
| F5b `vm.native build-all!` on every boot | **pre-existing** (ported from the heredoc twin) |

No finding in this report is attributable to the lazy-engine integration
(`13659b7d`) beyond beam sizes — the committed seed's `Elixir.BeamLisp.Ns.*`
beams grew 5.3 % in total (3 964 148 B at `856d49c7` → 4 172 728 B at HEAD; the
largest single moves are `Ns.Body.Rt` +10 % and `LazyMemo` +15 %, while
`LazySeq` shrank 9 %) — and none is attributable to the merge itself. Those
bytes are hashed and loaded on every boot (F3, F5), so the integration's effect
on the fixed costs is real but bounded at ~0.2 MB.

---

## 5. Reproduction appendix

All commands run from the repository root; nothing below writes to tracked
sources (`build/`, `priv/codegen.sources`, `~/.cache` are gitignored).

```sh
# 1. wall-clock boot, warm image
time bin/bl version                       # 110.3 s, 132.5 s observed (2 runs)

# 2. the unconditional pre-VM stage, cold and warm
rm -rf /tmp/probe-ebin
time bin/bl-stage-hosts priv/bootstrap/seed/manifest.term priv/bootstrap/seed /tmp/probe-ebin   # 0.668 s
time bin/bl-stage-hosts priv/bootstrap/seed/manifest.term priv/bootstrap/seed /tmp/probe-ebin   # 0.448 s
time elixir -e ':ok'                                                                            # 0.539 s baseline
time elixir -e 'IO.write("erts#{:erlang.system_info(:version)}-elixir#{System.version()}")'      # 0.532 s (bin/bl:65-70)

# 3. per-step split: drive Launcher.boot/2 with instrumented seams (the launcher's
#    own test door). Write /tmp/blprobe.exs:
#      defmodule P do
#        def t(l,f), do: (t0=System.monotonic_time(:millisecond); r=f.();
#                        IO.puts(:stderr,"PROBE\t#{l}\t#{System.monotonic_time(:millisecond)-t0}ms"); r)
#        def seams do
#          d=&BeamLisp.Launcher.default_seam/1
#          %{:install_hosts => fn e -> t("install_hosts", fn -> d.(:install_hosts).(e) end) end,
#            :manifest => fn -> t("manifest", fn -> d.(:manifest).() end) end,
#            :key_now => fn -> t("key_now", fn -> d.(:key_now).() end) end,
#            :provenance => fn m -> t("provenance", fn -> d.(:provenance).(m) end) end,
#            :start_app => fn -> t("start_app", fn -> d.(:start_app).() end) end,
#            :ensure_loaded => fn ns -> t("ensure_loaded #{ns}", fn -> d.(:ensure_loaded).(ns) end) end,
#            :fetch => d.(:fetch), :invoke => d.(:invoke), :get_env => d.(:get_env),
#            :code_path => d.(:code_path), :find_executable => d.(:find_executable),
#            :cmd => d.(:cmd), :load_app => d.(:load_app), :aot_boot => d.(:aot_boot),
#            :boot_namespaces => fn -> t("boot_namespaces", fn -> d.(:boot_namespaces).() end) end,
#            :stderr => fn m -> IO.puts(:stderr, m) end,
#            :halt => fn _ -> System.halt(0) end}
#        end
#      end
#      P.t("TOTAL", fn -> BeamLisp.Launcher.boot(System.argv(), P.seams()) end)
BL_EBIN=$PWD/build BL_ROOT=$PWD elixir $PA /tmp/blprobe.exs version

# 4. per-function counts: same driver, plus before the boot
#      :erlang.trace(:all, true, [:call]); :erlang.trace(:new, true, [:call])
#      for mfa <- [{BeamLisp.AOT,:ensure_loaded,1},{BeamLisp.AOT,:ns_closure_hash,1},
#                  {BeamLisp.AOT,:beam_provenance,1},{BeamLisp.AOT,:stale_by_provenance?,2},
#                  {BeamLisp.Ns.Reader,:read_string,2},{BeamLisp.Ns.Body.Compiler,:eval_form,2}] do
#        :erlang.trace_pattern(mfa, true, [:call_time]) end
#    and, at the end, printing :erlang.trace_info(mfa, :call_time) per MFA
#    (note: :halt must print the report BEFORE System.halt, or the numbers are lost)

# 5. the decisive state checks (cheap; no language boot)
elixir -e 'for f <- Path.wildcard("build/Elixir.BeamLisp.Ns*.beam") do
  {:ok,{_,[{:attributes,a}]}} = :beam_lib.chunks(String.to_charlist(f),[:attributes])
  IO.puts("#{Keyword.get(a,:bl_compiler_key)} #{f}") end' | sort | uniq -c | sort -rn
grep -c "" build/.beam_lisp/build.log                    # 13 facts: 1 run + 11 built + 1 end
grep "compiler_key" priv/bootstrap/seed/manifest.term    # 2693fef9…  (≠ 330d4b72… in build/)
```

Measured environment (for scale of the wall times): AMD Ryzen AI 7 350,
OTP 17.0.1 / Elixir 1.20.2, contended host (`user+sys` 1.5–2× wall on every
run above). Ratios and counts are the transferable part of these numbers.

---

## 6. Not verified / open questions

- **Healthy-image startup was not measured end-to-end.** Every namespace in the
  library tier is stale in this checkout, so I could not observe a boot that
  serves library beams from `build/`. The gate term (F2) is unconditional and
  measured; the *interpretation* term (F1) is what a current image would remove.
  Producing that state requires a full `bl build` (writes `build/`, ~231
  namespaces) — deliberately not run, since the task forbids source mutation and
  the working tree is shared.
- **The exact history that left 273 beams stamped `330d4b72…` while the log
  records only the boot tier** is reconstructed from two artifacts (the beams'
  stamps and the compacted log), not from a build transcript. The mechanism
  (F4) is read directly from the code; the sequence that produced this specific
  state is inferred.
- **The ~70 s of the 144 s `bl.cli` load not attributed** by the traced
  functions lives in the untraced interpreter/loader frames
  (`Loader.Server.run`, `Env`, `Ns.Rt.invoke`, `Compiler` internals). The
  ordering (gate ≪ interpretation) is established; the fine split inside
  interpretation is not.
- **`bl.cli/run-argv` taking 11–16 s** for `version` after a successful load is
  measured but not attributed; it is plausibly the first-call cost of an
  interpreted closure plus `register-store-paths!`, and it would not exist on a
  compiled beam.
- **Daemon (`bl serve`) startup** was out of scope; F7's serialization is a
  source-level observation and was not measured under concurrent load.
