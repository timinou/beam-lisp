# Cluster C — conservative descriptor lowering

## Current implementation

`Emit.compile_descriptor` runs one linear descriptor traversal before the existing backend. The new rewrite replaces `element(2, fun_info(F, :module))` with the descriptor module atom only when `F` is a literal own-module closure, or the exact self-application scaffold whose returned value is a literal closure. The index must be the integer `2` (`=:=`), not `2.0`.

Foreign functions, non-functions, unknown scaffold returns, quoted literal/pattern payloads and annotations retain their original behavior. Malformed descriptors pass through to the backend's existing validator, preserving the source of refusal.

There is **no new tuple/list rewrite**. The backend already folds the immutable-cons-to-tuple fixture; its unmodified and lowered emitted-byte results agree. Recognizing a reloadable `Core.list` call and erasing it would be unsound even when its supplied operands are known. That recognition and all helpers used only for it were removed, not retained as a fallback.

The early beta-reduction, dead-self-binding elimination and general Core helper rewrites were also removed. No new exports, caller opt-ins or second compiler path were introduced.

## Proof

`test/bl/pinned_kernel_lowering_test.bl` compiles real descriptors and inspects emitted BEAMs. Coverage includes:

- Own-module identity and retargeting to distinct probe module atoms.
- Strict integer index and the observable `2.0` BIF refusal.
- Foreign-function and non-function scaffold returns.
- Retained reloadable Core list/tuple calls and binding/shadowing parity.
- Effects and struct-key failure order; dynamic operands stay dynamic.
- Literal/annotation integrity and backend validation parity.
- Linear traversal via probe call counts rather than a predicted speedup.
- Tuple fixture parity showing an existing backend optimization, not attributing it to this pass.

The suite is included in `/tmp/bl-performance-final-loading-gates-158e8a77.log`: 83 tests / 438 assertions across the loading, kernel and analysis bundle, zero failures/errors. This bundle overlaps other gates; it is not a unique coverage total. The checkpoint generation is recorded in `performance-postfix-measurements.json`; the source-generated seed manifest remains authoritative.

## Remaining optimization boundaries

A type-selected collection kernel, recursive scaffold lifting or cached namespace dispatch needs its own proof. Current analysis is not blanket authorization: unknown kind/effects remain unknown; per-environment vars, late rebinding, hot reload and dynamic host capabilities must remain observable. No graph-lock reduction or destructive cursor advancement is part of this work.

The separate immutable plain-function invocation kernel, if accepted by its own tests, is documented in `performance-callable-kernel.md`; it does not turn namespace bindings into immutable compiler facts.
