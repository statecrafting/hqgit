---
id: "021-local-repository"
title: "Local repository: the .hq layout, the persistent entry store, namespaces, and the append path"
status: approved
kind: "kernel"
domain: "l1-ledger"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 1
depends_on:
  - "020-commitments-and-tombstones"
establishes:
  - "crates/hqgit-ledger/src/repo.rs"
  - "crates/hqgit-ledger/src/store.rs"
  - "crates/hqgit-ledger/src/namespace.rs"
  - "crates/hqgit-ledger/tests/repo.rs"
extends:
  - { spec: "017-ledger-entry-dag", unit: "crates/hqgit-ledger/src/lib.rs", nature: additive }
  - { spec: "017-ledger-entry-dag", unit: "crates/hqgit-ledger/Cargo.toml", nature: additive }
  - { spec: "010-workspace-and-core-types", unit: { kind: section, file: "Cargo.toml", anchor: "workspace.dependencies" }, nature: additive }
summary: >
  Where the ledger meets a disk. This spec fixes the .hq directory inside
  a working tree (the redb-backed entry store, the object store, the local
  identity, the config file), the EntryStore trait with atomic fsynced
  appends, the Repository type with init, open, and the one append path
  every fact takes (encode, put the payload object, build the entry on
  the current heads, stamp the clock, sign, append), and namespaces as
  facts with main and quarantine present from init. Write ordering is
  chosen so a crash can leave an orphan object but never a dangling
  entry. This is the substrate the CLI (032), the server (090), and the
  sync protocol (110) all share, which is what makes offline-first true.
---

# 021: Local repository

## 1. Purpose

Thesis §5 and constitution XIII: the CLI and the server run the same
ledger implementation, so offline-first is a property rather than a
promise. Specs 017 through 020 defined the ledger in memory; this spec is
its persistent form and the single append path, closing wave 1's ledger
half so that spec 032's `hq init` and spec 033's offline review have a
repository to write to. Namespaces arrive here because the quarantine
namespace (constitution XV) must exist before anything untrusted can be
written, and because encrypted namespaces (020) need a place to be
declared.

## 2. Territory

`repo.rs` (the `Repository` type, init, open, the append path, capability
minting), `store.rs` (the `EntryStore` trait and its redb implementation),
`namespace.rs` (the namespace facts and view), and `tests/repo.rs`, in
the crate 017 founded. The `.hq/` layout fixed here is a contract every
later spec that touches the directory (031 `gitmap.redb`, 040
`mirror.redb`, 080 `projections/`) extends rather than reshapes.

## 3. Behavior

- **B-1 (layout).** A repository is a directory containing `.hq/` with:
  `ledger.redb` (this spec), `objects.redb` (013 B-6), `identity/seed`
  (the local ed25519 seed, 32 bytes, created with mode `0600` on Unix),
  `identity/public` (the public key, hex), and `config.toml` (`schema =
  "1.0.0"`, `namespace = "<hex>"`, `node = "<hex>"`). `Repository::
  locate(start_dir) -> Option<PathBuf>` walks up to find `.hq/`, mirroring
  git's discovery, and stops at a filesystem boundary.
- **B-2 (`EntryStore`).** `trait EntryStore { fn append(&self, entry:
  &Entry) -> Result<EntryHash, Error>; fn get(&self, hash: &EntryHash) ->
  Result<Option<Entry>, Error>; fn contains(&self, hash: &EntryHash) ->
  Result<bool, Error>; fn heads(&self) -> Result<Vec<EntryHash>, Error>;
  fn children(&self, hash: &EntryHash) -> Result<Vec<EntryHash>, Error>;
  fn iter_all(&self) -> Result<Vec<EntryHash>, Error>; fn watermark(&self)
  -> Result<Option<Hlc>, Error>; }`. `RedbEntryStore` holds tables
  `entries: [u8; 32] -> canonical bytes`, `children: ([u8; 32], [u8; 32])
  -> ()`, `heads: [u8; 32] -> ()`, `meta: str -> bytes` (schema version,
  genesis hash, watermark). `append` runs the 017 B-6 checks (parents
  present, clock monotonic, duplicate is a no-op) inside one transaction
  that updates `entries`, `children`, `heads`, and the watermark, then
  commits durably (fsync). `iter_all` returns hashes sorted so callers can
  build a `Dag` (017) deterministically.
- **B-3 (write ordering).** The append path (B-5) MUST put the payload
  object (013) and its outboard (015) before appending the entry, so a
  crash between the two leaves an orphan object and never an entry whose
  payload is `Missing` by the repository's own fault. A `Repository::fsck()`
  reports orphans and any entry whose payload is missing, without
  repairing.
- **B-4 (`Repository::init`).** `init(path, identity: LocalIdentity) ->
  Result<Repository, Error>` refuses an existing `.hq/` (`Error::
  Validation`), creates the layout, derives the node id (018 B-7), writes
  the `RepoGenesis` object (013 B-2) with `namespace = Hash::of(b"hqgit/
  v1/namespace" || public_key || b"main")`, signs and appends the genesis
  entry (017 B-5), then appends the two namespace facts of B-6.
  `LocalIdentity::generate(rng: &mut dyn RngCore)` and `LocalIdentity::
  from_seed` are the constructors; the seed is the only secret on disk.
- **B-5 (`Repository::append_fact`).** `append_fact(&mut self, namespace:
  &Hash, envelope: FactEnvelope) -> Result<EntryHash, Error>` validates the
  envelope through the fact registry (019 B-2; unknown kinds pass), encodes
  it (011), puts the payload object (encrypted through 020 B-3 when the
  namespace is encrypted and the `KeyProvider` has its key, else
  `Error::Crypto`), collects the current heads as sorted parents, stamps
  `HlcGenerator::next(max parent hlc)` (018 B-5), signs with the local
  identity (017 B-3), and appends (B-2). It returns the new entry hash and
  it is the only public write path; `Dag` and `EntryStore` are not
  reachable mutably from outside the crate. `Repository` also implements
  019's `FactSource` and exposes `dag() -> Dag` (built from `iter_all`)
  and `total_order()` (018).
- **B-6 (namespaces).** `FactKind "ledger.namespace_declared"`, body `{
  id: Hash, name: String, encrypted: bool, quarantine: bool }`, and
  `"ledger.namespace_retired"` `{ id }`; `NamespaceView` is a
  `DerivedState` folding them into `BTreeMap<Hash, Namespace>` with
  `name` an `LwwRegister`. `init` declares `main` (`quarantine = false`)
  and `quarantine` (`quarantine = true`, id `Hash::of(b"hqgit/v1/
  namespace" || public_key || b"quarantine")`). A fact appended to the
  quarantine namespace carries `extra["namespace"] = id` in its entry so
  consumers (094) can partition without decoding payloads. Facts never
  move between namespaces; promotion (094) is a new fact.
- **B-7 (capabilities).** `Repository::owner_erase_capability(&self,
  namespace) -> EraseCapability` mints 020 B-6's owner capability for the
  local identity; `Repository::erase(&mut self, cid, reason)` appends the
  tombstone fact then calls 020's `erase` with that capability, in that
  order (020 B-6).
- **B-8 (open and versions).** `open(path)` reads `config.toml`, refuses a
  schema MAJOR it does not know (`Error::Schema`), opens both redb files,
  and verifies that the stored genesis hash matches the genesis entry's
  recomputed hash (`Error::Crypto` otherwise). Concurrent opens of one
  repository are serialized by a lock file `.hq/lock` (advisory, held for
  the lifetime of a mutable `Repository`).
- **B-9 (no ambient input).** The clock enters only through the
  `HlcGenerator` the repository holds (018 B-4); randomness enters only
  through the `RngCore` passed to `LocalIdentity::generate`.

## 4. Functional requirements

- **FR-001.** Every store operation is transactional and fsynced; a test
  simulates a crash by dropping the store mid-sequence (write objects,
  skip the entry) and asserts `fsck` reports an orphan and no dangling
  entry.
- **FR-002.** Tests cover: init then open round trip with identity and
  genesis verified; refusal to init over an existing `.hq/`; `locate` from
  a nested directory and from outside; `append_fact` builds parents from
  the current heads and advances the watermark; two repositories
  initialized from one seed, appending concurrently, then synced by
  copying entries through `EntryStore::append`, yield two heads and one
  total order; namespace declaration and retirement folding; quarantine
  facts tagged in `extra`; `erase` through the owner capability appends
  the tombstone first; `open` refuses a bumped MAJOR and a genesis
  mismatch; the lock file serializes a second mutable open.
- **FR-003.** `Repository` exposes no method that mutates an existing
  entry or rewrites history; a test enumerates the public API and asserts
  the only write methods are `append_fact`, `erase`, and `init`, plus
  `ingest_entry` once spec 110 adds it (an append of an already-signed
  foreign entry, never a rewrite).
- **FR-004.** The seed file is created with mode `0600` on Unix (asserted)
  and never read by any function other than `LocalIdentity::load`.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-ledger --locked repo` passes.
- **AC-2.** `cargo test -p hqgit-ledger --locked` passes in full.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

The `hq` binary that calls `init` and `append_fact` (032); the git object
mapping stored beside the ledger (031); identity beyond the local seed and
key rotation (060); replication between repositories (110); projections
persisted under `.hq/projections/` (080); the server's multi-repository
layout (090).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-ledger --locked repo
cargo test -p hqgit-ledger --locked
```
