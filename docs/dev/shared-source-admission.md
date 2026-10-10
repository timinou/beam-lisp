# Content sharing between project realms

Ordinary namespaces remain realm local. A realm may explicitly share a finite,
immutable library with `:uses {"library.math" "sha256:..."}` and an explicit
`:path` in the corresponding project declaration. Use `vm.shared/hash-of` while
resolving that library's sources to calculate its declaration; do not hash only
the root file or invent a module label.

The key binds the transitive source closure, canonical compiler authority and
compiler key. Admission reads a bounded snapshot before evaluating source. The
loader verifies the actual bytes immediately before publication, resolves a
namespace's declared path without silently falling back elsewhere, and names
shared modules with the complete 64-digit digest. All non-tier dependencies must
be declared and independently admitted. Changing paths changes realm identity.

Sharing deliberately has a smaller source profile than ordinary BL: lexical
functions, arithmetic, and immutable literal definitions. Every free symbol must
belong to that source. Host calls, ambient captures, stateful initialization,
metadata, macros, namespace aliases, and shadow contexts are refused. Removing
`:uses` restores the full language with ordinary realm-local ownership. This is
an admission boundary, not a replacement compiler or scheduler.

Closing one realm does not retire another realm's shared consumer. Code sharing
does not share a world's mutable state, services, sockets or editor sessions.

Validation: shared admission 20 assertions, realm ownership 31, environment 136,
realm identity 16 and application packages 95 pass together (298 total). The
bootstrap seed was regenerated through `bl seed`; only the Loader beam and its
manifest changed. Fresh child-VM package replay passes with that floor.
