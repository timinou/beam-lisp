# Publication coherence — why the isolated candidate boots cold but `main` `strict` finds 30 old namespace shims

Scope: read-only forensics on `build/`, `.local/foundation-publication-1790808237908102506/`,
`/tmp/bl-incremental-foundation-158e8a77/`, and the build/inventory sources; one
tooling fix in an allowed file (`!tasks/artifacts/incremental-foundation-publish.py`).
No image, seed, global build/test, `bin/bl`, or `priv/host/*` change was made.

Result in one line: **the staging build's source inventory (`BeamLisp.Tiers.sources`)
enumerates only `**/*.bl`, while the tree's declared build inventory (and the
loader's own extension set) also covers the literate `.bl.md` sources. The
candidate image therefore lacks 30 namespaces; publication into `build/` is
additive, so the previous generation's 30 namespace shims survive with an old
`__bl_provenance__` key, and strict AOT refuses the first of them (`bl.util`).**

---

## 1. The observed failure, reproduced

```console
$ BEAM_LISP_AOT_STRICT=1 bin/bl version
bl-stage-hosts: 66 pinned host beams staged into /home/user/code/undefine/beam-lisp/build (app resource beam_lisp.app)
** (RuntimeError) stale AOT beam for bl.util (BeamLisp.Ns.Bl.Util): compiled by toolchain 330d4b72994a,
   this VM runs d15fffd2d260. The source may be unchanged — the TOOLCHAIN moved, so the beam cannot be
   linked into this VM. Rebuild the image: `bl build`.
    priv/host/aot.bl:1552: BeamLisp.AOT.stale_by_provenance?/2
EXIT=1
```

`bl.util` is required by `bl.cli` (`[bl.util :as u]`), so **every** verb hits it;
`cmd-version` is simply the first. Non-strict mode never fails here — it notes the
mixed generation and repairs from source — which is exactly why the CLI benchmark
measured "green" until `strict-version` exited 1.

Provenance of the refusal, read straight out of the beam file (a namespace shim's
`__bl_provenance__/0` literal carries `{source_closure_hash, tier_key}`):

| beam | inode | size | `bl_compiler_key` in the beam | verdict |
|---|---|---|---|---|
| `build/Elixir.BeamLisp.Ns.Bl.Util.beam` | 409983894 | 63264 | `330d4b72…b6c9` | **old generation** |
| `build/Elixir.BeamLisp.Ns.Anf.beam` | 413669400 | 191344 | `d15fffd2…9b8` | current |
| `build/Elixir.BeamLisp.Ns.Build.beam` | 413670021 | — | `5eef0298…a05a` (driver key) | current |

`sha256(Elixir.BeamLisp.Ns.Bl.Util.beam) = 4d7f4e52675e6cd946c1343b49b3dd1a71789a327938ac4f6a3d253b3ac71f76`.

Whole-tree audit of `build/*.beam`, keyed on the generation key the live VM
reports (`d15fffd2…`, confirmed by `/tmp/bl-incremental-cold-158e8a77.log`):

```
905 beams in `build/`, classified by the key literal they carry:
  namespace shims (`Elixir.BeamLisp.Ns.<X>`, excluding `.Body.`/`.Init.`)
      new compiler key d15fffd2… : 257
      new driver key   5eef0298… :  21
      OLD compiler key 330d4b72… :  30      <-- the defect set
  non-shim beams carrying d15fffd2…    :  66   (the pinned hosts staged at 23:24)
  beams carrying no provenance at all  : 531   (`.Body.`/`.Init.`/companions/helpers)
```

The 30, exactly (all are `(ns …)` shims whose only source is a `.bl.md` file):

```
Bl.Ask Bl.Check Bl.Doctor Bl.Env Bl.Examples Bl.Fix Bl.Gateway Bl.Install Bl.Lint
Bl.Mcp Bl.Monitor Bl.Oracle Bl.Override Bl.Ports Bl.Repl Bl.Serve Bl.Test Bl.Util
Bl.Watch Data.Cache Data.Config Data.Registry Data.Tap Lsp.Rpc Lsp.Server
Mcp.Instructions Mcp.Skill Tooling.Incremental Tooling.Pulse Tooling.Trace
```

`build/` holds 80 files the image never had: those 30 shims, their 30
`Ns.Body.*` + 16 `Ns.Init.*` companions (a literate namespace with value defs
emits both), `Elixir.BeamLisp.Env.PerEnvDef.beam`, `.claim`, `.beam_lisp/`,
`erl_crash.dump`.
Their mtimes are 2026-09-29 14:09–14:15, i.e. the previous floor — untouched by
publication.

---

## 2. What each candidate cause actually is

| hypothesis | verdict | evidence |
|---|---|---|
| **source-inventory identity differs** | **CONFIRMED — root** | §3 |
| build skip/reuse policy unsound (generation-blind) | **REFUTED** | §4 |
| obsolete files remain | **CONFIRMED (mechanism, not root)** | §3, §5 |
| priority / name collision | **REFUTED** | §6 |
| test-concurrency mutation of build/cache | **REFUTED** | §7 |
| publication manifest issue | **CONFIRMED — separate defect** | §8 |

---

## 3. Root cause: two inventories, 279 vs 309

`BeamLisp.Tiers.sources/0` (`priv/host/tiers.bl`) is:

```clojure
(Enum/sort (Enum/flat_map (dirs root) (fn [d] (Path/wildcard (Path/join d "**/*.bl")))))
```

`dirs/1` = `library_names` = `("boot" "std" "lib" "compat" "build")` — `self/` is
deliberately excluded.

The loader's own answer to "what is a source" is
`BeamLisp.Loader.doc_extensions/0 = (".bl" ".bl.md" ".bl.org" ".clj" ".cljc")`
(`priv/host/loader.bl:107`, "the source extensions the loader **(and the build)**
recognise"), and the CLI expands `env.bl`'s `:build :paths` through
`bl.util/expand-targets` → `source-file?` → the same list. The build driver's own
contract header says the same: `(run {:sources [paths]  every source: .bl, .bl.md, .bl.org …})`.

Counted over the declared roots:

```
priv/{boot,std,lib,compat,build}   .bl 279   .bl.md 30   .bl.org 0   .clj/.cljc 0
  → declared (CLI) inventory                     309
Tiers.sources (same five roots, `**/*.bl` only; `self/` is excluded)     279
```

Direct evidence of what each build saw, from the two logs' own facts:

```console
$ grep -c 'bl\.md' build/build.log
0
$ grep -o '^\[:build/built "[^"]*"' build/build.log | wc -l          # candidate (staged)
279
$ grep -c 'bl\.md' .local/foundation-publication-1790808237908102506/build/build.log
30
$ grep -o '^\[:build/built "[^"]*"' …/build.log | wc -l              # previous floor (CLI)
305
```

```console
# candidate build log (/tmp/bl-current-image-build-158e8a77.log)
STAGE-COMPILER-DONE
beam-lisp AOT: building 279 source(s)
  /tmp/bl-incremental-foundation-158e8a77/lib/beam_lisp-0.1.0/priv/boot/rt.bl
  …
… :built 279, :ex-built nil            # 0 errors, 0 cached, no [:build/dropped] fact
```

`bl.util`'s own fact exists in the **old** log and in no other:

```clojure
[:build/built "/home/user/…/priv/std/bl/util.bl.md"
  "fbe60e89ca8d29b4926e7637d2fff07f58d156b0b731cfd8af8a4097b35d610e"   ; closure hash
  "330d4b72994a561d3e75b1f20aaa0a36f955860138f4641abd5ac1dae0a3b6c9"]  ; tier key at the time
```

The candidate image (832 entries) contains **no** `bl.util` beam at all — checked
by name diff (`cand \ main = {.bootstrap_staging.term}`, `main \ cand = 80 files`)
and by the key audit (0 of the image's 828 beams carry the old `330d4b72…` key;
323 carry `d15fffd2…`, the rest are Body/Init/companion beams and the 21 driver
shims stamped `5eef0298…`).

**Therefore the cold candidate "succeeded" for two reasons that both hide the
defect**: (a) `bl version` only initialises 21 namespaces
(`/tmp/bl-incremental-cold-158e8a77.log`:
`bl.util store provenance reader-node deps-compile anf source-graph sugar reader rt
multi core ns-interface lower vm.client diag compiler vm.native build-plan bl.env
bl.cli`), and (b) `bl.util` is *served from source* because no beam exists —
the loader interprets `priv/std/bl/util.bl.md`, which is most of the 14.13 s
cold boot. Nothing in that path ever asks whether the image is complete.

**And publication turns "incomplete image" into "strict failure"**, because it is
additive by design (`!tasks/artifacts/incremental-foundation-publish.py`: it
iterates the image's files and `os.replace`s each; a destination file the image
does not contain is never touched). `build/` is therefore
`previous floor ∪ candidate image`, a hybrid of two generations.

---

## 4. The reuse policy is sound — measured, not assumed

`build-log/fresh?/5` requires **both** keys and the beams on disk:

```clojure
(and (some? (:key e)) (= key (:key e)) (= tier (:tier e))
     (every? (fn [mod] (File/exists? (beam-path out mod))) (:modules e)))
```

* `tier` = `AOTCache/key_for_source` = the generation key (`compiler_key`) or the
  driver key (`build_key`) — so a toolchain move alone invalidates every source.
  Observed: `priv/boot/anf.bl` was **rebuilt** by the candidate build although its
  plan/closure key was byte-identical (`6106e4f7…`) — only its tier key moved
  `330d4b72… → d15fffd2…`.
* `key` = the plan's interface key, and `build-plan/key-of` folds **the node's own
  content hash** (`x ":" (:hash xn)`) for the root — so a body edit to a source
  always rebuilds that source; interface keying can only *remove* rebuilds it has
  proved unnecessary for other closure members.
* New driver sources are keyed by `build_key = hash(compiler_key ++ all
  priv/build/**.bl contents)`, so an edit anywhere in the driver rotates it.

No skip/reuse defect exists. The 30 old shims were never *skipped* — they were
never in the inventory, so no run ever considered them.

Independent corroboration that the 21 driver-tier sources were also written by
this staged run with the **wrong tier label in the log** is in §8; it does not
affect freshness (see §8) but is a real inconsistency.

---

## 5. "Obsolete files remain" — mechanism confirmed, but not by pruning

`build.run`:

```clojure
gone (if prune? (vec (remove (fn [path] (contains? keep path)) (keys (:sources st0)))) [])
gone-beams (vec (map (fn [path] (get-in st0 [:sources path :modules] [])) gone))
…
(doseq [mods gone-beams] (doseq [mod] (delete-beam out mod)))
```

* `:scope :scoped` prunes nothing. Verified in behaviour: the launcher's boot-tier
  self-heal passes `:scope :scoped` with a boot-only list
  (`priv/host/launcher.bl:build_args`), and its log `build/.beam_lisp/build.log`
  holds 10 sources, **0 `[:build/dropped]` facts**, and did not remove a library
  beam — the whole tree keeps using the shared ebin.
* `:scope :full` prunes only paths the **log records**. 0 `[:build/dropped]` facts
  appear in either log. The 30 literate shims are not recorded in any log, so no
  full run can prune them; only a run whose inventory *contains* them (the CLI)
  can overwrite them.

So "obsolete files remain" is true, but the obsolete files are *foreign*, not
*deleted-then-orphaned*. What makes them harmless in a normal tree is that a full
run rebuilds them (`util.bl.md` is in the CLI inventory); what makes them fatal
here is that the inventory that built the image did not.

---

## 6. Priority / name collision — refuted

Parsed `(ns …)` out of all 309 declared sources: 307 namespaces, **0 duplicates**
(the two files without a first `(ns …)` form are `priv/std/codebase.bl` and
`priv/std/test.bl`). The near-collisions are distinct namespaces on distinct
paths (`bl.trace` vs `tooling.trace`, `bl.monitor` vs `reload.monitor`,
`bl.test` vs `std/test.bl`) and `build-plan/plan` indexes by namespace, so a
collision would silently drop a file — there is none to drop.

---

## 7. Concurrency — refuted, with a clean separation of phases

Per-file mtime histogram of `build/*.beam` (911 entries):

```
09-26 16:03   1     09-30 21:30…21:47   830   (candidate image, mtimes preserved by copy2)
09-29 14:09…14:15  77  09-30 23:24        66   (pinned hosts staged into the image)
```

Nothing in `build/` was written after 23:24 (`find build -newermt '-10 minutes'`
→ empty; 23:43–23:44 is the publication, whose copies *preserve* the image's
mtimes). The CLI benchmark (23:48) and the 131-test gate run (23:48) therefore did
**not** mutate the image, and neither did the strict reproduction above — the
inode+mtime of `build/Elixir.BeamLisp.Ns.Bl.Util.beam`, `build/compile.beam_lisp`,
`build/build.log` are unchanged before/after it (`NO-INODE-MTIME-CHANGE`).

Timeline (all four writers identified):

```
Sep 29 14:09–14:15  `bl build` (CLI, 305 sources incl. 30 literate)      key 330d4b72
Sep 30 18:52        launcher boot-tier self-heal, :scope :scoped,
                    into build/.beam_lisp/ (10 sources)                  key 9782bba4
Sep 30 21:30–21:47  staged candidate build (Tiers.sources, 279 sources)  key d15fffd2
Sep 30 23:04        candidate seed written (93 modules)
Sep 30 23:24        `bl-stage-hosts` stages 66 pinned hosts into the image
Sep 30 23:43–23:44  publication: 831 image files copied into build/ (818 backed up)
```

The published gate failures (`namespace not found: demandintegration3971consumer`,
`… searched: ["/tmp/beam_lisp_drift_fixture/src", …]`) are a **different** defect:
the fixture root is gone/foreign for those two suites. They are not caused by the
30 shims (those two suites never load a `bl.*` namespace) and are out of this
ticket's scope.

---

## 8. Second defect (confirmed): the published build STATE belongs to another tree

`build/build.log` and `build/compile.beam_lisp` were copied from the image
verbatim, and the image was built over the **staging** tree, so its keys are
absolute staging paths:

```clojure
[:build/built "/tmp/bl-incremental-foundation-158e8a77/lib/beam_lisp-0.1.0/priv/boot/anf.bl" …]
manifest keys: "/tmp/bl-incremental-foundation-158e8a77/lib/beam_lisp-0.1.0/priv/build/embed-asset.bl" …
manifest entries: 279; `.bl.md` entries: 0
```

Two consequences, one of them destructive:

1. **Foreign tier labels.** The staged run passed `:root` = the *checkout* root
   (`!tasks/artifacts/incremental-foundation-stage.bl`), but `AOTCache.key_for_source/2`
   interprets its `root` argument as the **priv** root (`Tiers/build_source?` →
   `Path/join root "build"`). `<checkout>/build` is the *output* directory, so
   `build_source?` answered false for every source and the 21 driver-tier sources
   were logged under the **compiler** key instead of the driver key:
   `build.bl → "d15fffd2d260…"`, where the correct value (as the previous read
   floor wrote, and as the seed phase reports) is a driver key
   (`5eef02985e0af44f4a72d621577fe3cc5fbcfadb1b28905181f1cb956b42a05a`).
   The **beams** are stamped correctly (`key_for_ns` → `key_for_tier :build`) —
   so the log/manifest disagree with the beams. Effect: harmless for staleness
   (`fresh?` compares like with like inside one configuration; the plan key
   carries each source's own content), but a correct-root run rebuilds all 21
   needlessly, and the manifest Mix reads carries the wrong tier for them.
   `:root` is **undocumented** in `build.run`'s contract header and means two
   different things (`priv` for `source-key`, checkout for `build-native`).

2. **A full `bl build` on `build/` as published would DELETE the beams it just
   built.** With the foreign log in place, `keep` = the 309 real paths,
   `keys(:sources st0)` = 279 staging paths ∪ 309 real paths, so `gone` = the 279
   staging paths; their `:modules` are the *same module names* the new sources
   just produced under the real paths, and the deletion loop runs **after** the
   waves. Net effect of one `bl build`: 309 sources compiled, then 279 namespace
   shims + their body/init companions deleted → an unusable image until a second
   `bl build`. (This is `build.run`'s only real weakness in the cleanup path: it
   deletes a beam the current run just built, because deletion is keyed on
   recorded module names, not on "is this module still produced by some source in
   this run".)

`compile.beam_lisp`/`build.log` are *build state of the tree they were built in*;
copying them across trees is the publication manifest issue.

---

## 9. Hardlinks — the publication is inode-safe (validated)

* `publish.py` never writes through an existing inode: it `shutil.copy2`s to
  `…publication-<pid>` and then `os.replace(tmp, out)` — a **new inode** for the
  destination. A destination beam that is a hardlink to an authoritative AOT-cache
  entry therefore keeps the link count of the cache entry and cannot be modified.
* `AOT.write_beam` (`priv/host/aot.bl`) and `install-artifact!`
  (`priv/build/build.bl`) use the same tmp+rename rule.
* Measured: `build/*.beam` all have `st_nlink == 1`; the AOT cache holds 1925
  beams (44 with `nlink > 1`, i.e. genuinely linked into a repair/link dir), and
  the **inode overlap between `build/` and `~/.cache/beam_lisp/aot` is 0**.
* Dry run of the publisher is read-only and prints the expected shape:
  `{'build_link': …, 'lib_target': …/build, 'image_files': 831, 'seed_files': 95}`.

---

## 10. Minimal fixes

### F1 — the root (NOT in an allowed file: `priv/host/tiers.bl`, seed-pinned)

```diff
 (defn sources
-  "Every `.bl` source under the library tiers, sorted."
+  "Every SOURCE under the library tiers, sorted: `.bl`, and the literate
+   `.bl.md` / `.bl.org` the loader also serves (`Loader/doc_extensions/0`).
+   This set must equal what the loader can resolve. If it does not, an image
+   built from it silently lacks a namespace (the loader interprets it from
+   source on every boot) AND — because publication is additive — the previous
+   generation's beam for that namespace survives in `build/`, which strict AOT
+   refuses."
   ([] (sources (priv_root)))
   ([root]
    (Enum/sort
-     (Enum/flat_map (dirs root) (fn [d] (Path/wildcard (Path/join d "**/*.bl")))))))
+     (Enum/flat_map (dirs root)
+       (fn [d]
+         (Enum/flat_map (fn [ext] (Path/wildcard (Path/join d (str "**/*." ext))))
+                        ;; spelled as data: this runs before the language, so it
+                        ;; cannot ask the loader for its own extension list
+                        '("bl" "bl.md" "bl.org")))))))
```

Why this file and not the caller: `build.run`'s contract already defines a source
as `.bl/.bl.md/.bl.org`, the CLI already expands to that set, and the only
build-tier callers (`selfbuild/stage-sources!`, the staged foundation flow) cannot
reach `bl.util/expand-targets` (boot/build-barrier). `Tiers` is the one
preboot-safe home for the inventory, so making it agree with the loader is the
one-implementation fix.

**Consequences the fix forces** (all mandatory, in this order):

1. `priv/host/tiers.bl` is a **codegen source**, so editing it rotates
   `compiler_key` for the whole tree: every beam becomes stale. A full rebuild is
   required, not optional.
2. `Tiers` is also a **pinned host beam committed in the floor**
   (`priv/bootstrap/seed/Elixir.BeamLisp.Tiers.beam`) — the seed must be
   regenerated (`bl seed`) or the floor keeps the old glob.
3. Regression to add with the fix (test file, so it is allowed):
   `test/bl/tiers_test.bl` (or `build_test.bl`) —
   `(= (count (filter #(endswith? % ".bl.md") (BeamLisp.Tiers/sources)))
       (count (Path/wildcard (Path/join (BeamLisp.Tiers/priv_root) "**/*.bl.md"))))`
   and, stronger, `(every? (fn [p] (some #(endswith? p %) ["bl.md" "bl.org"])
                                  (BeamLisp.Tiers/sources)) ...)` is *not* the
   claim — the claim is **set equality with the loader's served set**:
   `(= (set (BeamLisp.Tiers/sources)) (set (filter loader-source? (all files under the tiers))))`
   with `loader-source?` = `ends-with?` any of `Loader/doc_extensions`.
   That test is red on the current tree and green after the patch.

### F2 — the publication-state defect (APPLIED: `!tasks/artifacts/incremental-foundation-publish.py`)

The publisher no longer copies the image's `build.log` / `compile.beam_lisp` over
the destination's: those are the *build state of the tree that was built*, keyed
by its absolute paths. The destination keeps its own state (or none), which means
the next `bl build` reconciles honestly — every source stale against the image's
key, `gone` = recorded-real-paths minus the new inventory = ∅, and no beam is
deleted. Also avoids the destructive first `bl build` of §8.2.

### F3 — proposed hardening (NOT applied; rotates `build_key` mid-verification)

In `priv/build/build.bl::run`, never delete a beam this run just built:

```clojure
built-mods (set (mapcat (fn [path] (blog/module-names (get-in st0 [:sources path :modules] []))) keep))
…
(doseq [mods gone-beams]
  (doseq [mod (blog/module-names mods)]
    (when-not (contains? built-mods mod) (delete-beam out mod))))
```

Plus make `:root` explicit in `run`'s contract header and split the two meanings
(priv root for `source-key`, checkout root for `build-native`/`:ex`) — or drop the
option from `source-key` and always use `AOTCache/key_for_source/1`.

---

## 11. Precise recovery (commands only; none of these were run by this worker)

Choose one path. **Both start by removing the foreign build state — running
`bl build` before that deletes the beams it just built (§8.2).**

```sh
# 0. keep the artifacts, then drop the foreign state
mkdir -p /tmp/bl-foreign-build-state
cp build/build.log build/compile.beam_lisp /tmp/bl-foreign-build-state/
rm -f build/build.log build/compile.beam_lisp
# --- R1: land the root fix first (correct end state) --------------------
#   apply the F1 patch to priv/host/tiers.bl, then:
bin/bl build            # 309 sources (279 .bl + 30 .bl.md), all rebuilt under the new key
bin/bl seed             # re-commit the floor (pinned Tiers beam carries the fix)
bin/bl seed --check     # must report the floor current
#   then re-stage the candidate exactly as before and re-verify cold:
#   BL_STAGE_PHASE=hosts|build|seed on a fresh isolated ebin, then incremental-foundation-cold.sh
BEAM_LISP_AOT_STRICT=1 bin/bl version     # must exit 0

# --- R2: immediate unblock without touching the host/seed ---------------
#   (fixes main's strict failure now; the next Tiers.sources-driven image
#    will still be incomplete)
bin/bl build            # CLI inventory already includes .bl.md → the 30 shims are rebuilt
BEAM_LISP_AOT_STRICT=1 bin/bl version     # must exit 0; expect 0 old-key shims
```

Post-conditions to check (either path):

```sh
# 0 beams carry a generation other than the live one
python3 - <<'EOF'
import os, re
# the OLD generation key (read it out of a failing `BEAM_LISP_AOT_STRICT=1 bin/bl version`)
old = "330d4b72994a561d3e75b1f20aaa0a36f955860138f4641abd5ac1dae0a3b6c9"
bad = [n for n in os.listdir("build") if n.endswith(".beam") and
       old in {x.decode() for x in re.findall(rb"[0-9a-f]{64}", open("build/"+n, "rb").read())}]
print("old-generation shims:", len(bad))     # must be 0
EOF
grep -c 'bl\.md' build/build.log                    # must be 30 in R1, 30 in R2
grep -c '^\[:build/dropped' build/build.log         # must be 0
find build -maxdepth 1 -name '*.beam' | wc -l       # ≥ 905; no beam deleted after a build
```

Expected after R1: `bl build` reports `building 309 source(s)` (the CLI already did
305 before 4 sources were added), `build.log` records 30 `.bl.md` facts, and a
cold boot of the re-staged candidate initialises 21 namespaces **without**
interpreting `bl.util` from source.

---

## 12. Honest limits of this analysis

* Everything above is read from source, on-disk bytes, logs, and two bounded
  read-only processes (`BEAM_LISP_AOT_STRICT=1 bin/bl version` — the failing
  command itself; the publisher's dry run). **No build, seed, test or
  publication was run by this worker**, so "the fix turns strict green" is a
  prediction from the code, not an observation.
* `build/` is a hybrid tree and is *not* the candidate image; the 30 old shims
  are previous-generation evidence, not a build output of this tree.
* The staged run's `:root` mis-tiering (§8.1) is reproduced from the log's own
  tier values and the two call sites; it was not re-run end-to-end here.
* The published gate suite's 9 failures / 17 errors were not triaged beyond
  separating them from this defect (fixture root, not inventory).
