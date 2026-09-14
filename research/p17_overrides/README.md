# P17 — `bl override`: vendoring and patching the shipped .bl

An experiment: how easy is it to override the beam-lisp the compiler ships?

Two mechanisms, one verb (`priv/std/bl/override.bl.md`):

- `bl override vendor NS` — copy a shipped namespace into this tree's
  `overrides/` to fix a bug in it. The tree's `overrides/` is a library root
  by convention (bound for every command, ahead of `priv/`), so the copy
  shadows the shipped file with no flags.
- `bl override apply PATCH.bl` — run a patch PROGRAM: beam-lisp source
  exporting `(transform [ctx])`, handed the shipped sources plus a scoped
  codebase database (`:db-for`) to find its targets by structure instead of
  line numbers. The override lands only if verification passes: the
  compiler's diagnostics must be clean (logical, implicit), each overridden
  ns must load in an isolated env (logical, implicit), the shipped tests of
  touched namespaces must pass against the override (unit, implicit —
  checkout mode), and the patch's own tests must pass (unit, explicit). Any
  failure rolls every written file back and exits 1.

## This demo

`patches/edn_tagged_readers.bl` teaches `clojure.edn` to honor
`:readers`/`:default` — custom tagged literals in EDN (`#spell/meta{:v 1}`),
the BOUNDARY-cluster need. The shipped source documents the gap itself
("the tagged-literal :readers/:default are not consulted").

```sh
cd research/p17_overrides
bl override apply patches/edn_tagged_readers.bl   # writes overrides/clojure/edn.bl, verified
bl run main.bl                                     # the feature, live
bl override list                                   # what this tree shadows
bl override diff clojure.edn                       # the patch as a diff
bl override revert clojure.edn                     # back to shipped
```

## Findings (measured, this session)

- **Overrides of AOT-compiled namespaces work through the drift gate**: a
  shipped ns has a beam on the code path, but the gate hashes the source the
  search path resolves and falls to the source path on mismatch — so an
  override beats the shipped beam with no flags. Verified for a compat-tier
  ns, standalone and through the warm daemon.
- **beam-lisp seqs are uniformly lazy — side effects in a `map` must be
  forced.** The apply command's write step sat unrealized in a `let` binding
  used only by the rollback path: the files were written when rollback forced
  the seq, then immediately deleted. Verification ran against an absent file
  and (correctly!) failed. `u/to-list` at construction is the fix; any
  binding whose value is a seq of side effects needs a forcing call.
- **`.spell`-as-`.bl` is NOT reachable this way**: which filenames count as
  source is decided on the Elixir floor (`BeamLisp.Loader/@doc_extensions`),
  before any search-path resolution. That seam must move into the boot
  sequence in beam-lisp first — see
  `!tasks/follow-ups/FUP-040-source-extensions-decided-in-boot-bl-not-elixir.org`.
- **Full-corpus codebase-db indexing is currently broken** (cold: a walker
  macroexpansion crash; warm: zero `:fn/*` facts) — the patch context
  therefore scopes the db (`:db-for`) to the target namespaces. Filed as
  FUP-045.
- **Reader quirk the EDN feature inherits**: a tag joins its payload only
  when IMMEDIATELY adjacent (`#t{:a 1}`, not `#t {:a 1}`) — both readers,
  bug-for-bug parity. Clojure allows the whitespace.
- **beam-lisp has two symbol shapes**: the reader keeps `foo/bar` whole-name;
  `(symbol "foo/bar")` ns-splits (Clojure-consistent). They are unequal;
  match tags by printed name.

## Where this lives

Developed against HEAD in the `beam-lisp--override-spike` worktree because
the main checkout carried a concurrent session's in-flight daemon/dashboard
work. The verb, its cli wiring, the doc section, and this directory are
synced back to the main tree; reconcile when that work lands.
