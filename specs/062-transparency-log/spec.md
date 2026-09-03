---
id: "062-transparency-log"
title: "Transparency log: Merkle log, inclusion and consistency proofs, signed checkpoints"
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
establishes:
  - "crates/hqgit-trust/src/tlog/mod.rs"
  - "crates/hqgit-trust/src/tlog/merkle.rs"
  - "crates/hqgit-trust/src/tlog/proofs.rs"
  - "crates/hqgit-trust/src/tlog/client.rs"
  - "crates/hqgit-trust/tests/tlog.rs"
  - "crates/hqgit-trust/testdata/tlog/"
extends:
  - { spec: "060-identity-and-key-rotation", unit: "crates/hqgit-trust/src/lib.rs", nature: additive }
summary: >
  An append-only Merkle log in the RFC 6962 shape over BLAKE3, holding
  attestation ids and identity facts, with inclusion proofs, consistency
  proofs, and checkpoints signed by the log key and cosignable by
  witnesses. A signature proves who; the log proves that the signed thing
  was published and cannot later be quietly withdrawn or forked. This spec
  fixes the leaf and node hashing, the proof shapes, the checkpoint
  envelope, and the TlogClient seam with an in-process implementation;
  keyless signing (063) logs its certificates here and attestation
  verification (064) requires an inclusion proof when the repository policy
  demands one. The served log is a later extension.
---

# 062: Transparency log

## 1. Purpose

Thesis §4.5 names transparency-log inclusion proofs as part of the default
signing shape, and design doc §1.1 point 5 lists a transparency log among
the things that turn trust from decorative into checkable. A signature
alone lets a signer deny having published; a log with consistency proofs
makes publication a public, append-only fact that any verifier can hold the
log operator to. This spec builds that log as a library so a host (090 and
later) can serve it and any client can verify against it offline.

## 2. Territory

The `tlog` module tree inside `crates/hqgit-trust`: `merkle.rs` (leaf and
node hashing, the in-memory tree, roots at any size), `proofs.rs`
(inclusion and consistency proof types and their pure verifiers),
`client.rs` (the `TlogClient` trait, `Checkpoint`, cosignatures, and the
`InProcessLog`), `mod.rs` (re-exports and `LogEntry`), the tests, and the
frozen proof vectors under `testdata/tlog/`. Serving the log over the
network and persisting it durably belong to a later spec that extends
`client.rs`.

## 3. Behavior

- **B-1 (leaves).** `LogEntry` is a closed enum `Attestation(AttestationId)
  | IdentityFact(EntryHash) | Certificate(Hash)` (the third is for 063),
  encoded canonically (011) as `[tag: u8, hash]`. The leaf hash is
  `Hash::of(0x00 || canonical_bytes)`; an interior node hash is
  `Hash::of(0x01 || left || right)`. The empty tree root is
  `Hash::of(b"")`. These are frozen (constitution VIII).
- **B-2 (tree).** `MerkleTree` holds leaves in append order and MUST
  answer `root_at(size) -> Hash` for any `size <= len` in `O(log n)` using
  the RFC 6962 split rule (the largest power of two strictly less than
  `size` as the left subtree). `append(leaf) -> u64` returns the leaf
  index. Leaves are never removed or reordered.
- **B-3 (inclusion proofs).** `InclusionProof { leaf_index: u64, tree_size:
  u64, path: Vec<Hash> }`; `prove_inclusion(tree, index, size)` and the
  pure `verify_inclusion(proof, leaf_hash, root) -> Result<(), Error>`
  recompute the root from the leaf and the path and compare; a mismatch,
  an index at or beyond `tree_size`, or a path of the wrong length is
  `Error::Crypto`.
- **B-4 (consistency proofs).** `ConsistencyProof { old_size: u64,
  new_size: u64, path: Vec<Hash> }`; `prove_consistency(tree, old, new)`
  and the pure `verify_consistency(proof, old_root, new_root) ->
  Result<(), Error>` per RFC 6962 §2.1.2. A verifier that has trusted a
  checkpoint at `old_size` MUST require a consistency proof before trusting
  one at `new_size` from the same log; failure is evidence of a fork.
- **B-5 (checkpoints).** `Checkpoint { origin: String, tree_size: u64,
  root: Hash, at: Hlc, sig: Signature, cosigs: Vec<Cosignature>, extra }`
  where `origin` is the log's identity (an `IdentityId` from 060, rendered
  as hex), `sig` is the log key's signature under
  `SignDomain("tlog.checkpoint")` over the canonical bytes with `sig` and
  `cosigs` absent, and `Cosignature { witness: KeyId, sig: Signature }` is
  a witness's signature over the same bytes under
  `SignDomain("tlog.cosign")`. `verify_checkpoint(cp, log_verifier,
  witness_policy: &WitnessPolicy) -> Result<(), Error>` requires the log
  signature and at least `witness_policy.threshold` valid cosignatures
  from `witness_policy.witnesses`.
- **B-6 (client seam).** `trait TlogClient { fn submit(&mut self, entry:
  LogEntry) -> Result<Receipt, Error>; fn inclusion(&self, leaf_hash: &Hash)
  -> Result<(InclusionProof, Checkpoint), Error>; fn latest_checkpoint(&self)
  -> Result<Checkpoint, Error>; fn consistency(&self, old_size: u64,
  new_size: u64) -> Result<ConsistencyProof, Error>; }` with `Receipt {
  index: u64, leaf_hash: Hash, checkpoint: Checkpoint }`. Submitting a leaf
  already present returns the existing index (idempotent).
- **B-7 (in-process log).** `InProcessLog { tree, signer: Box<dyn Signer>,
  origin, witnesses: Vec<Box<dyn Signer>> }` implements `TlogClient` over a
  `LogStore` trait (`append`, `len`, `leaf(i)`, `checkpoint`) with
  `MemoryLogStore`; it issues a fresh checkpoint on every append, `at`
  supplied by an injected `HlcGenerator` (018). It is the log the CLI (034
  onward) and tests use; a served, durable `LogStore` is the later spec's
  extension.
- **B-8 (trusted checkpoints).** `TrustedCheckpoints { by_origin:
  BTreeMap<String, Checkpoint> }` is the verifier-side record (064 holds
  one per repository config): `advance(new_cp, consistency_proof) ->
  Result<(), Error>` accepts a later checkpoint only with a valid
  consistency proof from the recorded one; a smaller `tree_size` or a
  failed proof is `Error::Crypto("tlog fork")`.
- **B-9 (no ambient input).** The tree and proofs read no clock; checkpoint
  times come from the injected generator; `BTreeMap` only.

## 4. Functional requirements

- **FR-001.** `merkle.rs` and `proofs.rs` are pure; `client.rs` isolates
  the only mutation behind `LogStore`.
- **FR-002.** Frozen vectors under `testdata/tlog/`: `roots.json` (roots for
  sizes 0 through 8 over fixed leaves), `inclusion.json` (proofs for every
  leaf at sizes 1 through 8), `consistency.json` (every `old <= new` pair
  up to 8), `checkpoint.json` (a signed checkpoint with one cosignature and
  its canonical bytes). A test re-derives every field.
- **FR-003.** Tests cover: root recomputation matches vectors; inclusion
  proof for every leaf at every size; a tampered path element, a wrong
  index, and a wrong `tree_size` each fail; consistency across ten
  appends; a fork (two different trees at the same size) fails
  `advance`; checkpoint signature and cosignature threshold; idempotent
  submit; `TrustedCheckpoints` refuses a smaller size.
- **FR-004.** Property tests: for random leaf sets up to 1,000, every
  inclusion proof verifies and every consistency pair verifies.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-trust --locked tlog` passes, vectors
  included.
- **AC-2.** An `InProcessLog` seeded with the fixtures produces the frozen
  `checkpoint.json` bytes exactly when driven with the fixture signer and
  `Hlc`.

## 6. Out of scope

Serving the log over HTTP or gRPC and durable log storage (a later spec
extending `client.rs`, with the endpoint in 090's app); the certificates
logged as leaves (063); the verifier that demands inclusion (064); gossip
between witnesses (a federation concern, 112).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-trust --locked tlog
```
