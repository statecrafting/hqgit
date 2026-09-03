---
paths:
  - "crates/hqgit-trust/**"
  - "crates/hqgit-policy/**"
  - "crates/hqgit-policy-sdk/**"
  - "crates/hqgit-agent/**"
  - "crates/hqgit-eval/src/cache.rs"
  - "crates/hqgit-eval/src/provenance.rs"
---

# Trust invariants (constitution XI and XII)

You are touching the trust plane, the policy engine, the agent runtime, or
the action cache. Trust here is checkable, never decorative.

- Verification order is fixed (spec 064): signature, then issuer key valid
  at the attestation's HLC (rotation window, spec 060), then the keyless
  bundle when present (spec 063), then transparency inclusion when the
  repo policy requires it (spec 062), then the predicate claim shape (spec
  027). Never skip a stage, never report partial success as success, and
  never construct a `VerifiedAttestation` outside `verify.rs`.
- A key is valid only inside its rotation window; a signature made after
  revocation fails; a rotation fact must be signed by both the previous and
  the next key.
- The policy engine is deterministic (spec 065): wasmtime with no WASI
  clocks, random, network, or filesystem; fuel and memory limits; NaN
  canonicalization; same input bytes plus same module hash give the same
  output bytes. Every evaluation emits a `policy-eval` attestation (spec
  067); a merge gate consumes that attestation, never a live evaluation.
- Policies are pinned in the ledger (spec 068). There is no settings
  table; do not add one.
- Biscuit tokens (spec 100): attenuation only ever narrows; a holder can
  add caveats and never remove one; expiry and revocation are checked
  against the ledger fold, offline. An agent never authenticates as a
  human and a human session never presents as an agent (spec 102).
- The cache is a trust boundary (spec 071): a cache entry without a
  verified provenance attestation is a miss for any gating lookup; entries
  are immutable and coexist per executor; never overwrite.
- No self-approval path: an approval attestation whose issuer is the
  revision's submitter, or an agent approving its own delegation chain, is
  refused by the example policies and must stay refused.
- Seeds and private keys are never logged, `Debug`-printed, serialized, or
  written to the ledger.
- Ask the `trust-reviewer` agent to review before shipping.
