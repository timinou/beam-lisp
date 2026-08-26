# Biscuit conformance corpus (vendored)

Source: https://github.com/eclipse-biscuit/biscuit-rust/tree/main/biscuit-auth/samples
Fetched: 2026-08-26. Block version 3, `biscuit-auth` 6.x line.

- `samples.json` — machine-readable manifest: root keypair, per-token block
  code + symbols, expected verification `result` per authorizer, revocation ids.
- `test0NN_*.bc` — 38 signed tokens (protobuf wire format), the adversarial
  conformance suite every Biscuit implementation validates against.

This is the oracle for `auth`'s Biscuit layer (PLAN-041 Wave 3). "Fully
compatible" is DEFINED as: decode every `.bc`, verify against the root key in
`samples.json`, and match the expected `result`. Do not edit these files; a
spec bump is a re-vendor, not a hand-patch.

Root keys (from samples.json):
- private: `99e87b0e9158531eeeb503ff15266e2b23c2a2507b138c9d1b1f2ab458df2d61`
- public:  `1055c750b1a1505937af1537c626ba3263995c33a64758aaafb1275b0312e284`
