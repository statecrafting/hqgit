---
id: "017-ledger-entry-dag"
title: "Ledger entry and the hash-linked DAG: shape, signing bytes, append, verify"
status: approved
kind: "kernel"
domain: "l1-ledger"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 1
depends_on:
  - "011-canonical-encoding"
  - "013-object-store"
establishes:
  - "crates/hqgit-ledger/Cargo.toml"
  - "crates/hqgit-ledger/src/lib.rs"
  - "crates/hqgit-ledger/src/entry.rs"
  - "crates/hqgit-ledger/src/dag.rs"
  - "crates/hqgit-ledger/src/verify.rs"
  - "crates/hqgit-ledger/tests/"
  - "fuzz/fuzz_targets/entry_hash_stable.rs"
extends:
  # The frozen entry vectors join the golden corpus 011 established.
  - { spec: "011-canonical-encoding", unit: "crates/hqgit-types/testdata/vectors/", nature: additive }
  # One more fuzz target in the fuzz workspace 012 established.
  - { spec: "012-hash-stability-gate", unit: "fuzz/Cargo.toml", nature: additive }
summary: >
  The core primitive of the platform: a ledger entry is { parents, issuer,
  hlc, payload, sig }, a hash-linked DAG rather than a linear log because
  concurrent authors are the normal case. This spec founds hqgit-ledger and
  fixes, permanently, the entry's canonical shape, its signing preimage, and
  its hash; the in-memory DAG with append and head tracking; and chain
  verification (hash links, parent presence, signature through an issuer
  resolver seam, clock monotonicity). Nothing here persists (021) or orders
  (018) or interprets payloads (019, 023): it is the substrate those specs
  build on, and the golden entry vectors it freezes are the record every
  later release must reproduce byte for byte.
---

# 017: Ledger entry and the hash-linked DAG

## 1. Purpose

Thesis §4.2: the ledger is a per-repository signed, hash-linked event DAG.
Every fact about a repository (a revision, a comment, an attestation, a key
rotation) is carried by an entry of the one shape fixed here. Because the
hash of an entry is what parents reference, what signatures cover, and what
every replica reconciles on (110), its byte layout is the single most
consequential decision in the corpus and is frozen at tier 1 (bootstrap
anchor `hash-stability`). This spec exists to make that decision once,
explicitly, with vectors.

## 2. Territory

`crates/hqgit-ledger` as founded here: the manifest, `lib.rs`, `entry.rs`
(the shape, encoding, signing, hashing), `dag.rs` (the in-memory DAG), and
`verify.rs` (chain verification and the `IssuerResolver` seam), plus the
`tests/` subtree. Additively: entry vectors under spec 011's golden vector
directory and one fuzz target in spec 012's workspace. Persistence is spec
021 (`store.rs`, `repo.rs`); total order and clock generation are spec 018;
the fact and derived-state split is spec 019.

## 3. Behavior

- **B-1 (shape).** `Entry { parents: Vec<EntryHash>, issuer: KeyId, hlc:
  Hlc, payload: Cid, sig: Signature, extra: BTreeMap<String, Value> }`.
  `EntryHash` is a newtype over `Hash`. `parents` MUST be sorted ascending
  and free of duplicates; a constructor enforces it and a decoder rejects a
  violation as `Error::Validation`. `extra` is the unknown-field
  preservation map from spec 011: fields a newer writer added and this
  reader does not know, carried verbatim and included in the hash.
- **B-2 (canonical bytes).** The canonical bytes of an entry are the spec
  011 DAG-CBOR encoding of the map `{ "extra"?, "hlc", "issuer",
  "parents", "payload", "sig" }` with keys in canonical order, `extra`
  flattened into the top-level map (its keys MUST NOT collide with the five
  known keys; a collision is `Error::Validation`), and omitted when empty.
- **B-3 (signing preimage).** The signed payload is the canonical bytes of
  the entry with `sig` absent, under `SignDomain("ledger.entry")` through
  spec 010's preimage rule. `Entry::sign(unsigned, &impl Signer) -> Entry`
  is the only way to produce a signed entry; `Entry::unsigned_bytes()` is
  exposed for verification and for the fuzz target.
- **B-4 (hash).** `EntryHash = Hash::of(canonical_bytes_with_sig)`. The
  hash covers the signature: re-signing the same body yields a distinct
  entry. `Entry::hash()` is memoized nowhere; it is recomputed from bytes so
  no cached value can drift from the encoding.
- **B-5 (genesis).** A DAG has exactly one genesis entry: `parents` empty,
  `payload` a `Cid` of the spec 013 `RepoGenesis` object (namespace id,
  created-by principal, schema versions). Every other entry MUST have at
  least one parent. `Dag::new(genesis)` is the only constructor.
- **B-6 (append).** `Dag::append(entry) -> Result<EntryHash, Error>`
  requires every parent to be present (`Error::NotFound` naming the missing
  parent otherwise), requires `entry.hlc` to be strictly greater than every
  parent's `hlc` (`Error::Validation`), rejects a duplicate hash as a no-op
  `Ok`, and updates the head set (entries with no known child). `heads()`
  returns the head set sorted by hash. `ancestors(hash)` and
  `contains(hash)` are read-only. The DAG holds entries only; payload
  content is resolved through the object store (013), never stored inline.
- **B-7 (verify).** `verify(dag, resolver: &impl IssuerResolver) ->
  Result<VerifyReport, Error>` walks every entry in hash order and checks:
  the recomputed hash equals the stored key; every parent exists; the
  signature verifies against the `Verifier` the resolver returns for
  `(issuer, hlc)`; the clock rule of B-6; the genesis rule of B-5; the
  payload `Cid` codec is `DagCbor` or `Raw`. The report lists every failure
  with the entry hash and the rule; it never stops at the first. The
  `IssuerResolver` trait is `fn verifier_for(&self, key: &KeyId, at: &Hlc)
  -> Result<Box<dyn Verifier>, Error>`; this spec ships
  `StaticResolver(BTreeMap<KeyId, PublicKey>)`. Spec 060 supplies the
  rotation-aware resolver.
- **B-8 (no ambient input).** Nothing in this crate reads a clock, the
  environment, or iterates a `HashMap`. Fuzzing (B-10) and the source guard
  of spec 010 FR-003 both apply to this crate.
- **B-9 (golden vectors).** The vectors directory gains
  `ledger/entry-genesis.json`, `ledger/entry-two-parents.json`, and
  `ledger/entry-with-extra.json`, each holding the unsigned fields, the
  seed, the expected canonical bytes (hex), the expected signature, and the
  expected hash. A test re-derives every field. These vectors are frozen
  (constitution VIII): a change is a schema MAJOR.
- **B-10 (fuzz target).** `entry_hash_stable` decodes arbitrary bytes as an
  entry; on success it re-encodes and asserts byte identity and hash
  identity, and asserts that `parents` came out sorted and deduplicated.

## 4. Functional requirements

- **FR-001.** Every function in `entry.rs`, `dag.rs`, and `verify.rs` is a
  pure function of its arguments; the only trait objects are the `Signer`,
  `Verifier`, and `IssuerResolver` seams.
- **FR-002.** Tests cover: shape validation (unsorted or duplicate parents,
  colliding `extra` key); canonical bytes against the vectors; sign then
  verify round trip; hash covers the signature; genesis rules; append with a
  missing parent, a non-monotonic clock, and a duplicate; head tracking
  across a fork and a merge entry; verify reporting every failure class in
  one report; unknown fields surviving a decode-encode round trip and
  changing the hash.
- **FR-003.** Property tests (`proptest`, added to
  `[workspace.dependencies]`) assert that for random valid entries decode
  and encode are inverse and the hash is stable across two encodes.
- **FR-004.** The crate depends on `hqgit-types` and `hqgit-object` only
  within the workspace.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-ledger --locked` passes, vectors included.
- **AC-2.** With `cargo-fuzz` installed, `cargo fuzz run entry_hash_stable
  -- -max_total_time=20` finds no failure.
- **AC-3.** `spec-spine index` discovers `hqgit-ledger` bound to this spec
  and `index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Persistence (021), total order and clock generation (018), the fact and
derived-state split (019), commitments and tombstones (020), rotation-aware
issuer resolution (060), replication (110).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-ledger --locked
cargo test -p hqgit-types --locked golden
```
