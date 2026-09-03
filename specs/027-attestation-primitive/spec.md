---
id: "027-attestation-primitive"
title: "The attestation primitive: one signed evidence shape, a predicate registry, in-toto interop"
status: approved
kind: "kernel"
domain: "l2-domain"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 1
depends_on:
  - "023-domain-fact-vocabulary"
establishes:
  - "crates/hqgit-domain/src/attestation.rs"
  - "crates/hqgit-domain/src/predicate.rs"
  - "crates/hqgit-domain/tests/attestation.rs"
  - "crates/hqgit-domain/testdata/attestations/"
extends:
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/lib.rs", nature: additive }
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/facts.rs", nature: additive }
  # The frozen attestation vectors join the golden corpus 011 established.
  - { spec: "011-canonical-encoding", unit: "crates/hqgit-types/testdata/vectors/", nature: additive }
summary: >
  The single most valuable simplification in the design (thesis §4.3,
  constitution IX): every form of evidence is one primitive, Attestation
  { subject, predicate, issuer, claim, sig }. Human approval, build
  provenance, test result, static finding, license scan, policy
  evaluation, mirrored external state, semantic delta, and agent action
  are the same shape, stored the same way, verified the same way, and fed
  to policy the same way. This spec fixes the attestation's canonical
  bytes, signing preimage, and id (frozen with vectors), the predicate
  registry with claim validators for the built-in predicates and reserved
  slots later specs fill, signature verification, and a lossless mapping
  to in-toto Statement v1 so SLSA tooling reads hqgit evidence. Requests to
  special-case a predicate are refused by construction: there is no other
  noun.
---

# 027: The attestation primitive

## 1. Purpose

Design §1.1 point 5 says trust is decorative because approvals are UI
state and attribution is an email string. The fix is a single evidence
object with a signature, a typed claim, and a subject hash, generalizing
in-toto's statement model. Because attestations are what policy (065)
evaluates, what the action cache (071) trusts, and what the transparency
log (062) records, their byte layout is frozen here at wave 1 alongside
the ledger entry (017), and every later evidence kind registers a
predicate instead of inventing a shape.

## 2. Territory

`attestation.rs` (the type, canonical bytes, signing, id, signature
verification, the in-toto mapping), `predicate.rs` (`PredicateType`, the
built-in constants, the `PredicateRegistry` and `ClaimValidator` seam,
the built-in claim schemas), `tests/attestation.rs`, and in-toto fixtures
under `testdata/attestations/`. Additively: `lib.rs` re-exports, the
`attestation.issued` decoder in `facts.rs`, and an `attestation/` vector
set in spec 011's golden directory. Specs 051, 067, 074, and 102 extend
`predicate.rs` with their claim schemas.

## 3. Behavior

- **B-1 (shape).** `Attestation { subject: Hash, predicate: PredicateType,
  issuer: Principal, issuer_key: KeyId, claim: Cid, at: Hlc, sig:
  Signature, extra: BTreeMap<String, Value> }`. `subject` is any BLAKE3
  hash (a revision id, a tree cid's hash, an entry hash, an artifact
  digest); `claim` is the cid of a `DagCbor` object holding the predicate's
  claim; `extra` is preserved and hashed (011). A signature bundle from
  keyless signing (063) rides in `extra` under the key `bundle`.
- **B-2 (canonical bytes and id).** The canonical bytes are the spec 011
  encoding of the map with keys `at`, `claim`, `issuer`, `issuer_key`,
  `predicate`, `sig`, `subject`, with `extra` flattened (collision is
  `Error::Validation`). The signing preimage is the canonical bytes with
  `sig` absent under `SignDomain("attestation")` (010 B-7). `AttestationId
  = Hash::of(canonical bytes with sig)`; the attestation is stored as a
  `DagCbor` object (013) whose cid hash equals its id, and the
  `attestation.issued` fact (023) references that cid plus `subject`,
  `predicate`, and `issuer` as indexable copies.
- **B-3 (issuance).** `Attestation::issue(unsigned: UnsignedAttestation,
  signer: &impl Signer) -> Attestation` sets `issuer_key` from the signer
  and signs; there is no other constructor of a signed value.
  `issue_fact(att: &Attestation, cid: Cid) -> DomainFact` builds the
  `attestation.issued` fact for the caller to append after storing the
  object.
- **B-4 (predicates).** `PredicateType(String)` MUST match
  `^[a-z0-9-]+(/[a-z0-9-]+)*/v[0-9]+$`. Constants: `hqgit/approval/v1`,
  `hqgit/provenance/v1`, `hqgit/test-result/v1`, `hqgit/static-finding/v1`,
  `hqgit/license/v1`, `hqgit/policy-eval/v1`, `hqgit/agent-action/v1`,
  `hqgit/mirror/v1`, `hqgit/semantic-delta/v1`. Claim schemas fixed here:
  approval `{ revision: RevisionId, verdict: Approve | RequestChanges,
  comment: Option<String> }`; test-result `{ suite: String, passed: u32,
  failed: u32, skipped: u32, log: Option<Cid> }`; static-finding `{ tool:
  String, findings: Vec<{ rule, severity: Info | Low | Medium | High |
  Critical, path, anchor: Option<Value> }> }`; license `{ packages: Vec<{
  name, version, license }>, verdict: Allow | Deny(String) }`; mirror `{
  source, external_id, kind, observed_by: Principal }`. Reserved (accepted
  as opaque until the named spec extends this file): provenance (074),
  policy-eval (067), agent-action (102), semantic-delta (051).
- **B-5 (registry).** `PredicateRegistry { validators: BTreeMap<
  PredicateType, Box<dyn ClaimValidator>> }` with `trait ClaimValidator {
  fn validate(&self, claim: &Value) -> Result<(), Error> }`;
  `register_builtin(&mut registry)` installs B-4's schemas; an unknown
  predicate is preserved, signature-verified, and reported as
  `ClaimVerdict::Unregistered`, never rejected (new evidence kinds must be
  able to flow before every replica upgrades).
- **B-6 (verification here).** `verify_signature(att: &Attestation,
  verifier: &impl Verifier) -> Result<(), Error>` recomputes the preimage
  and checks `sig`; `verify_claim(att, claim: &Value, registry) ->
  ClaimVerdict { Valid | Invalid(String) | Unregistered }`. Identity,
  rotation validity, keyless bundles, and transparency inclusion are the
  trust plane's chain (064); this spec verifies bytes against a key it is
  handed.
- **B-7 (in-toto interop).** `to_in_toto(&self, claim: &Value) ->
  InTotoStatement` produces `{ _type: "https://in-toto.io/Statement/v1",
  subject: [{ name: hex, digest: { blake3: hex } }], predicateType:
  IN_TOTO_PREDICATE_BASE + predicate, predicate: claim as JSON }` with
  `IN_TOTO_PREDICATE_BASE = "https://schemas.hqgit.dev/"` (a namespace
  constant, not a live URL). `from_in_toto(statement, issuer, signer) ->
  Result<UnsignedAttestation, Error>` accepts a statement whose subject
  carries a `blake3` digest and rejects one that does not
  (`Error::Validation`); any other digests are kept in `extra` under
  `digests`. The JSON rendering of the claim uses sorted keys.
- **B-8 (vectors).** `attestation/approval.json`, `attestation/with-extra.json`,
  and `attestation/in-toto.json` record unsigned fields, seed, canonical
  bytes, signature, id, and (for the third) the in-toto JSON. Frozen
  (constitution VIII).

## 4. Functional requirements

- **FR-001.** Tests: canonical bytes against vectors; issue then verify;
  a tampered byte fails; id covers the signature; every built-in claim
  schema accepts its fixture and rejects a malformed one; unregistered
  predicate yields `Unregistered` with the signature still checked;
  `extra` preserved and hashed; in-toto round trip on the fixture set,
  including a rejected sha256-only statement; regex acceptance and
  rejection cases for `PredicateType`.
- **FR-002.** A property test asserts encode and decode are inverse for
  random valid attestations and that two encodes agree.
- **FR-003.** `attestation.rs` and `predicate.rs` read no clock and
  perform no I/O; the claim object is passed in, never fetched.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-domain --locked attestation` passes,
  vectors included.
- **AC-2.** The in-toto fixture produced by `to_in_toto` validates against
  the in-toto Statement v1 JSON schema checked into
  `testdata/attestations/`.

## 6. Out of scope

Identity, rotation, keyless bundles, transparency inclusion, and the
end-to-end verification chain (060 to 064); the claim schemas of the
reserved predicates (051, 067, 074, 102); the CLI (034).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-domain --locked attestation
cargo test -p hqgit-types --locked golden
```
