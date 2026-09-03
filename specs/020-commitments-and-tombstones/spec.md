---
id: "020-commitments-and-tombstones"
title: "Commitments and tombstones: content indirection, per-namespace encryption, and erasure that keeps the chain verifiable"
status: approved
kind: "kernel"
domain: "l1-ledger"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 1
depends_on:
  - "019-facts-and-derived-state"
establishes:
  - "crates/hqgit-ledger/src/commitment.rs"
  - "crates/hqgit-ledger/src/tombstone.rs"
  - "crates/hqgit-object/src/encrypt.rs"
  - "crates/hqgit-ledger/tests/erasure.rs"
extends:
  - { spec: "017-ledger-entry-dag", unit: "crates/hqgit-ledger/src/lib.rs", nature: additive }
  - { spec: "013-object-store", unit: "crates/hqgit-object/src/lib.rs", nature: additive }
  # EraseCapability gains its constructors; erase gains its contract.
  - { spec: "013-object-store", unit: "crates/hqgit-object/src/store.rs", nature: additive }
  - { spec: "013-object-store", unit: "crates/hqgit-object/src/local.rs", nature: additive }
  - { spec: "013-object-store", unit: "crates/hqgit-object/src/memory.rs", nature: additive }
  - { spec: "013-object-store", unit: "crates/hqgit-object/Cargo.toml", nature: additive }
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  The erasure design decided at entry one because it cannot be
  retrofitted: the signed log contains commitments (content identifiers),
  never user content; content lives in the object store, encrypted per
  namespace where it must be; deletion removes the blob and appends a
  tombstone over the commitment; the chain stays verifiable and the
  content is genuinely gone. This spec fixes payload resolution with its
  three honest answers (present, erased, missing), the namespace
  encryption envelope whose commitment is over plaintext while the store
  holds ciphertext, the tombstone fact, the erase operation, and the
  unforgeable capability that gates it. Every projection must render an
  erased payload as erased and never fail.
---

# 020: Commitments and tombstones

## 1. Purpose

Thesis §4.2 and §8, constitution X, bootstrap anchor `erasure-by-
tombstone`: signed, replicated, append-only collaboration data collides
with erasure requirements and moderation, and the answer is content
indirection from day one. Spec 017 already made entry payloads `Cid`s;
this spec completes the design so that the CLI (033) can erase a comment
body, the server (094) can moderate quarantine content, and a legal hold
can be honored, all without rewriting a single signed byte. It also
supplies namespace encryption, so a private namespace's content is opaque
to a replica that holds its bytes but not its key.

## 2. Territory

`commitment.rs` (payload resolution and the encrypted-namespace read
path) and `tombstone.rs` (the tombstone fact kind, `erase`, and
`EraseCapability` minting) in `hqgit-ledger`; `encrypt.rs` (the
encryption envelope and the `KeyProvider` seam) in `hqgit-object`; the
`tests/erasure.rs` file; and the additive completion of spec 013's `erase`
contract across the trait and both backends. The AEAD and HKDF crates are
pinned in the workspace dependency table.

## 3. Behavior

- **B-1 (commitments).** An entry's `payload` is a `Cid` and nothing else
  (017 B-1); the log never carries content. `resolve_payload(entry: &Entry,
  store: &dyn ObjectStore, tombstones: &TombstoneSet, keys: &dyn
  KeyProvider) -> Result<Resolved, Error>` answers `Resolved::Present
  (Vec<u8>)`, `Resolved::Erased(TombstoneRef { entry: EntryHash, reason:
  EraseReason, at: Hlc })`, or `Resolved::Missing` (not erased, not held
  locally: a fetch (015) may still find it). A caller MUST handle all
  three; there is no accessor that panics or that maps `Erased` to
  `Missing`.
- **B-2 (encryption envelope).** `encrypt.rs` defines `EncryptedBlob {
  alg: Alg, nonce: [u8; 24], ciphertext: Vec<u8>, extra }` as an envelope
  with `kind = "object.encrypted"`, `Alg` a closed enum with one member
  `XChaCha20Poly1305`. `encrypt(key: &NamespaceKey, cid: &Cid, plaintext:
  &[u8]) -> EncryptedBlob` uses the plaintext's `Cid` bytes as associated
  data and a nonce derived as the first 24 bytes of HKDF-BLAKE3(key,
  info = b"hqgit/v1/nonce" || cid) so encryption is deterministic (the
  same plaintext in the same namespace encrypts identically, preserving
  put idempotency and deduplication); `decrypt(key, cid, &EncryptedBlob)
  -> Result<Vec<u8>, Error>` verifies the tag and re-verifies `Hash::of
  (plaintext) == cid.hash` (`Error::Crypto` on either failure).
- **B-3 (commitment over plaintext).** In an encrypted namespace the
  `Cid` referenced by an entry is computed over the plaintext (the
  commitment is content-addressed and stable across re-keying), while the
  store holds the `EncryptedBlob` keyed by that same `Cid`. `ObjectStore
  ::put_encrypted(key, codec, plaintext) -> Cid` and `get` on such an id
  returns the encrypted envelope bytes; `resolve_payload` performs the
  decrypt through the `KeyProvider`. A store therefore verifies an
  encrypted object by the envelope's own hash on read (013 B-4 applies to
  the ciphertext object, keyed under a `Raw` codec id derived as
  `Hash::of(b"hqgit/v1/enc" || cid)` so the two ids never collide).
- **B-4 (`KeyProvider`).** `trait KeyProvider { fn key_for(&self,
  namespace: &Hash) -> Result<Option<NamespaceKey>, Error>; }`.
  `NamespaceKey` is 32 bytes, never `Debug`-printed, never serialized into
  the ledger or any object. `NoKeys` (a provider that has none) makes every
  encrypted payload resolve as `Missing` with a distinct
  `Resolved::Missing` detail naming the namespace, so a replica without
  the key is honest about what it cannot read.
- **B-5 (tombstone fact).** `FactKind "ledger.tombstone"`, `v = 1`, body
  `{ target: Cid, reason: EraseReason, scope: TombstoneScope }` where
  `EraseReason` is a closed enum `Erasure | Moderation | Legal` and
  `TombstoneScope` is `Object` (the referenced content) or `Payload
  (EntryHash)` (the payload of one entry). It is registered with the fact
  registry (019 B-2) by `register_ledger(registry)`. `TombstoneSet` is a
  `DerivedState` (019 B-5) folding tombstones into a `BTreeMap<Cid,
  TombstoneRef>`; a later tombstone for the same target does not replace
  the earlier one (the first erasure is the record).
- **B-6 (`EraseCapability` and `erase`).** `EraseCapability` (declared
  sealed in 013 B-4) gains exactly two constructors: `EraseCapability::
  owner(repo_identity: &KeyId, namespace: &Hash)` (minted by the local
  repository for its own identity, 021) and `EraseCapability::from_verdict
  (attestation: &AttestationId)` (a policy verdict, 068; declared here,
  its verification is that spec's). `erase(store, cid, cap) -> Result<Erased,
  Error>` deletes the object bytes, the BAO outboard (015), and any
  encrypted envelope for `cid`; `Erased { cid, sidecars_removed: u8 }`. The
  tombstone fact MUST be appended before the bytes are deleted, so a crash
  leaves a tombstone with content still present (which `resolve_payload`
  reports as `Erased` and a repair sweep removes) and never content gone
  with no tombstone.
- **B-7 (chain stays verifiable).** Spec 017's `verify` MUST pass
  unchanged on a DAG whose payload objects were erased, because it hashes
  and signs commitments only. A test erases every payload in a fixture DAG
  and asserts a clean verify report.
- **B-8 (projections render erasure).** Any consumer folding facts (019
  B-5, 080) MUST treat an `Erased` payload as a fact with a null body and
  `extra["erased"] = true` and MUST NOT fail; the CLI (033) renders
  `[erased: <reason>]`. This rule is stated here and tested through 019's
  fold.
- **B-9 (no ambient input).** Nonces are derived, not random; no clock;
  keys come only from the `KeyProvider`.

## 4. Functional requirements

- **FR-001.** `encrypt.rs` is pure over key, id, and bytes; `commitment.rs`
  and `tombstone.rs` perform I/O only through the `ObjectStore` and
  `KeyProvider` traits.
- **FR-002.** Tests cover: the three `Resolved` outcomes; encrypt then
  decrypt round trip; a wrong namespace key fails; associated data binds
  the `Cid` (swapping ciphertexts between two ids fails); deterministic
  nonce derivation vector; `put_encrypted` idempotency; the encrypted id
  never collides with the plaintext id; tombstone first-wins; `erase`
  removes object, outboard, and envelope; tombstone-before-delete
  ordering under a simulated crash; verify passes after total erasure; the
  fold tolerates erased payloads; `EraseCapability` cannot be constructed
  outside its two constructors (a compile-fail test with `trybuild` or a
  visibility test).
- **FR-003.** The AEAD primitive is the pinned `chacha20poly1305` crate
  with its XChaCha variant and the HKDF is BLAKE3's `derive_key`; no other
  cryptographic dependency is introduced.
- **FR-004.** Key material never appears in `Debug`, logs, or errors (a
  formatting test asserts absence).

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-ledger --locked erasure` passes.
- **AC-2.** `cargo test -p hqgit-object --locked` and `cargo test -p
  hqgit-ledger --locked` pass in full.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Minting the owner capability at repository init (021); the policy verdict
that grants erasure (068); key distribution and rotation for namespace
keys (a wave 4 amendment to 060); serving or refusing erased content over
the network (094, 111); the repair sweep as an operator command (a later
CLI spec).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-ledger --locked erasure
cargo test -p hqgit-object --locked
```
