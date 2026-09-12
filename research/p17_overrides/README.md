# P17 — `bl override`: vendoring and patching the shipped .bl

An experiment: how easy is it to override the beam-lisp the compiler ships?

Two mechanisms, one verb (`priv/std/bl/override.bl.md`):

- `bl override vendor NS` — copy a shipped namespace into this tree's
  `overrides/` to fix a bug in it. The tree's `overrides/` is a library root
  by convention (bound by `with-project`, ahead of `priv/`), so the copy
  shadows the shipped file with no flags.
- `bl override apply PATCH.bl` — run a patch PROGRAM: beam-lisp source
  exporting `(transform [ctx])`, handed the shipped source plus the codebase
  database (`:db`) to find its targets by structure instead of line numbers.
  The override lands only if verification passes: the compiler's diagnostics
  must be clean (logical, implicit), each overridden ns must load in an
  isolated env (logical, implicit), the shipped tests of touched namespaces
  must pass against the override (unit, implicit), and the patch's own tests
  must pass (unit, explicit). Any failure rolls every written file back.

## This demo

`patches/edn_tagged_readers.bl` teaches `clojure.edn` to honor
`:readers`/`:default` — custom tagged literals in EDN (`#spell/meta {:v 1}`),
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

## Findings

- Overrides of std/lib/compat-tier namespaces ride the load path for free;
  the verb adds discovery, verification, and rollback.
- `.spell`-as-`.bl` (the original target use case) is NOT reachable this way:
  which filenames count as source is decided on the Elixir floor
  (`BeamLisp.Loader/@doc_extensions`), before any search-path resolution.
  That seam must move into the boot sequence in beam-lisp first — see
  `!tasks/follow-ups/FUP-040-source-extensions-decided-in-boot-bl-not-elixir.org`.
- Boot-tier overrides would work for a `bl run`, but a drop's AOT image has
  the tiers compiled in; an override of a boot namespace asks for a rebuild.
  The std/compat runtime path is the sweet spot the machinery covers.
