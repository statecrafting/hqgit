---
id: "013-object-store"
title: "Object store: content-addressed blob and tree objects, the ObjectStore trait, memory and local backends"
status: approved
kind: "kernel"
domain: "l0-objects"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 1
depends_on:
  - "011-canonical-encoding"
establishes:
  - "crates/hqgit-object/Cargo.toml"
  - "crates/hqgit-object/src/lib.rs"
  - "crates/hqgit-object/src/object.rs"
  - "crates/hqgit-object/src/store.rs"
  - "crates/hqgit-object/src/memory.rs"
  - "crates/hqgit-object/src/local.rs"
  - "crates/hqgit-object/tests/"
extends:
  # redb, blake3 (if 010 did not already list it), and tempfile join the shared table.
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  L0 of the layer model: the content-addressed store every other layer
  reads and writes through. This spec founds hqgit-object with the object
  kinds (Blob, Tree, RepoGenesis) as canonical envelopes, the ObjectStore
  trait whose reads verify the hash before returning a byte, an in-memory
  backend for tests and a redb-backed local backend under the repository's
  .hq directory. Objects are immutable by construction, so every cache
  layer above them is trivially correct; deletion exists in the trait only
  as the erasure path spec 020 completes with a capability token. Chunking
  (014), verified streaming (015), and the remote backend (016) extend this
  crate without changing what a stored object is.
---

# 013: Object store

## 1. Purpose

Thesis §4.1 and constitution VI: canonical state is a set of
content-addressed objects, and BLAKE3 was chosen for verified streaming.
This spec fixes what an object is (a `Cid` over canonical bytes or raw
bytes), what a store promises (a get never returns bytes whose hash it did
not check), and the two backends the CLI needs before any server exists.
It is the first crate that touches a disk, and its immutability property is
what makes the object mapping to git (031), the layered remote cache (016),
and the action cache (071) simple.

## 2. Territory

`crates/hqgit-object` as founded here: the manifest (`[package.metadata.
spec-spine] spec = "013-object-store"`), `lib.rs`, `object.rs` (the object
kinds), `store.rs` (the trait and shared verification), `memory.rs`, and
`local.rs`, plus the `tests/` subtree. The crate depends on `hqgit-types`
only within the workspace. Chunking adds `chunk.rs` and `merkle.rs` (014),
verified streaming adds `bao.rs` and `fetch.rs` (015), the remote backend
adds `s3.rs` and `layered.rs` (016), and erasure adds `encrypt.rs` (020);
each `extends` this spec's `lib.rs`.

## 3. Behavior

- **B-1 (identity).** `pub type ObjectId = Cid`. A `Raw` object's id is
  `Cid { codec: Raw, hash: Hash::of(bytes) }`; a `DagCbor` object's id is
  `Cid { codec: DagCbor, hash: Hash::of(canonical_bytes) }` where the
  canonical bytes are the spec 011 encoding of its `Envelope`. The same
  bytes always have the same id; there is no other identity.
- **B-2 (object kinds).** `object.rs` defines, each as an `Envelope` with
  `kind` fixed and `v = 1.0`, all implementing `Canonical` with an `extra`
  map (011 B-6): `Blob` (`kind = "object.blob"`, the inline form for small
  content: `{ len: u64, bytes }`; the chunked form arrives in 014),
  `Tree` (`kind = "object.tree"`, `entries: Vec<TreeEntry { name: String,
  mode: EntryMode, cid: Cid }>`), and `RepoGenesis` (`kind =
  "object.genesis"`, `{ namespace: Hash, created_by: Principal, versions:
  BTreeMap<String, SchemaVersion> }`). `EntryMode` is a closed enum
  `File | Executable | Symlink | Tree` encoding as the strings `"file"`,
  `"exec"`, `"symlink"`, `"tree"`. An `Object` enum wraps the three with
  `Object::kind()` and `Object::id(&self) -> Cid`.
- **B-3 (tree rules).** `Tree` entries MUST be sorted by `name` bytes,
  unique by `name`, valid UTF-8, non-empty, and free of `/`, `\0`, `.`, and
  `..`; a `Tree` entry's `cid` codec MUST be consistent with its mode
  (`Tree` mode points at a `DagCbor` tree, the others at a blob). The
  constructor enforces every rule as `Error::Validation` and the decoder
  re-checks them, so an unsorted tree cannot exist with a valid id.
- **B-4 (`ObjectStore`).** `trait ObjectStore { fn put(&self, codec: Codec,
  bytes: &[u8]) -> Result<Cid, Error>; fn get(&self, cid: &Cid) ->
  Result<Option<Bytes>, Error>; fn has(&self, cid: &Cid) -> Result<bool,
  Error>; fn list(&self, prefix: &[u8]) -> Result<Vec<Cid>, Error>; fn
  erase(&self, cid: &Cid, cap: &EraseCapability) -> Result<Erased, Error>; }`.
  `put` MUST compute the id from the bytes it was given, MUST be idempotent
  (a second put of the same bytes returns the same id and writes nothing),
  and MUST NOT accept a caller-supplied id. `get` MUST recompute the hash
  of the bytes it read and return `Error::Crypto` on mismatch; bytes that
  failed verification are never returned. `list` returns ids whose hash
  starts with `prefix`, sorted. `erase` is declared here so the trait is
  complete, and until spec 020 supplies `EraseCapability` construction it
  is unconstructible outside that spec (a sealed struct with no public
  constructor), so every backend here implements `erase` and no caller can
  invoke it.
- **B-5 (`MemoryStore`).** A `BTreeMap<(Codec, Hash), Vec<u8>>` behind a
  `RwLock`; the reference implementation tests and every later crate's
  fixtures use.
- **B-6 (`LocalStore`).** A redb database at `<repo>/.hq/objects.redb`
  with one table `objects: (codec: u8, hash: [u8; 32]) -> bytes` and one
  table `meta: str -> bytes` holding `OBJECT_SCHEMA_VERSION`. `put` writes
  in one transaction and calls durable commit (fsync); `open` refuses an
  unknown schema MAJOR as `Error::Schema`; a torn write cannot produce a
  readable object because redb commits are atomic. The path layout is a
  contract spec 021 builds the rest of `.hq/` around.
- **B-7 (immutability).** No API updates or overwrites an object. A backend
  MAY garbage-collect only through `erase`. This is the property that makes
  the layered cache (016) and the git mapping (031) correct without
  invalidation logic.
- **B-8 (no ambient input).** The crate reads no clock and no environment;
  the only I/O is the redb file the caller names.

## 4. Functional requirements

- **FR-001.** `object.rs` and `store.rs` are I/O-free; only `local.rs`
  touches a filesystem, behind a path the caller supplies.
- **FR-002.** Tests cover: tampering with stored bytes yields
  `Error::Crypto` on get and never a value; a tree with unsorted, duplicate,
  or illegal names is refused on construction and on decode; put is
  idempotent and returns a stable id; `list` ordering and prefix semantics;
  `RepoGenesis` round trip; `LocalStore` reopen after close preserves
  objects and refuses a bumped MAJOR; the sealed `EraseCapability` cannot
  be constructed from a test.
- **FR-003.** A conformance test suite `tests/conformance.rs` runs the same
  assertions against every `ObjectStore` implementation through a generic
  function, so backends added by 016 reuse it.
- **FR-004.** The tree vectors (`testdata/vectors/object/tree-*.json`) are
  added to spec 011's corpus through an `extends` edge declared by the
  build session if the session adds them; otherwise the object encodings
  are pinned by unit tests in this crate.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-object --locked` passes.
- **AC-2.** The conformance suite passes against `MemoryStore` and
  `LocalStore`.
- **AC-3.** `spec-spine index` discovers `hqgit-object` bound to this spec
  and `index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Content-defined chunking and the chunked blob manifest (014); BAO outboard
data and range reads (015); the S3 backend and the layered cache (016);
constructing `EraseCapability` and encrypted namespaces (020); the git
object mapping (031).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-object --locked
```
