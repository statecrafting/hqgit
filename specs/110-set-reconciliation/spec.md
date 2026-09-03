---
id: "110-set-reconciliation"
title: "Range-based set reconciliation over entry hashes: fingerprints, the split protocol, and ingest"
status: approved
kind: "kernel"
domain: "l1-ledger"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 8
depends_on:
  - "021-local-repository"
establishes:
  - "crates/hqgit-sync/Cargo.toml"
  - "crates/hqgit-sync/src/lib.rs"
  - "crates/hqgit-sync/src/reconcile.rs"
  - "crates/hqgit-sync/src/fingerprint.rs"
  - "crates/hqgit-sync/src/protocol.rs"
  - "crates/hqgit-sync/tests/"
  - "crates/hqgit-sync/testdata/protocol/"
extends:
  # The repository gains the verified ingest path foreign entries take.
  - { spec: "021-local-repository", unit: "crates/hqgit-ledger/src/repo.rs", nature: additive }
summary: >
  Thesis §4.2: replication is range-based set reconciliation, with the
  Willow protocol as the prior art. Two replicas of one repository hold
  sets of entry hashes ordered by (hlc, hash); each side fingerprints a
  range, and where fingerprints differ the range is split until the
  difference is small enough to exchange item lists. Because an entry's
  hlc is strictly greater than its parents' (017), that same order is a
  topological order, so missing entries append in order with no extra
  sort. This spec founds hqgit-sync with the fingerprint, the pure
  reconciler state machine, the canonical message vocabulary, a
  transport-agnostic Channel seam, and the ingest path that verifies every
  foreign entry before it touches the ledger. Payload objects are fetched
  lazily and verified through spec 015. The transport is spec 111.
---

# 110: Set reconciliation

## 1. Purpose

Facts merge by set union (019 B-3), so replication is set reconciliation
and nothing more: neither side needs the other's history, only the
difference. Range fingerprinting converges in a number of rounds
logarithmic in the set size regardless of how the difference is
distributed, works over any transport, and needs no per-peer log
position, which is what makes federation (112) between hosts that have
never met tractable. Everything received is verified through the ledger's
own rules before it is stored, so a lying peer can withhold but never
inject.

## 2. Territory

`crates/hqgit-sync` as founded here: the manifest (workspace dependencies
`hqgit-types`, `hqgit-object`, `hqgit-ledger`; `proptest` as a dev
dependency), `lib.rs`, `fingerprint.rs`, `reconcile.rs`, `protocol.rs`,
the `tests/` subtree, and frozen message vectors under
`testdata/protocol/`. Additively: `Repository::ingest_entry` in spec
021's `repo.rs`. QUIC, peer identity, and the object source are spec 111;
peer registries and the sync verbs are spec 112.

## 3. Behavior

- **B-1 (key space).** An item is `Item { hlc: Hlc, hash: EntryHash }`,
  ordered lexicographically (010 B-8's `Ord` on `Hlc`, then hash bytes).
  `Bound` is the same pair used as a range endpoint; `Bound::MIN` is all
  zero bytes and `Bound::MAX` all `0xFF`. A `Range { lo: Bound, hi: Bound
  }` is half-open `[lo, hi)`; the whole space is `[MIN, MAX)`. serde
  encodes a bound as the two-element array `[hlc, hash]`.
- **B-2 (fingerprint).** `Fingerprint { xor: [u8; 32], count: u64 }`
  where `xor` is the bytewise XOR of every item's hash in the range and
  `count` the item count; the empty range is all zero. `Fingerprint::of(
  items)` and `combine(&self, other)` (XOR and add) make a range's
  fingerprint the combination of its sub-ranges', which is what lets a
  split be answered without re-hashing. The threat model is stated, not
  hidden: a peer who controls its own item set can withhold entries
  regardless of fingerprinting, so the fingerprint drives which ranges
  are exchanged and never what is accepted (B-7 accepts only verified
  entries). Withholding is defended by syncing with more than one peer
  (112), not by the fingerprint.
- **B-3 (messages).** `protocol.rs` defines `Message`, each variant a
  spec 011 `Envelope` with `kind = "sync.<variant>"`, `v = 1`, and an
  `extra` map: `RangeFingerprint { id: u32, range, fp: Fingerprint }`;
  `RangeItems { id: u32, range, items: Vec<Item>, want: bool }` (the
  sender's items in the range; `want` asks for the receiver's items in
  return); `Done { fp: Fingerprint }` (the sender's fingerprint of the
  whole space, sent when it has no open ranges); `WantEntries { hashes:
  Vec<EntryHash> }`; `Entries { entries: Vec<Vec<u8>> }` (canonical entry
  bytes, 017 B-2); and `Abort { reason: String }`. Constants:
  `ITEM_THRESHOLD = 32` (a range with at most this many local items is
  answered with `RangeItems`, never split), `SPLIT = 4` (a larger range
  splits into this many sub-ranges at local item-count quantiles),
  `MAX_ITEMS = 4096` per `RangeItems`, `MAX_ENTRIES = 256` per `Entries`,
  `MAX_ROUNDS = 64`. Ids are per-session sequence numbers.
- **B-4 (`EntryIndex`).** `trait EntryIndex { fn fingerprint(&self, range:
  &Range) -> Fingerprint; fn items(&self, range: &Range, limit: usize) ->
  Vec<Item>; fn split(&self, range: &Range, parts: u8) -> Vec<Range>; fn
  has(&self, hash: &EntryHash) -> bool; }`. `MemoryIndex(BTreeSet<Item>)`
  implements it and is what `LedgerIndex::load(store: &dyn EntryStore)
  -> Result<MemoryIndex, Error>` builds from 021's `iter_all` and `get`
  at session start (a persistent by-hlc index is a later optimization,
  noted in 021's territory).
- **B-5 (reconciler).** `Reconciler::new(index: &dyn EntryIndex, role:
  Role::{Initiator, Responder})`; `start(&mut self) -> Vec<Message>` (the
  initiator sends `RangeFingerprint` for the whole space; the responder
  sends nothing); `handle(&mut self, msg: &Message) -> Result<Step,
  Error>` with `Step { send: Vec<Message>, missing: Vec<Item>, done: bool
  }`. On `RangeFingerprint`: equal local fingerprint yields no reply for
  that range; otherwise if local items in the range are at most
  `ITEM_THRESHOLD` reply `RangeItems { want: true }`, else reply one
  `RangeFingerprint` per sub-range of `split`. On `RangeItems`: every
  received item not in the index is added to `missing`; if `want`, reply
  `RangeItems { want: false }` with local items in the range. `done`
  becomes true when both sides have sent `Done` and the two whole-space
  fingerprints, each combined with the items that side is about to
  receive, agree; disagreement is `Error::Validation("reconciliation
  did not converge")`. A peer exceeding `MAX_ROUNDS`, sending an id it
  never received, a range outside the one it was asked about, or a
  `RangeItems` whose items do not reproduce the fingerprint it claimed
  for that range earlier is `Error::Validation` naming the rule, and the
  session aborts. The reconciler is a pure state machine: no I/O, no
  clock.
- **B-6 (`Channel` and the runner).** `trait Channel { fn send(&mut self,
  msg: &Message) -> Result<(), Error>; fn recv(&mut self) -> Result<
  Option<Message>, Error>; }`. `run(reconciler, channel: &mut dyn
  Channel) -> Result<Outcome, Error>` drives the exchange to `done`, then
  requests missing entries in batches of `MAX_ENTRIES` with `WantEntries`
  in `(hlc, hash)` order and ingests each `Entries` reply (B-7) before
  requesting the next, returning `Outcome { rounds: u32, sent: u64,
  received: u64, ingested: u32, missing_payloads: u32 }`. `MemoryChannel
  ::pair()` gives two connected in-process channels for tests and for 111
  to wrap.
- **B-7 (ingest).** `Repository::ingest_entry(&mut self, bytes: &[u8],
  resolver: &dyn IssuerResolver) -> Result<Ingested, Error>` (additive on
  021) decodes the entry (017 B-1, rejecting a malformed shape), checks
  that the recomputed hash equals the hash advertised in the item and the
  `hlc` equals the advertised one (`Error::Validation`), verifies the
  signature through the resolver (`Error::Crypto`), requires every parent
  to be present (`Error::NotFound` naming it; the runner requests parents
  first because `(hlc, hash)` order lists them first), and appends
  through 021's `EntryStore` inside one transaction. `Ingested::{Appended,
  AlreadyPresent}`. It never puts a payload object: an entry whose
  payload resolves `Missing` (020 B-1) is a legitimate replica state.
- **B-8 (payloads).** `fetch_payloads(repo, entries: &[EntryHash], source:
  &dyn ObjectSource) -> Result<u32, Error>` fetches each entry's payload
  through 015 `fetch_into`, skipping cids the `TombstoneSet` (020 B-5)
  marks erased and cids already present, and returns the count still
  missing. Verification is 015's: nothing unverified enters the store.
- **B-9 (no ambient input).** The crate reads no clock, no environment,
  no randomness; `BTreeMap` and `BTreeSet` are the only collections on
  the ordered paths.

## 4. Functional requirements

- **FR-001.** `testdata/protocol/` holds one vector per message variant
  (`{ description, input, canonical_hex, hash }`, spec 011's layout) and
  a recorded two-party transcript; a test replays the transcript through
  two reconcilers and asserts every emitted message byte for byte. These
  vectors are frozen (constitution VIII).
- **FR-002.** Tests cover: fingerprint combination equals whole-range
  computation; equal sets finish in one round with no items exchanged;
  two random sets of `n` items differing in `d` complete with rounds at
  most `2 * ceil(log4(n)) + 2` for `n` in {1, 100, 10,000} and `d` in
  {1, n/2, n} (proptest over seeds); every B-5 refusal, including a peer
  whose `RangeItems` contradict its earlier fingerprint; `run` over
  `MemoryChannel::pair` ingests in parent-first order against two 021
  repositories initialized from one genesis; ingest refuses a bad
  signature, a wrong advertised hlc, and a missing parent, leaving the
  store unchanged; `fetch_payloads` skips erased cids.
- **FR-003.** 021's FR-003 public-API test gains `ingest_entry` as the
  fourth write method; no other mutable path is added.
- **FR-004.** The crate depends on `hqgit-types`, `hqgit-object`, and
  `hqgit-ledger` only within the workspace; its manifest carries
  `[package.metadata.spec-spine] spec = "110-set-reconciliation"`.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-sync --locked` passes, vectors included.
- **AC-2.** `cargo test -p hqgit-ledger --locked repo` passes with the
  ingest path added.
- **AC-3.** `spec-spine index` discovers `hqgit-sync` bound to this spec
  and `index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Transport, peer identity, and capability checks (111); peer discovery,
registries, scheduling, and the `hq sync` verbs (112); quarantine
admission of foreign entries (112 over 094); a persistent by-hlc index
(a 021 amendment when measured to matter); encrypted namespace keys (020
`KeyProvider`; ciphertext replicates as bytes).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-sync --locked
cargo test -p hqgit-ledger --locked repo
```
