---
id: "015-verified-streaming"
title: "Verified streaming: BAO outboard trees, range proofs, and lazy fetch that never trusts a byte"
status: approved
kind: "kernel"
domain: "l0-objects"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 1
depends_on:
  - "014-content-defined-chunking"
establishes:
  - "crates/hqgit-object/src/bao.rs"
  - "crates/hqgit-object/src/fetch.rs"
  - "crates/hqgit-object/tests/bao.rs"
extends:
  - { spec: "013-object-store", unit: "crates/hqgit-object/src/lib.rs", nature: additive }
  # ObjectStore gains the range read; backends gain the outboard sidecar.
  - { spec: "013-object-store", unit: "crates/hqgit-object/src/store.rs", nature: additive }
  - { spec: "013-object-store", unit: "crates/hqgit-object/src/local.rs", nature: additive }
  - { spec: "013-object-store", unit: "crates/hqgit-object/src/memory.rs", nature: additive }
  - { spec: "013-object-store", unit: "crates/hqgit-object/Cargo.toml", nature: additive }
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  The reason BLAKE3 was chosen over SHA-256: the BAO tree gives chunk-level
  verification and range proofs, so partial and lazy fetch are verifiable
  by construction rather than trusted. This spec stores a BAO outboard
  encoding beside every Raw object, adds a range read to the store whose
  result type cannot exist without a verified proof, defines the
  ObjectSource seam a remote (016, 111) implements to serve slices with
  proofs, and a lazy fetch API that verifies with bounded memory and never
  lets a partial object into the store as if it were whole. Tampered
  slices are rejected at the byte where the proof fails.
---

# 015: Verified streaming

## 1. Purpose

Thesis §4.1 (D2): BLAKE3 over SHA-256 primarily for verified streaming.
Without this spec a client that fetches part of a large blob from a peer
must trust the peer; with it, every slice carries a proof against the
object's own hash, so the remote backend (016), the sync protocol (111),
and the git endpoint (092) can serve ranges to untrusted clients and
accept ranges from untrusted peers. The type system carries the guarantee:
a `VerifiedSlice` is only constructible by the verifier.

## 2. Territory

`bao.rs` (outboard encoding, proof construction, proof verification),
`fetch.rs` (the `ObjectSource` seam and the lazy fetch driver), the
`tests/bao.rs` file, and the additive range-read surface on spec 013's
trait and backends. The `bao` crate (the reference BAO implementation) is
pinned exact in the workspace dependency table.

## 3. Behavior

- **B-1 (outboard).** For every `Raw` object, `bao::encode_outboard(bytes)
  -> Outboard` produces the BAO outboard tree over the standard BLAKE3
  1024-byte chunk group (the `bao` crate's outboard format, version pinned);
  the outboard's root MUST equal `Hash::of(bytes)` and a test asserts it.
  Backends store the outboard as a sidecar keyed by the same `(codec,
  hash)` under a second redb table `outboards` (013 `LocalStore`) or a
  second map (013 `MemoryStore`); `put` computes and stores it in the same
  transaction, so an object never exists without its outboard.
  `DagCbor` objects are small by construction (011 B-3 nesting limit and
  014 B-4 inline threshold) and carry no outboard; a range read on one is
  `Error::Validation`.
- **B-2 (range proofs).** `bao::prove(outboard, bytes, range: Range<u64>)
  -> SliceProof` produces the minimal set of tree nodes that lets a
  verifier holding only the object hash check the bytes of `range`;
  `bao::verify_slice(hash: &Hash, range, proof: &SliceProof, bytes: &[u8])
  -> Result<VerifiedSlice, Error>` re-derives the root and returns
  `Error::Crypto` naming the first failing chunk group offset otherwise.
  `VerifiedSlice { hash: Hash, range: Range<u64>, bytes: Vec<u8> }` has no
  public constructor and no mutable accessor; `into_bytes` is its only
  exit.
- **B-3 (store range read).** `ObjectStore` (013 B-4) gains `fn get_range
  (&self, cid: &Cid, range: Range<u64>) -> Result<Option<VerifiedSlice>,
  Error>`: a local read that still verifies through the outboard rather
  than trusting the local disk (a bit flip on disk is detected exactly as
  a malicious peer is). A range past the end is clipped; an empty range
  returns an empty verified slice.
- **B-4 (`ObjectSource`).** `trait ObjectSource { fn fetch_slice(&self,
  cid: &Cid, range: Range<u64>) -> Result<Option<(SliceProof, Vec<u8>)>,
  Error>; fn fetch_whole(&self, cid: &Cid) -> Result<Option<Vec<u8>>,
  Error>; fn size_of(&self, cid: &Cid) -> Result<Option<u64>, Error>; }`.
  The remote backend (016) and the sync session (111) implement it; a
  `LocalSource` over any `ObjectStore` implements it for tests and for
  serving.
- **B-5 (lazy fetch).** `fetch_range(cid, range, source: &dyn ObjectSource)
  -> Result<VerifiedSlice, Error>` fetches and verifies with at most one
  slice in memory at a time, splitting a large range into slices of at most
  `FETCH_SLICE_MAX = 4 MiB`; `fetch_into(store, cid, source) ->
  Result<Cid, Error>` streams a whole object through verification and only
  then calls `store.put`, so a partial or tampered object never enters a
  store. A chunked blob (014) is fetched manifest first, then each chunk
  through the same path, each chunk verified against its own id.
- **B-6 (proof bounds).** For an object of `n` bytes and a range of `k`
  bytes, the proof size MUST be `O(log n)` chunk-group hashes plus the
  boundary groups; a test asserts an upper bound for the fixture sizes so a
  regression to whole-tree proofs is caught.
- **B-7 (no ambient input).** No clock, no environment, no randomness.

## 4. Functional requirements

- **FR-001.** `bao.rs` is pure over bytes and proofs; `fetch.rs` performs
  I/O only through the `ObjectSource` and `ObjectStore` traits.
- **FR-002.** Tests cover: outboard root equals the object hash; a slice
  proof verifies; a one-bit flip in the slice, in the proof, or in the
  claimed hash is rejected with the offending group named; ranges
  crossing a chunk-group boundary, a chunk (014) boundary, the start, and
  the end; empty and past-the-end ranges; `fetch_into` refusing a source
  that serves a tampered whole object and leaving the store unchanged;
  proof size bounds per B-6; a chunked blob fetched through a source that
  serves chunks out of order.
- **FR-003.** Spec 013's conformance suite gains range-read cases and
  still passes against both backends.
- **FR-004.** Memory during `fetch_range` of a 10 MiB range stays bounded
  by `FETCH_SLICE_MAX` plus proof size (asserted structurally).

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-object --locked bao` passes.
- **AC-2.** `cargo test -p hqgit-object --locked` passes, including the
  conformance suite with range reads.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

The S3-backed `ObjectSource` (016); the QUIC transport and sync session
that serve slices between peers (111); serving ranges over the git
endpoint (092); any caching policy for fetched slices (016's layered
store).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-object --locked bao
cargo test -p hqgit-object --locked
```
