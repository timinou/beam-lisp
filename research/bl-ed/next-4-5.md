# Next steps 4 and 5: Beam Lisp compiled in the browser, and split cells in bl-ed

This note designs steps 4 and 5 on top of the unified target (PLAN-163). Both
assume U1–U2 have landed: core.bl and rt.bl compile to JS over the host-leaf
ABI (168 leaves, measured). Each section says what exists today, what is
missing, and how to build it. Every "today" fact was measured or read on
2026-10-03.

---

## 4. Beam Lisp compiled in the browser (FUP-134)

### Goal
bl-ed (and any page) evaluates real Beam Lisp locally, with the same reader,
the same macro expander, the same compiler and the same core as the BEAM.
That means no server round trip, and `ed.lisp`'s stand-in interpreter goes.

### What the frontend is today
| file | defns | lines | role |
|---|---|---|---|
| priv/boot/reader.bl | 78 | 1,271 | text → reader nodes (spans, diagnostics) |
| priv/boot/compiler.bl | 202 | 4,375 | reader nodes → bl-ANF; macro expansion |
| priv/boot/anf.bl | 41 | 260 | ANF shape + validation |
| priv/boot/optimize.bl | 6 | 36 | checked optimizations |
| priv/boot/core.bl + rt.bl | 611 | 7,029 | core (compiled in PLAN-163 U2) |

All of it is Beam Lisp. The JS backend (priv/lib/js/emit.bl, 583 lines) is
Beam Lisp too. In principle the whole pipeline text → ANF → JS can run in a
browser.

### The pipeline in the browser
```
source text ──reader.bl──▶ nodes ──compiler.bl──▶ bl-ANF ──emit.bl──▶ JS text ──new Function──▶ live fns
                                       ▲                                             │
                                       └──────── macro expansion calls back ─────────┘
```
1. Build the frontend namespaces (reader, compiler, anf, js.emit) with
   `bl js build`, once, into a Worker bundle. They are ordinary namespaces on
   the unified target.
2. To evaluate a cell: read, compile to ANF, emit JS, instantiate it with
   `new Function` against the page's module table (`N_ns.d_name`), and
   publish each def into a live table.
3. Macro expansion needs the macro as a running function. On the BEAM it is
   `Rt/invoke macro-fn` (compiler.bl:4128). In the browser it is the same
   call: a `defmacro` compiled in step 2 is a JS function in the live table,
   and `macro-lookup` finds it there. *The JS target needs eval-at-compile-
   time, and it already has it*, because compiling to JS and instantiating IS
   eval.

### What blocks it, and the fix for each
| blocker | evidence | fix |
|---|---|---|
| core calls BEAM leaves | 168 leaves (research/bl-ed/core-host-leaves.txt) | PLAN-163 U1 |
| global name resolution goes through `Env/fetch!` with an ns→core fallback | PLAN-157 lesson 1 | a JS `Env` leaf set over the live table. The Env leaves are 7 of the 168 (fetch!, intern, lookup, put_key, put_link, caps_allowed?, doc_string) |
| ANF fresh names come from a process-global counter, so output depends on history | PLAN-157 W1.2 | thread the counter through the compile env. Required for byte-reproducible JS on both targets |
| the compiler references `Elixir.*` atoms as data (module names for remotes) | compiler.bl `slash-target` | atoms are interned Kw/Atom values in rt.mjs; module-name remotes become link-table lookups (js.build already does this at build time; dc781b46) |
| bundle size | bl-ed today: 11 modules, 332 KB unminified | frontend ≈ 14k lines of BL. Measure; lazy-load the compiler Worker only on first eval |
| speed of a cold compile | not measured | target: compiling a 20-line cell under 50 ms in the Worker. Measure after U2 |

### Safety
Browser eval is a capability, not a default. bl-ed's split cells (§5) only
run cells the analyzer proves pure in the browser, and the Worker has no DOM
or network: its only exits are its return value and messages. That is the
same capability rule the split client already applies (quoted-view-core.bl:
1-50), now enforced by placement instead of by refusing eval.

### Acceptance
- `bl js build bl.compiler.worker` produces a Worker bundle. In it,
  `(eval "(defmacro twice [x] `(do ~x ~x)) (twice (+ 1 2))")` returns 3.
- The BEAM↔JS differential gains a *compiler* corpus: the same source
  compiled on both targets yields equal ANF (after canonicalizing fresh
  names), not just equal results.
- bl-ed's `:` line uses the Worker. ed.lisp is deleted.

---

## 5. Split cells in bl-ed (PLAN-157 applied to a notebook)

### Goal
Each cell of a `.bl.org` runs where it is safe and fast. Pure, terminating
cells evaluate instantly in the browser on every edit (live results, no
round trip). Cells with effects (files, processes, network, time) evaluate on
the BEAM, as today. The author writes one file and never chooses.

### What exists today
- `system.analyze/analyze src` returns for every fn
  `{:footprint :terminates :returns :calls :edges :latent}` with an
  inter-procedural fixpoint (priv/lib/system/analyze.bl). W0 (this branch)
  added lazy forcing as an effect.
- The split placement gate (priv/lib/split) already turns those facts into
  "runs in the browser / refused, here is why" with named reasons, for 5 apps.
- bl-ed evaluates on the BEAM through `/api/eval` → `bl.doc` (`run-doc`,
  `write-results`), and both sides agree on cell ids through `bl.doc.spans`
  (step 1).

### Design
1. *Classify per cell, not per file.* A cell's code is its defs plus its
   top-level expression. Run `analyze` over the document's whole program (all
   cells, in order) and read each cell's own forms:
   - *local*: footprint `{}`, terminates, every callee local (transitively);
   - *beam*: anything else, with the analyzer's reason (`File/read!` at
     cell-3 line 4 → …), which is shown in the gutter.
   Reuse the split gate's reason format so the two features explain
   themselves the same way.
2. *Where the classification runs.* On the BEAM at first (the analyzer needs
   z3 for termination proofs). bl-ed asks `/api/place` on open and on every
   save, and caches the answer per cell content hash. When the frontend runs
   in the browser (§4), the analyzer can follow. Termination then needs a
   z3-free fallback (structural recursion only), with z3 cases deferred to
   the BEAM.
3. *Evaluation.*
   - local cell edited → recompile that cell in the Worker (§4), re-run it and
     every local cell downstream of it (the call graph is `:edges`), and paint
     results inline (`#+RESULTS:` shown live, written on save).
   - beam cell → unchanged path (`/api/eval`), plus its downstream local
     cells re-run when its value returns.
4. *Values across the line.* A local cell may use a beam cell's value. The
   value crosses as data on the existing wire (split's bounded codec,
   priv/lib/split/wire.bl). Functions and processes never cross; a local
   cell that needs one is classified *beam* (that is a refusal with a reason,
   not an error).
5. *Agreement.* A local result must equal what the BEAM would print. The
   differential is the guard (step 3: `bl test` runs it). Add a notebook mode:
   `bl js test --doc FILE` runs every local cell on both targets and diffs.

### Why this is the right shape
- One placement mechanism for apps and notebooks: PLAN-157's split gate.
- One evaluator per target: the self-hosted compiler.
- One cell model: `bl.doc.spans`.
- Nothing new is trusted. The analyzer decides, the differential checks.

### Order and gates
| step | needs | gate |
|---|---|---|
| 5a `/api/place` + gutter reasons | analyze + split reason format | every cell of docs/**/*.bl.org classified; reasons render |
| 5b local re-run on edit | §4 Worker | typing in a local cell updates its result in < 50 ms p95 on a 1k-line doc |
| 5c values across | split wire | a local cell reading a beam cell's map shows the right value; a fn value is refused with a reason |
| 5d notebook differential | step 3 | `bl js test --doc` green on docs/**/*.bl.org |

### Risks
- Analyzer precision: a cell refused as *beam* still works, just slower;
  imprecision costs speed, never correctness.
- Termination: z3-dependent proofs stay BEAM-side, so the browser fallback is
  conservative.
- Order: a local re-run must respect document order for redefinitions. Use
  the cell order from `bl.doc.spans` and re-run strictly downstream.
