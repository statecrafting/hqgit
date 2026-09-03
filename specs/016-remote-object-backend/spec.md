---
id: "016-remote-object-backend"
title: "Remote object backend: an S3-compatible store and the layered read-through cache"
status: approved
kind: "feature"
domain: "l0-objects"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: medium
wave: 1
depends_on:
  - "013-object-store"
  - "015-verified-streaming"
establishes:
  - "crates/hqgit-object/src/s3.rs"
  - "crates/hqgit-object/src/layered.rs"
  - "crates/hqgit-object/tests/s3.rs"
extends:
  - { spec: "013-object-store", unit: "crates/hqgit-object/src/lib.rs", nature: additive }
  - { spec: "013-object-store", unit: "crates/hqgit-object/Cargo.toml", nature: additive }
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  Thesis §4.1: local index in redb, remote in any S3-compatible store, and
  immutability makes every cache layer trivially correct. This spec adds
  an ObjectStore over any S3-compatible endpoint through the object_store
  crate, with a hash-sharded key layout, outboard sidecars, and conditional
  puts for idempotency; an ObjectSource over the same endpoint so verified
  range fetches (015) work against remote objects; and a LayeredStore that
  reads through a local store to a remote one and writes through to both.
  Negative caching is forbidden by design: content is immutable, presence
  is not, so a miss is retried and never memoized.
---

# 016: Remote object backend

## 1. Purpose

Spec 013 gave the CLI a local store and spec 015 made partial reads
verifiable. A server (090), a CI executor (073), and a peer (111) need
objects that live somewhere shared and durable without a second storage
system to operate. Any S3-compatible store is that place (thesis §4.1),
and because objects are immutable (013 B-7) the layered cache in front of
it needs no invalidation logic at all: the only question a cache can get
wrong is presence, and this spec forbids caching the answer "absent".

## 2. Territory

`s3.rs` (the `S3Store` backend and its `ObjectSource`), `layered.rs` (the
`LayeredStore`), and `tests/s3.rs`. The `object_store` crate (with its
`aws` feature) is pinned in the workspace dependency table. Spec 013's
conformance suite is reused against both new backends unchanged.

## 3. Behavior

- **B-1 (`S3Store`).** `S3Store::new(config: S3Config) -> Result<S3Store,
  Error>` where `S3Config { endpoint: String, bucket: String, prefix:
  String, region: Option<String>, credentials: CredentialSource }` and
  `CredentialSource` is `Env | Profile(String) | Static { .. }` (never
  serialized, never logged). It implements `ObjectStore` (013 B-4, with
  015 B-3's `get_range`) over the `object_store` crate's `AmazonS3`
  client, and MUST work against MinIO, Ceph RGW, and AWS S3 through the
  same configuration.
- **B-2 (key layout).** Object bytes at `<prefix>/objects/<codec-name>/
  <hash[0..2]>/<hash-hex>` and the BAO outboard (015 B-1) at the same key
  with the suffix `.obao`. `list(prefix)` maps to a listing under
  `objects/<codec-name>/<first two hex chars>` and filters locally; results
  are sorted before return.
- **B-3 (idempotent put).** `put` first computes the id, then issues a
  conditional put (`If-None-Match: *` where the endpoint supports it, else
  a head-then-put with the race accepted because the bytes are identical
  by construction). A second put of existing content performs no upload.
  The outboard is written before the object so a reader never sees an
  object without its sidecar; a crash between the two leaves an orphan
  sidecar that the next put overwrites identically.
- **B-4 (verified reads).** `get` downloads and verifies the hash (013
  B-4); `get_range` downloads the outboard and the byte range and verifies
  through spec 015 B-2, so a corrupted or malicious bucket is detected
  exactly as a malicious peer is. `S3Store` also implements 015 B-4's
  `ObjectSource`, serving `fetch_slice` with a proof computed from the
  stored outboard.
- **B-5 (`LayeredStore`).** `LayeredStore { local: Box<dyn ObjectStore>,
  remote: Box<dyn ObjectStore> }` implements `ObjectStore`: `get` and
  `get_range` try `local` then `remote`, and on a remote hit store the
  verified bytes locally (write-back of verified content only); `put`
  writes local then remote (write-through; a remote failure returns
  `Error::Io` after the local write succeeded and the caller may retry
  idempotently); `has` is local or remote; `list` unions and sorts;
  `erase` is applied to both. There is no eviction policy in this spec:
  the local tier is a full store, and eviction is a later operator feature.
- **B-6 (no negative cache).** `LayeredStore` MUST NOT record a remote
  miss. A subsequent `get` of the same id asks the remote again. This is
  stated as a rule because it is the one cache mistake immutability does
  not forgive: an object absent now may be present after a peer pushes it.
- **B-7 (errors).** Network and authorization failures are `Error::Io`
  with the endpoint and key named but credentials redacted; a hash mismatch
  is `Error::Crypto`; a misconfiguration is `Error::Config`.
- **B-8 (no ambient input).** Credentials come from the caller's
  `CredentialSource`; the store reads no clock and no environment except
  when the caller chose `CredentialSource::Env`, which is the only
  environment read in the crate and is documented as such.

## 4. Functional requirements

- **FR-001.** `S3Store` and `LayeredStore` pass spec 013's conformance
  suite (with the 015 range cases) against the `object_store` crate's
  in-memory backend configured as the S3 seam, so unit tests need no
  network.
- **FR-002.** Tests cover: key layout for a known hash; put idempotency
  (a second put issues no upload, asserted through a counting wrapper);
  outboard-before-object ordering; a tampered remote object refused;
  `LayeredStore` read-through populates local; write-through with a
  failing remote leaves local populated and returns `Error::Io`; no
  negative cache (a miss followed by a remote put followed by a get
  succeeds); `fetch_range` (015) over `S3Store` as an `ObjectSource`.
- **FR-003.** One `#[ignore]` live test runs against an endpoint named by
  `HQGIT_TEST_S3_ENDPOINT` and is documented in the test file; CI does not
  run it.
- **FR-004.** Credentials never appear in `Debug` output, logs, or error
  messages (a test formats an error and a config and asserts absence).

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-object --locked s3` passes.
- **AC-2.** `cargo test -p hqgit-object --locked` passes, conformance suite
  included.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Local-tier eviction and quota (an operator feature after 090); peer-to-peer
object exchange (111); server-side placement of buckets per repository
(091); encryption of objects at rest beyond the namespace envelope (020).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-object --locked s3
cargo test -p hqgit-object --locked
```
