---
id: "060-identity-and-key-rotation"
title: "Identity as a keypair with a rotation chain recorded in the ledger"
status: approved
kind: "kernel"
domain: "l4-trust"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 4
depends_on:
  - "019-facts-and-derived-state"
establishes:
  - "crates/hqgit-trust/Cargo.toml"
  - "crates/hqgit-trust/src/lib.rs"
  - "crates/hqgit-trust/src/identity.rs"
  - "crates/hqgit-trust/src/rotation.rs"
  - "crates/hqgit-trust/src/resolver.rs"
  - "crates/hqgit-trust/tests/"
  - "crates/hqgit-trust/testdata/identity/"
summary: >
  Authentication and identity are different problems (thesis §4.5). Login is
  OIDC (061); durable identity is a keypair whose rotation history is a
  sequence of signed facts in the ledger, so a signature made under a key
  that was later rotated or revoked still verifies at the time it was made.
  This spec founds hqgit-trust and fixes the three identity facts
  (identity.created, identity.key_rotated, identity.key_revoked), the
  IdentityId that every Principal id in 010 resolves to, the IdentityView
  fold that answers key_valid_at, and the RotationAwareResolver that plugs
  into the ledger's IssuerResolver seam (017) so chain verification stops
  trusting a static key table. Constitution XI: trust is checkable, not
  decorative.
---

# 060: Identity and key rotation

## 1. Purpose

Design doc §1.1 point 5: attribution today is an email string and signing
is decorative. hqgit makes identity a cryptographic object with history: a
`Principal` (010 B-6) is the hash of the fact that created it, its current
key is whatever the rotation chain says it is, and the chain lives in the
same ledger as everything it signs. Without this spec, every signature in
the corpus is verified against a static table (017's `StaticResolver`),
which cannot express rotation, revocation, or compromise windows. With it,
"who signed this, and was that key theirs at the time" is a fold over
facts, replayable by any replica.

## 2. Territory

`crates/hqgit-trust` as founded here: the manifest (workspace dependencies
`hqgit-types` and `hqgit-ledger` only), `lib.rs`, `identity.rs` (the facts,
`IdentityId`, `IdentityView`), `rotation.rs` (the chain rules and the
cosignature), `resolver.rs` (`RotationAwareResolver`), the `tests/` subtree,
and the frozen chain vectors under `testdata/identity/`. OIDC binding is
061, the transparency log is 062, keyless certificates are 063, and full
attestation verification is 064; each extends this crate.

## 3. Behavior

- **B-1 (fact kinds).** Three fact kinds, registered with the 019
  `FactRegistry` by `register_trust(registry)`, with frozen kind strings:
  `identity.created`, `identity.key_rotated`, `identity.key_revoked`. Each
  body is a `Canonical` struct (011) with an `extra` map for unknown-field
  preservation.
- **B-2 (`identity.created`).** Body `{ kind: PrincipalKind, initial_key:
  PublicKey, display: String, extra }`. The entry carrying it MUST be signed
  by `initial_key` (issuer equals `KeyId::of(initial_key)`): an identity is
  self-certifying. `IdentityId = Hash::of(canonical bytes of the fact
  envelope)`; the 010 ids (`HumanId`, `AgentId`, `ServiceId`, `OrgId`) are
  `IdentityId`s tagged by `kind`. `display` is descriptive only and never
  enters any trust decision.
- **B-3 (`identity.key_rotated`).** Body `{ identity: IdentityId, prev:
  KeyId, next: KeyId, next_pub: PublicKey, effective: Hlc, cosign:
  Signature, extra }`. The entry MUST be signed by `prev`, which MUST be the
  identity's active key at `effective`; `cosign` MUST be `next`'s signature
  under `SignDomain("identity.rotation")` over the canonical bytes of the
  body with `cosign` absent (proof of possession of the next key).
  `effective` MUST be greater than the previous chain fact's `effective`.
  A rotation makes `prev` `Rotated` from `effective` onward and `next`
  `Valid` from `effective` onward.
- **B-4 (`identity.key_revoked`).** Body `{ identity: IdentityId, key:
  KeyId, reason: Revocation, effective: Hlc, since: Option<Hlc>, extra }`
  with `Revocation` a closed enum `Compromise | Retired | Lost`. The entry
  MUST be signed by the identity's active key at `effective` or by any key
  that succeeds `key` in the chain (a compromised key is revoked by its
  successor). `since`, when present, MUST be less than or equal to
  `effective` and marks the start of the compromise window: signatures at or
  after `since` are invalid. Revoking the only active key freezes the
  identity: no further facts for it are accepted.
- **B-5 (`IdentityView`).** A `DerivedState` (019) folding the three kinds
  in total order (018). `fn key_valid_at(&self, key: &KeyId, at: &Hlc) ->
  KeyValidity` with `KeyValidity` a closed enum `Valid | NotYet(effective) |
  Rotated(effective) | Revoked { effective, since } | Unknown`. A `Rotated`
  key is `Valid` for `at` before its rotation (historical signatures keep
  verifying); a `Revoked` key is invalid for `at` at or after `since`
  (or `effective` when `since` is absent). `fn identity_of(&self, key) ->
  Option<IdentityId>`, `fn active_key(&self, identity, at) ->
  Option<(KeyId, PublicKey)>`, `fn chain(&self, identity) -> Vec<ChainLink>`.
- **B-6 (chain defects are recorded, never applied).** A fact that violates
  B-2 through B-4 (issuer is not the active key, missing or wrong cosign,
  non-monotonic `effective`, unknown identity, a rotation after a freeze)
  MUST NOT alter the view; it is recorded as a `ChainDefect { entry, rule,
  detail }` on the view so a verifier (064) and an operator can see the
  attempt. The fold never panics on a malformed body: it records
  `ChainDefect` with rule `Malformed`.
- **B-7 (resolver).** `RotationAwareResolver { view: IdentityView }`
  implements 017's `IssuerResolver`: `verifier_for(key, at)` returns an
  `Ed25519Verifier` when `key_valid_at(key, at)` is `Valid`, otherwise
  `Error::Crypto` naming the validity state and the identity. It is the
  resolver the CLI (034) and the server (090) MUST use once this spec
  lands; `StaticResolver` remains for tests and for bootstrapping a repo
  whose identity facts are being verified for the first time (the fold
  validates its own chain, B-2 to B-4, so no external key table is needed).
- **B-8 (no ambient input).** Nothing in this crate reads a clock or the
  environment; `effective` values are supplied by the caller (the CLI's
  `HlcGenerator`, 018). `BTreeMap` is the only map type (010 B-11).

## 4. Functional requirements

- **FR-001.** Every function in `identity.rs`, `rotation.rs`, and
  `resolver.rs` is pure over its arguments; the only trait objects are the
  010 `Signer` and `Verifier` seams and 017's `IssuerResolver`.
- **FR-002.** Golden chain vectors under `testdata/identity/`:
  `created.json`, `rotated-once.json`, `rotated-twice.json`,
  `revoked-compromise.json`, `forged-rotation.json`, each carrying seeds,
  the fact bodies, the expected canonical bytes and entry hashes, and the
  expected `KeyValidity` answers at named `Hlc` probes. A test re-derives
  every field. These vectors are frozen (constitution VIII).
- **FR-003.** Tests cover: a signature made before rotation verifies through
  the resolver and one made after fails; a revocation with `since` earlier
  than `effective` invalidates the window; a rotation without a valid
  `cosign` is a `ChainDefect` and leaves the view unchanged; a revocation
  signed by a key outside the chain is a defect; the frozen identity accepts
  no further facts; permutation of entry arrival order yields the same view.
- **FR-004.** `IdentityView` folds a ledger of 10,000 identity facts in
  linear time; the chain per identity is stored as a `Vec<ChainLink>`
  indexed by `IdentityId` in a `BTreeMap`.
- **FR-005.** The crate depends on `hqgit-types` and `hqgit-ledger` only
  within the workspace, and its manifest carries
  `[package.metadata.spec-spine] spec = "060-identity-and-key-rotation"`.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-trust --locked` passes, vectors included.
- **AC-2.** `spec-spine index` discovers `hqgit-trust` bound to this spec
  and `index coverage --fail-on-untraced` exits 0.
- **AC-3.** Ledger verification (017 B-7) of a fixture DAG containing a
  rotation passes with `RotationAwareResolver` and fails with a
  `StaticResolver` holding only the initial key, proving the resolver is
  load-bearing.

## 6. Out of scope

OIDC login and subject binding (061); the transparency log (062); keyless
short-lived certificates (063); end-to-end attestation verification (064);
agent registration and delegation (100, 101); any UI for key management.

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-trust --locked
cargo clippy -p hqgit-trust --all-targets --locked -- -D warnings
```
