---
id: "064-attestation-verification"
title: "Attestation verification: the fixed pipeline from signature to verified set"
status: approved
kind: "kernel"
domain: "l4-trust"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 4
depends_on:
  - "060-identity-and-key-rotation"
  - "062-transparency-log"
  - "027-attestation-primitive"
establishes:
  - "crates/hqgit-trust/src/verify.rs"
  - "crates/hqgit-trust/src/verified.rs"
  - "crates/hqgit-trust/src/verify_policy.rs"
  - "crates/hqgit-trust/tests/verify.rs"
  - "crates/hqgit-trust/testdata/verify/"
extends:
  - { spec: "060-identity-and-key-rotation", unit: "crates/hqgit-trust/src/lib.rs", nature: additive }
  # hqgit-domain joins the trust crate's dependencies (the Attestation type).
  - { spec: "060-identity-and-key-rotation", unit: "crates/hqgit-trust/Cargo.toml", nature: additive }
summary: >
  The one path by which an attestation becomes evidence. Spec 027 checks a
  signature against a verifier it is handed; this spec fixes the whole
  chain in one order: signature, issuer key valid at the attestation's
  clock (060), keyless bundle when present (063), transparency-log
  inclusion when the verify policy requires it (062), and claim shape
  against the predicate registry (027). The output is VerifiedAttestation,
  a type nothing outside this module can construct, gathered into a
  VerifiedAttestationSet that carries a per-item verdict and never hides a
  failure inside a partial success. That set is the only shape the policy
  engine (065), the action cache (071), quarantine promotion (094), and the
  projections (081) accept: verification happens here or it did not happen.
---

# 064: Attestation verification

## 1. Purpose

Constitution XI: trust is checkable, not decorative. Spec 027 made every
form of evidence one primitive; spec 060 made identity a keypair with a
rotation chain; spec 062 made issuance publicly logged; spec 063 made
short-lived keys usable. Each of those verifies one thing. A consumer that
composes them by hand will get the order wrong, skip a stage under load, or
accept a failed stage as a warning. This spec removes that freedom: there is
one pipeline, its stages run in one order, each stage's failure is a named
variant, and the result is a type that proves the pipeline ran. Thesis §4.5
and design doc §1.1 point 5 describe the property; this spec is where it
becomes unavoidable.

## 2. Territory

`crates/hqgit-trust/src/verify.rs` (the pipeline, `verify_one`,
`verify_set`), `src/verified.rs` (`VerifiedAttestation`,
`VerifiedAttestationSet`, `Verdict`, the sealed constructor, the test
builders), `src/verify_policy.rs` (`VerifyPolicy`, `TrustAnchors`), the
`tests/verify.rs` file, and fixtures under `testdata/verify/`. Additively:
the crate's `lib.rs` re-exports and its `Cargo.toml` (the `hqgit-domain`
dependency, which keeps the dependency direction of thesis §5:
`hqgit-trust` sits above `hqgit-domain`, never the reverse). Policy
evaluation (065) consumes the set; nothing here evaluates policy.

## 3. Behavior

- **B-1 (`VerifyPolicy`).** `VerifyPolicy { require_tlog: bool,
  require_keyless_for: BTreeSet<PrincipalKind>, max_clock_skew_ms: u64,
  registry: PredicateRegistry }` and `TrustAnchors { identities:
  IdentityView, roots: Option<TrustRoots>, checkpoints: Vec<Checkpoint> }`.
  Both are plain data supplied by the caller; the pipeline reads no clock,
  no environment, and no network. `VerifyPolicy::strict()` sets
  `require_tlog = true` and requires keyless bundles for `Human`
  principals; `VerifyPolicy::offline()` sets `require_tlog = false` (the
  wave 1 CLI posture, 034).
- **B-2 (the pipeline, in order).** `verify_one(att: &Attestation, claim:
  &Value, policy: &VerifyPolicy, anchors: &TrustAnchors, tlog: Option<&dyn
  TlogClient>) -> Verdict` runs exactly these stages and stops at the first
  failure:
  1. **Structure.** `att.subject`, `att.claim`, and `att.issuer_key` are
     well-formed; `att.at` is not more than `max_clock_skew_ms` ahead of the
     newest checkpoint in `anchors` when one exists. Failure:
     `VerifyFailure::Malformed(String)`.
  2. **Signature.** `027::verify_signature` with an `Ed25519Verifier` for
     `att.issuer_key`, taking the public key from `anchors.identities`
     (060) or, when the attestation carries a keyless bundle in `extra`,
     from the bundle's leaf certificate. Failure:
     `VerifyFailure::BadSignature`.
  3. **Issuer.** `anchors.identities.key_valid_at(&att.issuer_key,
     &att.at)` (060 B-5) is `Valid` and the identity that owns the key is
     `att.issuer`. Failure: `VerifyFailure::KeyNotValidAt { key, at,
     reason }` or `VerifyFailure::IssuerMismatch`.
  4. **Bundle.** When `extra` carries a `SignatureBundle` (063 B-6),
     `063::verify_bundle` against `anchors.roots` must pass, and the
     certificate's OIDC subject must bind to `att.issuer` through an
     `identity.binding_added` fact (061). When the policy requires keyless
     for the issuer's kind and no bundle is present:
     `VerifyFailure::BundleRequired`. Failure otherwise:
     `VerifyFailure::BadBundle(String)`.
  5. **Transparency.** When `policy.require_tlog` is true, `tlog` MUST be
     `Some`, and `tlog.inclusion(&leaf_hash(LogEntry::Attestation(id)))`
     (062 B-6) must return a proof that verifies against a checkpoint in
     `anchors.checkpoints` or against `tlog.latest_checkpoint()` after a
     consistency proof from a trusted one. Failure:
     `VerifyFailure::NotLogged` or `VerifyFailure::LogUntrusted`.
  6. **Claim.** `027::verify_claim(att, claim, &policy.registry)`. An
     unknown predicate passes this stage with `claim_checked: false`
     recorded on the verified item (027 B-5 preserves unknown predicates);
     a known predicate whose claim fails validation is
     `VerifyFailure::BadClaim(String)`.
  A stage never runs before every earlier stage passed; the order is a
  frozen constant `STAGES: [&str; 6]` that tests assert against.
- **B-3 (`Verdict`).** `enum Verdict { Ok(VerifiedAttestation),
  Failed { id: AttestationId, stage: &'static str, failure: VerifyFailure
  } }`. `VerifyFailure` is a closed enum with the variants named in B-2
  plus `Erased` (the claim object is a tombstone, 020) and `Unavailable`
  (the claim object is missing from the store). A verdict is never a
  warning: it is `Ok` or it names the stage.
- **B-4 (`VerifiedAttestation`).** A struct holding the attestation, its
  id, the decoded claim, `claim_checked: bool`, `logged: bool`, `keyless:
  bool`, and `verified_under: VerifyPolicyDigest` (the hash of the policy
  and anchors used, so a consumer can tell a strict verification from an
  offline one). Its only constructor is private to `verify.rs`; the type is
  `Clone` and serde-serializable so it can be journaled, but
  deserialization yields an `UnverifiedRecord`, never a
  `VerifiedAttestation`. Test builders (`verified::testing::verified(att,
  claim)`) exist behind `#[cfg(feature = "testing")]` and are what 071,
  081, and 094 use in fixtures.
- **B-5 (`VerifiedAttestationSet`).** `verify_set(atts: &[(Attestation,
  Value)], policy, anchors, tlog) -> VerifiedAttestationSet` runs
  `verify_one` on every item and returns `{ ok: Vec<VerifiedAttestation>,
  failed: Vec<Verdict>, policy_digest }`, both halves sorted by
  attestation id. `is_clean()` is true iff `failed` is empty; `by_predicate
  (&PredicateType)`, `by_subject(&Hash)`, and `issuers()` query the `ok`
  half only. A consumer that wants "all approvals" gets only verified ones
  and can see, separately, how many failed and why.
- **B-6 (determinism).** `verify_one` and `verify_set` are pure functions
  of their arguments; the `TlogClient` is the only seam that may perform
  I/O, and an in-process client makes every test hermetic. Two runs over
  identical inputs yield identical verdicts and an identical
  `policy_digest`.
- **B-7 (erasure).** A claim whose object has been erased (020) verifies
  the signature and issuer stages (the commitment is intact) and then fails
  at stage 6 with `Erased`; the attestation is thereby excluded from the
  `ok` half. An erased approval is not an approval.

## 4. Functional requirements

- **FR-001.** Every `VerifyFailure` variant is reachable by a test and the
  stage name reported with it matches `STAGES`.
- **FR-002.** Tests cover: a valid offline attestation; a valid strict
  attestation with an in-process transparency log; a signature made before
  a rotation still verifying and one made after a revocation failing at
  stage 3; a keyless attestation passing with a good bundle and failing with
  a tampered certificate; `require_tlog` refusing an unlogged attestation;
  an unknown predicate passing with `claim_checked = false`; a known
  predicate with a malformed claim failing at stage 6; an erased claim
  failing with `Erased`; `verify_set` sorting and `is_clean`.
- **FR-003.** A compile-fail test (`trybuild`) asserts that
  `VerifiedAttestation` cannot be constructed outside the crate.
- **FR-004.** `policy_digest` changes when any field of `VerifyPolicy` or
  the anchor set changes, and is stable otherwise (golden fixture).
- **FR-005.** The crate depends on `hqgit-types`, `hqgit-ledger`, and
  `hqgit-domain` only within the workspace.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-trust --locked --test verify` passes.
- **AC-2.** On the spec 033 fixture ledger, verifying the approval
  attestation under `VerifyPolicy::offline()` yields `Ok`, and under
  `VerifyPolicy::strict()` with an empty log yields `Failed` at
  `transparency`.

## 6. Out of scope

Policy evaluation over the verified set (065); deciding which policy
applies (068); capability derivation from verified attestations (094);
the executor trust tier (071); a served transparency log (a later
extension of 062 on the server).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-trust --locked
```
