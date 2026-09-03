---
id: "023-domain-fact-vocabulary"
title: "Domain fact vocabulary: the typed facts, their ids, and their validation"
status: approved
kind: "kernel"
domain: "l2-domain"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 1
depends_on:
  - "019-facts-and-derived-state"
establishes:
  - "crates/hqgit-domain/Cargo.toml"
  - "crates/hqgit-domain/src/lib.rs"
  - "crates/hqgit-domain/src/facts.rs"
  - "crates/hqgit-domain/src/validate.rs"
  - "crates/hqgit-domain/src/ids.rs"
  - "crates/hqgit-domain/tests/"
extends:
  # The frozen fact-kind and id vectors join the golden corpus 011 established.
  - { spec: "011-canonical-encoding", unit: "crates/hqgit-types/testdata/vectors/", nature: additive }
summary: >
  Founds hqgit-domain, the L2 crate every collaboration noun lives in, and
  fixes the fact vocabulary the ledger carries: one DomainFact variant per
  kind (change, review, attestation, issue, ownership, mirror), each with a
  frozen namespaced kind string, a versioned body schema encoded through
  the spec 011 canonical codec, and unknown-field preservation. Ids are
  never counters: a ChangeId, RevisionId, ThreadId, CommentId, IssueId, or
  AttestationId is the BLAKE3 hash of the canonical bytes of the fact that
  brought it into being, so an id is content-derived and identical on every
  replica. Structural validation runs on decode, before any fold sees a
  fact, and the crate registers every kind with spec 019's FactRegistry.
  Later specs add variants and semantics by extending facts.rs; this spec
  is the vocabulary, not the behavior.
---

# 023: Domain fact vocabulary

## 1. Purpose

Thesis §4.3 names the nouns (Change, Revision, Anchor, Review,
Attestation, Issue) and constitution VII says every one of them is carried
by immutable facts that merge by set union. Before any noun can have
behavior, the facts that describe it need a fixed kind string, a fixed body
shape, and a fixed way to mint an identity that two replicas agree on
without talking. This spec founds the domain crate to answer those three
questions once. Everything a later domain spec does is a fold over the
vocabulary fixed here, and the kind strings are frozen because they reach
hashed bytes (constitution VIII).

## 2. Territory

`crates/hqgit-domain` as founded here: the manifest (workspace deps
`hqgit-types`, `hqgit-object`, `hqgit-ledger`; no others), `lib.rs`,
`facts.rs` (the `DomainFact` enum and body structs), `validate.rs`
(structural validation and registry wiring), `ids.rs` (the id newtypes and
minting), and the `tests/` subtree. Additively: a `domain/` vector set in
spec 011's golden directory. Later specs in this crate (024 onward) add
modules and `extends` this spec's `lib.rs` and `facts.rs`.

## 3. Behavior

- **B-1 (the enum).** `DomainFact` is a closed enum with one variant per
  kind. Each variant wraps a body struct that derives spec 011's
  `Canonical`, carries `extra: BTreeMap<String, Value>` for unknown-field
  preservation, and encodes as a `FactEnvelope { kind, v: 1, body }` (spec
  019). `DomainFact::kind(&self) -> &'static str` and `DomainFact::encode()
  -> FactEnvelope`; `DomainFact::decode(&FactEnvelope) -> Result<DomainFact,
  Error>` returns `Error::Schema` for an unknown `v` and `Error::Validation`
  for a malformed body. An envelope whose kind is not in the table is not a
  domain fact and is left to the registry's opaque path.
- **B-2 (frozen kinds).** The kind strings and required body fields:

  | kind | body |
  |---|---|
  | `change.opened` | `opened_by: Principal, title: String, nonce: Nonce` |
  | `change.field_set` | `change: ChangeId, field: ChangeField, value: Value` |
  | `change.revision_submitted` | `change: ChangeId, tree: Cid, base: Cid, parent_revision: Option<RevisionId>, message: String, submitted_by: Principal, nonce: Nonce` |
  | `change.merged` | `change: ChangeId, revision: RevisionId` |
  | `change.abandoned` | `change: ChangeId, reason: String` |
  | `change.depends_on` | `change: ChangeId, on: ChangeId, at_revision: RevisionId` (semantics in 050) |
  | `review.thread_opened` | `change: ChangeId, at_revision: RevisionId, anchor: Option<Value>, opened_by: Principal, nonce: Nonce` |
  | `review.comment_posted` | `thread: ThreadId, author: Principal, body: Cid, reply_to: Option<CommentId>, nonce: Nonce` |
  | `review.thread_resolved` | `thread: ThreadId, resolved: bool` |
  | `review.approval_issued` | `change: ChangeId, revision: RevisionId, attestation: AttestationId` |
  | `attestation.issued` | `attestation: Cid, subject: Hash, predicate: String, issuer: Principal` |
  | `issue.opened` | `opened_by: Principal, title: String, nonce: Nonce` |
  | `issue.field_set` | `issue: IssueId, field: IssueField, value: Value` |
  | `issue.closed` | `issue: IssueId, reason: String` |
  | `issue.link_added` | `issue: IssueId, target: LinkTarget` |
  | `ownership.declared` | body fixed by 104 (reserved here as `Value`) |
  | `ownership.revoked` | body fixed by 104 (reserved here as `Value`) |
  | `mirror.observed` | `source: String, external_id: String, kind: String, payload: Cid` (semantics in 040) |

  `ChangeField` is `Title | Description`; `IssueField` is `Title | State |
  Assignee | Milestone | LabelAdd | LabelRemove`; `LinkTarget` is
  `Change(ChangeId) | Issue(IssueId)`. The `anchor` and issue `value`
  fields are opaque canonical `Value`s here; specs 025 and 028 give them
  types. A reserved body (`ownership.*`) decodes as an opaque `Value` until
  its owning spec extends this file.
- **B-3 (ids are content-derived).** `ids.rs` defines newtypes over `Hash`:
  `ChangeId`, `RevisionId`, `ThreadId`, `CommentId`, `IssueId`,
  `AttestationId`, plus `Nonce([u8; 16])`. For every opening fact
  (`change.opened`, `change.revision_submitted`, `review.thread_opened`,
  `review.comment_posted`, `issue.opened`) the id of the thing it opens is
  `Hash::of(canonical bytes of the fact body)`, exposed as
  `DomainFact::minted_id() -> Option<Hash>`. The `nonce` is supplied by the
  caller (the CLI draws it from OS randomness) so two otherwise identical
  openings mint distinct ids; the domain crate never reads randomness.
  `AttestationId` is minted by spec 027 from the attestation's own bytes.
  `Display` for every id is 64 lowercase hex; `short()` is the first 12.
- **B-4 (validation on decode).** `validate::check(&DomainFact) ->
  Result<(), Error>` runs after decode and before any fold: required
  strings non-empty and free of control characters, `title` at most 512
  bytes and `reason` and `message` at most 64 KiB, every `Cid` codec
  consistent with its role (`body` and `payload` are `Raw` or `DagCbor`,
  `attestation` and `tree` and `base` are `DagCbor`), every referenced id
  32 bytes, `extra` keys not colliding with known keys. A failure is
  `Error::Validation` naming the kind and the field.
- **B-5 (registry wiring).** `register_domain(registry: &mut
  FactRegistry)` registers every kind of B-2 with a validator that decodes
  and checks; a kind registered twice is `Error::Config`. Unknown kinds are
  never registered here, so they stay opaque in a fold (spec 019).
- **B-6 (fold contract).** Domain views (024 onward) implement spec 019's
  `DerivedState` and receive `(fact, at: &Hlc)`. A body that needs to know
  who acted carries a `Principal` field; the relation between that
  principal and the entry's issuer key is verified by the trust plane (060,
  064), never assumed by the domain.
- **B-7 (no ambient input).** Nothing in this crate reads a clock, the
  environment, randomness, or a `HashMap`; spec 010 FR-003's source guard
  applies to this crate.

## 4. Functional requirements

- **FR-001.** Every variant round-trips `encode` then `decode` to an equal
  value, with `extra` preserved and included in the canonical bytes.
- **FR-002.** The golden set `domain/fact-kinds.json` lists every kind
  string and its `v`; a test asserts the enum matches the file exactly, so
  adding or renaming a kind is a visible vector change (constitution VIII).
- **FR-003.** The golden set `domain/ids.json` records, for one fixture of
  each opening fact, the canonical body bytes and the minted id; a test
  re-derives both.
- **FR-004.** Validation tests cover each rule of B-4 with one failing
  fixture per rule and assert the error names the field.
- **FR-005.** `register_domain` on an empty registry registers exactly the
  B-2 kinds; a second call fails with `Error::Config`.
- **FR-006.** The crate depends on `hqgit-types`, `hqgit-object`, and
  `hqgit-ledger` only within the workspace, and its manifest carries
  `[package.metadata.spec-spine] spec = "023-domain-fact-vocabulary"`.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-domain --locked` passes, vectors included.
- **AC-2.** `spec-spine index` discovers `hqgit-domain` bound to this spec
  and `index coverage --fail-on-untraced` exits 0.

## 6. Out of scope

Change and revision behavior (024); anchors (025); threads and approvals
(026); the attestation object and predicates (027); issue folds (028);
stack semantics of `change.depends_on` (050); ownership bodies (104);
mirror semantics (040).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-domain --locked
cargo test -p hqgit-types --locked golden
```
