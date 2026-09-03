---
id: "063-keyless-signing"
title: "Keyless signing: short-lived certificates bound to an OIDC identity, the signature bundle, and bundle verification"
status: approved
kind: "feature"
domain: "l4-trust"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 4
depends_on:
  - "061-oidc-login"
  - "062-transparency-log"
establishes:
  - "crates/hqgit-trust/src/keyless.rs"
  - "crates/hqgit-trust/src/bundle.rs"
  - "crates/hqgit-trust/tests/keyless.rs"
  - "crates/hqgit-trust/testdata/keyless/"
extends:
  - { spec: "060-identity-and-key-rotation", unit: "crates/hqgit-trust/src/lib.rs", nature: additive }
  # The `keyless` feature and the two optional dependencies join the manifest.
  - { spec: "060-identity-and-key-rotation", unit: "crates/hqgit-trust/Cargo.toml", nature: additive }
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  The Sigstore shape, self-hosted: a session proven by OIDC login (061) is
  exchanged for an X.509 certificate over an ephemeral ed25519 key that is
  valid for ten minutes, the certificate is published to the transparency
  log (062), and the attestation signed with that key carries a
  SignatureBundle (certificate chain plus the certificate's inclusion
  proof) in its extra map, so a verifier can check it long after the key
  is gone. This spec fixes the certificate profile, the issuer seam with an
  in-process reference issuer, the bundle's canonical form, keyless
  issuance, and the pure bundle verifier that spec 064 calls as one stage
  of its chain. The identity's long-lived key (060) remains the offline
  signing path; keyless is the default when a session exists.
---

# 063: Keyless signing

## 1. Purpose

Thesis §4.5 and decision D11: signing defaults to the Sigstore shape,
short-lived certificates bound to an OIDC identity with transparency-log
inclusion proofs, run in-house when sovereignty matters. Design doc §1.1
point 5 counts it among the things that make trust checkable rather than
decorative (constitution XI). Spec 061 proves who is logged in and spec
060 holds the durable key; this spec joins them for the common case where
a human signs from a machine that should never hold a long-lived secret.
A session (061 B-9) buys a certificate over a key that lives ten minutes,
the certificate is logged, and the attestation carries what a verifier
needs. Nothing about the long-lived key path changes.

## 2. Territory

`keyless.rs` (the ephemeral key, the `CertificateIssuer` seam, the
`InProcessIssuer`, `sign_keyless`, `verify_bundle`) and `bundle.rs`
(`SignatureBundle`, `TrustRoots`, the Sigstore bundle reader) inside
`crates/hqgit-trust`, both behind the `keyless` cargo feature;
`tests/keyless.rs`; and the fixtures under `testdata/keyless/`. Additively:
`lib.rs` re-exports, the crate manifest (the feature and two optional
dependencies), and the workspace table (`sigstore` and `x509-cert`, pinned
exact). Consuming the bundle inside the verification chain is spec 064;
obtaining a session is spec 061; the log is spec 062.

## 3. Behavior

- **B-1 (feature).** A cargo feature `keyless`, on by default, gates both
  modules and makes `sigstore` and `x509-cert` optional dependencies.
  `cargo build -p hqgit-trust --no-default-features --locked` MUST build.
  Spec 064 compiles its keyless stage under the same feature.
- **B-2 (ephemeral key).** `EphemeralKey::generate(entropy: [u8; 32]) ->
  EphemeralKey` wraps a 010 `Ed25519Signer`; `public() -> PublicKey`,
  `key_id() -> KeyId`; it implements `Signer`. The seed is zeroized on
  drop, has no `Debug` or serde, and is never written to disk by this
  crate. `pop(&self, session: &Session) -> Signature` is the proof of
  possession: a signature under `SignDomain("keyless.pop")` over
  `session.subject.claims_hash || public key bytes`.
- **B-3 (issuer seam).** `CertRequest { session: Session, public:
  PublicKey, proof: Signature, not_before: u64 }` (seconds since epoch,
  injected). `trait CertificateIssuer { fn issue(&mut self, req:
  &CertRequest) -> Result<CertChain, Error>; }`. An issuer MUST refuse an
  invalid proof (`Error::Crypto`), `session.expires_at <= not_before`
  (`Error::Validation`), and a `session.subject.issuer` outside its
  allow-list (`Error::Config`). `CertChain { leaf: Vec<u8>, chain:
  Vec<Vec<u8>>, inclusion: InclusionProof, checkpoint: Checkpoint }` holds
  DER, leaf first, the root excluded.
- **B-4 (certificate profile).** X.509 v3; ed25519 SubjectPublicKeyInfo
  (OID `1.3.101.112`); serial from the issuer's monotonic counter;
  `notBefore = not_before`, `notAfter = not_before + 600`; empty subject;
  SubjectAltName with exactly one `otherName` of type
  `1.3.6.1.4.1.57264.1.7` carrying `sub` as UTF8String, plus an
  `rfc822Name` when the session has an email; extension
  `1.3.6.1.4.1.57264.1.8` carrying the OIDC issuer URL as a DER
  UTF8String; KeyUsage `digitalSignature` (critical); ExtendedKeyUsage
  `codeSigning`; BasicConstraints `CA = false`. The intermediate is ed25519
  with `pathLen = 0`; the root is ed25519. These OIDs are Sigstore's so
  Fulcio-issued and hqgit-issued certificates are read by one parser.
- **B-5 (in-process issuer).** `InProcessIssuer { ca: CaMaterial,
  allowed_issuers: Vec<String>, tlog: Box<dyn TlogClient>, serial: u64 }`
  with `CaMaterial { root: Vec<u8>, intermediate: Vec<u8>, signer: Box<dyn
  Signer> }` (the intermediate's key signs leaves). `issue` builds the
  leaf per B-4, signs it, submits `LogEntry::Certificate(Hash::of(leaf))`
  to the log (062 B-6), and returns the chain with the receipt's inclusion
  proof and checkpoint. It is the reference issuer tests and the CLI use;
  a served issuer is a later extension in the server (090 onward).
- **B-6 (`SignatureBundle`).** `SignatureBundle { v: u16, leaf: Vec<u8>,
  chain: Vec<Vec<u8>>, inclusion: InclusionProof, checkpoint: Checkpoint,
  extra }`, `v = 1`, a `Canonical` (011) envelope with kind
  `"keyless.bundle"`; `to_value()` and `from_value()`. It rides in
  `Attestation.extra["bundle"]` (027 B-1), so the attestation's signature
  and id cover it. It carries the certificate's inclusion proof and MUST
  NOT carry the attestation's own: the attestation id does not exist
  before signing. Spec 064 fetches that proof from the log by leaf hash.
- **B-7 (`sign_keyless`).** `sign_keyless(unsigned: UnsignedAttestation,
  key: &EphemeralKey, chain: &CertChain) -> Result<Attestation, Error>`
  refuses an `extra["bundle"]` already present (`Error::Validation`), a
  leaf whose key is not `key.public()` (`Error::Crypto`), and an
  `unsigned.at.wall_ms / 1000` outside the leaf's validity window
  (`Error::Validation`); it inserts the bundle and calls 027
  `Attestation::issue(unsigned, key)`, so `issuer_key` is the ephemeral
  key id while `issuer` stays the session's ledger identity.
  `log_attestation(att: &Attestation, tlog: &mut dyn TlogClient) ->
  Result<Receipt, Error>` submits `LogEntry::Attestation(id)`; the caller
  invokes it immediately after issuance.
- **B-8 (`verify_bundle`).** `verify_bundle(bundle: &SignatureBundle,
  roots: &TrustRoots, issuer_key: &KeyId, at_secs: u64, trusted:
  &TrustedCheckpoints) -> Result<KeylessIdentity, BundleFailure>` runs in
  this fixed order and stops at the first failure: (1) DER parsing,
  `Malformed`; (2) chain building from leaf through `chain` to a member of
  `roots.roots` with every link's signature checked, `UntrustedChain`, or
  `UnsupportedAlgorithm` for any non-ed25519 link; (3) `at_secs` inside
  the leaf window and the window at most 600 s, `OutsideValidity`; (4)
  KeyUsage, ExtendedKeyUsage, and `CA = false` per B-4, `BadLeafProfile`;
  (5) `KeyId::of(leaf key) == issuer_key`, `KeyMismatch`; (6) the SAN
  `otherName` and the issuer extension both present, `MissingSubject`;
  (7) `verify_checkpoint(checkpoint, roots.log_key, roots.witness_policy)`
  (062 B-5), `BadCheckpoint`; a trusted checkpoint of the same origin and
  `tree_size` with a different root, `LogForked`; `verify_inclusion` of
  the certificate leaf hash against `checkpoint.root`, `BadInclusion`.
  Success is `KeylessIdentity { issuer: String, sub: String, leaf_hash:
  Hash, not_before: u64, not_after: u64 }`. Mapping the subject to an
  `IdentityId` through 061's `BindingView` is spec 064's stage.
- **B-9 (`TrustRoots`).** `TrustRoots { roots: Vec<Vec<u8>>, log_key:
  PublicKey, witness_policy: WitnessPolicy, extra }`. The binary reads it
  from `[trust.keyless]` in `.hq/config.toml` (021); this crate never reads
  configuration. `TrustRoots::from_ca(&CaMaterial, log_key,
  witness_policy)` builds one for tests.
- **B-10 (Sigstore interop).** `read_sigstore_bundle(json: &[u8]) ->
  Result<ForeignBundle, Error>` parses the
  `application/vnd.dev.sigstore.bundle.v0.3+json` media type through the
  `sigstore` crate's bundle types into `ForeignBundle { leaf, chain,
  signature: Vec<u8>, subject: Option<(String, String)>, rekor: Value }`.
  Rekor entries hash with SHA-256, are carried opaquely, and are never
  accepted as hqgit log proofs; a foreign ECDSA chain is
  `UnsupportedAlgorithm` under B-8. The reader exists so the B-4 profile
  stays readable by Sigstore tooling and vice versa.
- **B-11 (no ambient input).** Entropy, `not_before`, and `at_secs` are
  injected; the crate reads no clock or randomness; `BTreeMap` only. The
  identity-key path (027 `Attestation::issue` with the 060 key) is
  untouched: offline signing needs neither an issuer nor a log.

## 4. Functional requirements

- **FR-001.** Every function is pure over its arguments; the only trait
  objects are `Signer`, `Verifier`, `TlogClient`, and `CertificateIssuer`.
- **FR-002.** Fixtures under `testdata/keyless/`: `ca/` (root and
  intermediate DER with their seeds), `leaf-valid.der`, and the bundles
  `valid.json`, `expired.json`, `wrong-key.json`, `untrusted-root.json`,
  `bad-inclusion.json`, `forked.json`, each recording the expected
  `verify_bundle` answer; plus `sigstore-bundle-v0.3.json` produced by
  sigstore-rs with its expected subject.
- **FR-003.** Tests cover: proof of possession accept and reject; each
  issuer refusal of B-3; an issued leaf parsed back matches B-4 field by
  field; the certificate leaf is included in the log; each `sign_keyless`
  refusal; the bundle is covered by the signature (flipping one byte of it
  fails 027 `verify_signature`); every `BundleFailure` variant; ordering
  (a bundle that is both expired and key-mismatched reports
  `OutsideValidity`); the Sigstore fixture yields its subject and
  `UnsupportedAlgorithm`.
- **FR-004.** `EphemeralKey` has no `Debug` or `Serialize` impl (a
  compile-fail test) and its seed is zeroized (a drop test on a copy of
  the memory is not required; the `zeroize` derive is asserted by source).
- **FR-005.** The manifest declares `sigstore` with default features off
  and only its bundle-parsing feature, and `x509-cert` with its `builder`
  feature, both `optional = true` behind `keyless`.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-trust --locked keyless` passes.
- **AC-2.** `cargo build -p hqgit-trust --no-default-features --locked`
  passes.
- **AC-3.** An attestation signed with `sign_keyless` against the fixture
  CA and an `InProcessLog` (062 B-7) round-trips through 027's canonical
  codec with `extra["bundle"]` intact and its id unchanged.

## 6. Out of scope

The verification chain that consumes the bundle (064); the CLI login and
keyless-signing verbs (the wave 6 CLI extension beside 093's remote
login); serving the issuer and the log (090 onward); ECDSA chains;
namespace-key distribution (a wave 4 amendment to 060).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-trust --locked keyless
cargo build -p hqgit-trust --no-default-features --locked
```
