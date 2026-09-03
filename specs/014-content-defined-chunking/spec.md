---
id: "014-content-defined-chunking"
title: "Content-defined chunking: FastCDC with frozen parameters and the chunked blob manifest"
status: approved
kind: "kernel"
domain: "l0-objects"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 1
depends_on:
  - "013-object-store"
establishes:
  - "crates/hqgit-object/src/chunk.rs"
  - "crates/hqgit-object/src/merkle.rs"
  - "crates/hqgit-object/tests/chunk.rs"
  - "crates/hqgit-object/testdata/chunk/"
extends:
  - { spec: "013-object-store", unit: "crates/hqgit-object/src/lib.rs", nature: additive }
  # Blob gains its chunked representation, BlobManifest.
  - { spec: "013-object-store", unit: "crates/hqgit-object/src/object.rs", nature: additive }
  - { spec: "013-object-store", unit: "crates/hqgit-object/Cargo.toml", nature: additive }
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  Large files are the general path with different chunk statistics, not a
  special case bolted on later. This spec adds FastCDC content-defined
  chunking with parameters frozen forever (so chunk boundaries are stable
  across releases and replicas), the BlobManifest object that names a
  chunked blob by the list of its chunk ids, the rule that content at or
  below one chunk stays inline, a binary Merkle tree over chunk hashes with
  its own domain, and the put_blob and get_blob entry points that hide the
  split from every caller. The manifest id is the identity of a chunked
  blob; the whole-content BLAKE3 hash is recorded alongside for the git
  bridge and the BAO outboard alignment spec 015 needs.
---

# 014: Content-defined chunking

## 1. Purpose

Thesis §4.1: content-defined chunking plus a Merkle tree means LFS is just
the general path with different chunk statistics. Design §1.1 point 8
names monorepo scale as a real failure of the incumbent model. This spec
makes every blob, small or large, take the same code path, and it freezes
the chunking parameters because a chunk boundary that moves between
releases would change every manifest id and break deduplication across
replicas (constitution VIII applies to chunk boundaries exactly as to
encodings).

## 2. Territory

`chunk.rs` (the chunker and its frozen parameters), `merkle.rs` (the chunk
hash tree), the `BlobManifest` addition to spec 013's `object.rs`, the
`put_blob` and `get_blob` entry points exported from `lib.rs`, the
`tests/chunk.rs` file, and the `testdata/chunk/` fixtures. The `fastcdc`
crate joins the workspace dependency table.

## 3. Behavior

- **B-1 (frozen parameters).** `chunk.rs` defines `pub const CHUNK_MIN:
  usize = 65_536`, `CHUNK_AVG: usize = 262_144`, `CHUNK_MAX: usize =
  1_048_576`, and `CHUNK_PARAMS_VERSION: u16 = 1`, and uses the FastCDC
  (2016) algorithm with normalization level 1 and the gear table of the
  `fastcdc` crate at a pinned version. A test hashes the gear table and
  asserts the recorded constant `GEAR_TABLE_HASH`; the crate version is
  pinned exact in `[workspace.dependencies]`. Changing any of these is a
  schema MAJOR of `OBJECT_SCHEMA_VERSION` and a spec amendment.
- **B-2 (chunker).** `pub fn chunk(reader: impl Read) -> impl Iterator<Item
  = Result<Chunk, Error>>` yields `Chunk { offset: u64, bytes: Vec<u8> }`
  in order with bounded memory (at most `CHUNK_MAX` plus a read buffer
  resident). The boundaries MUST depend only on the content bytes, never on
  read sizes or platform.
- **B-3 (`BlobManifest`).** Added to `object.rs` as an envelope with `kind
  = "object.blob-manifest"`: `{ total_len: u64, content_hash: Hash,
  params_version: u16, chunks: Vec<ChunkRef { cid: Cid, len: u32 }>,
  extra }`. `content_hash` is `Hash::of` over the whole plaintext content
  (the same value a git bridge or BAO outboard is computed against, 015
  and 031). Every `ChunkRef.cid` MUST be a `Raw` object; the sum of `len`
  MUST equal `total_len`; the decoder re-checks both as
  `Error::Validation`.
- **B-4 (inline threshold).** Content whose length is at most `CHUNK_MAX`
  is stored as one `Raw` object and its id is that object's `Cid`; content
  above `CHUNK_MAX` is stored as `Raw` chunks plus a `BlobManifest`, and its
  id is the manifest's `Cid`. `put_blob(store, reader) -> Result<BlobId,
  Error>` where `BlobId { cid: Cid, inline: bool, content_hash: Hash,
  total_len: u64 }` applies this rule; `get_blob(store, cid) ->
  Result<Option<BlobReader>, Error>` reassembles either form as a streaming
  reader that verifies each chunk on read through spec 013 B-4 and, at the
  end, verifies `content_hash` (`Error::Crypto` on mismatch).
- **B-5 (chunk tree).** `merkle.rs` computes `chunk_tree_root(chunks:
  &[ChunkRef]) -> Hash` as a binary Merkle tree over chunk hashes with
  BLAKE3 keyed derivation under the context string `"hqgit/v1/chunk-tree"`
  (leaf = `derive(ctx, 0x00 || hash)`, node = `derive(ctx, 0x01 || left
  || right)`, an odd trailing node promoted unchanged) and
  `chunk_tree_proof(chunks, index) -> Vec<Hash>` with
  `verify_chunk_proof(root, index, hash, proof) -> bool`. The root is NOT
  the manifest id and NOT `content_hash`; it is the inclusion instrument
  for a single chunk when a peer serves chunks out of order (110, 111).
- **B-6 (determinism).** The manifest for given content is a pure function
  of the bytes: same content, same chunks, same manifest id, on every
  platform. A one-byte edit in the middle of a large file MUST change at
  most two chunk ids (the chunk containing the edit and, if a boundary
  shifts, its successor) and leave the rest shared.
- **B-7 (no ambient input).** The chunker reads no clock, no environment,
  and uses no randomness.

## 4. Functional requirements

- **FR-001.** `chunk.rs` and `merkle.rs` are pure over their inputs; the
  only I/O is the reader the caller passes and the store the caller names.
- **FR-002.** Fixtures under `testdata/chunk/` hold deterministic
  pseudo-random content generated from a recorded seed (the generator is in
  the test, the seed is a constant) with the expected boundary offsets and
  chunk hashes for 1 MiB, 3 MiB, and 10 MiB inputs; a test regenerates and
  asserts them.
- **FR-003.** Tests cover: boundary determinism against FR-002; inline
  versus chunked at `CHUNK_MAX` and `CHUNK_MAX + 1`; a one-byte edit
  touches at most two chunks; manifest round trip through the codec; the
  `len` sum and codec rules refused on decode; `get_blob` detects a
  tampered chunk and a tampered `content_hash`; chunk tree proofs verify
  and a wrong index fails; the gear table hash pin.
- **FR-004.** Memory during `put_blob` and `get_blob` of a 10 MiB fixture
  stays under 4 MiB of buffers (asserted structurally: the reader never
  holds more than `CHUNK_MAX` plus the read buffer).

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-object --locked chunk` passes.
- **AC-2.** The full `cargo test -p hqgit-object --locked` passes,
  including spec 013's conformance suite unchanged.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

BAO outboard trees and verified range reads (015); the remote backend
(016); the git blob mapping that records `content_hash` (031); any
compression (objects are stored as given; compression is a transport
concern for 111).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-object --locked chunk
cargo test -p hqgit-object --locked
```
