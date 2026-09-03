---
id: "019-facts-and-derived-state"
title: "Facts and derived state: the immutable fact envelope, the registry seam, LWW registers, and the reserved sequence CRDT"
status: approved
kind: "kernel"
domain: "l1-ledger"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: critical
wave: 1
depends_on:
  - "018-deterministic-total-order"
establishes:
  - "crates/hqgit-ledger/src/facts.rs"
  - "crates/hqgit-ledger/src/derived.rs"
  - "crates/hqgit-ledger/src/crdt/mod.rs"
  - "crates/hqgit-ledger/src/crdt/lww.rs"
  - "crates/hqgit-ledger/src/crdt/sequence.rs"
  - "crates/hqgit-ledger/tests/facts.rs"
extends:
  - { spec: "017-ledger-entry-dag", unit: "crates/hqgit-ledger/src/lib.rs", nature: additive }
  - { spec: "017-ledger-entry-dag", unit: "crates/hqgit-ledger/Cargo.toml", nature: additive }
summary: >
  The separation the thesis calls critical: facts are immutable events that
  never conflict and merge by set union; derived state is the mutable
  projection and the only thing that needs convergence. This spec fixes
  the fact envelope every entry payload decodes to, the registry seam
  through which domain crates declare fact kinds and validators while
  unknown kinds stay preserved and opaque, the last-writer-wins register
  keyed by hybrid logical clock that every derived field uses unless a
  spec argues otherwise, the fold that rebuilds any derived state from
  zero, and the sequence CRDT interface reserved for collaborative text
  and nothing else. It keeps the CRDT surface near five percent of the
  domain, which is the difference between a system that can be reasoned
  about and one that cannot.
---

# 019: Facts and derived state

## 1. Purpose

Thesis §4.2, constitution VII, bootstrap anchor `facts-immutable`: the
place most projects go wrong is reaching for CRDTs everywhere. Every
domain noun above this spec (024 changes, 026 threads, 028 issues, 060
identities, 104 ownership) is expressed as facts that never conflict and
derived fields that converge by one rule. This spec supplies both halves
and the fold that joins them under the total order of 018, so that a
domain spec adds a fact kind and a view, never a merge algorithm.

## 2. Territory

`facts.rs` (the envelope, the registry seam, decoding an entry payload to
a fact), `derived.rs` (the `DerivedState` trait and the fold), and
`crdt/` (`lww.rs` the register, `sequence.rs` the reserved interface and
reference implementation, `mod.rs` the exports), plus `tests/facts.rs`, in
the crate 017 founded. The `collab-text` cargo feature is declared in the
crate manifest.

## 3. Behavior

- **B-1 (`FactEnvelope`).** An entry's payload object (013, codec
  `DagCbor`) decodes to `FactEnvelope { kind: FactKind, v: u16, body:
  Value, extra }` through spec 011's `Envelope` with `kind` prefixed
  `"fact."` on the wire. `FactKind(String)` is a lowercase, dot-namespaced
  identifier matching `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$` (`"change.
  revision_submitted"`, `"ledger.tombstone"`); a malformed kind is
  `Error::Validation`. `Fact { entry: EntryHash, issuer: KeyId, at: Hlc,
  envelope: FactEnvelope }` is the decoded form the fold consumes; it is
  immutable and carries no setters.
- **B-2 (`FactRegistry`).** `FactRegistry::new()` plus `fn register(&mut
  self, kind: FactKind, max_v: u16, validator: Box<dyn FactValidator>) ->
  Result<(), Error>` (`Error::Validation` on a duplicate kind) and `fn
  validate(&self, envelope: &FactEnvelope) -> Result<Validated, Error>`.
  `trait FactValidator { fn validate(&self, v: u16, body: &Value) ->
  Result<(), Error>; }`. Domain crates register their kinds in a function
  they export (023 `register_domain`, 060 `register_trust`); the CLI and
  server call every registrar at startup. `Validated` is `Known |
  Unknown`: a kind not in the registry is NOT an error, it is preserved
  verbatim, folded as opaque (B-5), and counted, so an older reader
  survives a newer writer (constitution VIII's forward compatibility
  applied to facts).
- **B-3 (set union).** The fact set of a repository is the set of
  `(EntryHash, Fact)` pairs; two replicas' fact sets merge by union with no
  conflict resolution because every fact is keyed by an entry hash that
  covers its content and its signer (017 B-4). A test asserts that folding
  the union in total order is independent of which replica contributed
  which fact.
- **B-4 (`LwwRegister`).** `LwwRegister<T: Canonical + Ord> { value:
  Option<T>, at: Hlc, by: KeyId }` with `fn set(&mut self, value: T, at:
  Hlc, by: KeyId)` applying the write only when `(at, by) > (self.at,
  self.by)`, and `fn merge(&mut self, other: &Self)` as the same rule. The
  tiebreak on `by` after `at` makes merge commutative, associative, and
  idempotent (a test proves all three on random sequences). Every derived
  scalar field in the domain MUST be an `LwwRegister` unless its owning
  spec's Behavior section argues for another instrument (028's add-wins
  label set is the one such argument in wave 1).
- **B-5 (`DerivedState` and the fold).** `trait DerivedState: Default {
  fn apply(&mut self, fact: &Fact) -> Result<(), Error>; fn on_unknown(&mut
  self, fact: &Fact) { let _ = fact; } }`; `fold<S: DerivedState>(order:
  &[EntryHash], facts: &dyn FactSource) -> Result<S, Error>` starts from
  `S::default()` and applies every fact in the given total order (018),
  routing unknown kinds to `on_unknown`, so any state is rebuildable from
  zero (constitution VI). `trait FactSource { fn fact(&self, entry:
  &EntryHash) -> Result<Option<Fact>, Error>; }` is implemented by 021's
  repository; an erased payload (020) surfaces as `Fact` with `body =
  Value::Null` and `extra["erased"] = true`, which `apply` MUST tolerate.
- **B-6 (`SequenceCrdt`).** `crdt/sequence.rs` declares `trait
  SequenceCrdt { type Id: Canonical + Ord; fn insert(&mut self, after:
  Option<&Self::Id>, ch: char, at: Hlc, by: KeyId) -> Self::Id; fn delete
  (&mut self, id: &Self::Id, at: Hlc, by: KeyId); fn materialize(&self) ->
  String; fn merge(&mut self, other: &Self); }` and, behind `#[cfg(feature
  = "collab-text")]`, an RGA reference implementation `Rga` with ids
  `(Hlc, KeyId)`. This interface is reserved for genuinely collaborative
  text (constitution VII); a doc comment names the rule and no other
  module in the workspace may depend on the feature without a spec
  amendment that argues the case.
- **B-7 (no ambient input).** The fold reads no clock; the `Hlc` it orders
  by is entry data.

## 4. Functional requirements

- **FR-001.** `facts.rs`, `derived.rs`, and `crdt/` are pure over their
  inputs; the only trait objects are `FactValidator` and `FactSource`.
- **FR-002.** Tests cover: `FactKind` grammar accept and reject cases;
  registry duplicate refusal; validation of a known kind with a failing
  validator; an unknown kind preserved through decode, fold, and re-encode
  with the hash unchanged; union commutativity (B-3); LWW commutativity,
  associativity, idempotence, and tiebreak on `by`; a fixture
  `DerivedState` with three fields folded under twenty seeded
  permutations of the same facts to one state; the erased-payload case;
  `Rga` insert, delete, materialize, and merge under permutation (feature
  on).
- **FR-003.** A property test asserts LWW merge is a join (commutative,
  associative, idempotent) on random write sequences.
- **FR-004.** The `collab-text` feature is off by default and `cargo build
  --workspace --locked` never enables it; a test in the default build
  asserts `Rga` is not linked.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-ledger --locked facts` passes.
- **AC-2.** `cargo test -p hqgit-ledger --locked --features collab-text`
  passes.
- **AC-3.** `spec-spine index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

The domain's own fact kinds and their validators (023); erasure and the
tombstone fact kind (020); persistence of facts and the repository-backed
`FactSource` (021); projections that persist folded state (080); any use
of the sequence CRDT by a product feature (none is planned; a future spec
must argue it).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-ledger --locked facts
cargo test -p hqgit-ledger --locked --features collab-text
```
