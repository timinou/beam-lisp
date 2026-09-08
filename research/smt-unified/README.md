# smt-unified — the ONE SMT translator (over bl-ANF)

Prototype + differential proof for deleting the surface SMT translator.

- `anf-translate.bl` — the unified translator over bl-ANF (scalar arithmetic,
  and/or/=> reconstructed from the compiler's short-circuit scaffold, enum
  datatypes, collection-length, multi-clause defn→define-fun, and pure-helper
  inlining — the capability the surface walker never had).
- `parity.bl` — a z3 differential proof: for a 22-entry corpus it asserts
  `(not (= surface-form anf-form))` and checks it is **unsat** — i.e. the two
  denote the identical term. Run:
  `BEAM_LISP_PATH=research/smt-unified mix beam_lisp.run --path priv research/smt-unified/parity.bl`

## Measured result

**22/22 denote the same term** (scalar, and/or/=>, enum keyword/discriminant/
accessor, count/conj length, sign/floor-half define-fun). On that proof the
surface `translate` family was deleted and `system.smt` rewritten to read ANF;
`system` 187/421, `veritas` 55/130, `smt_parity` 2/14 — baseline match, 0
failures. Shipped as commit `39ea5f3`. See `docs/tools/07-one-smt-translator.bl.org`.
