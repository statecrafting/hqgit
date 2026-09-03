---
id: "024-change-and-revision"
title: "Change and Revision: stable change identity over an ordered revision sequence"
status: approved
kind: "kernel"
domain: "l2-domain"
created: "2026-09-02"
authors: ["Bartek Kus"]
implementation: pending
risk: high
wave: 1
depends_on:
  - "023-domain-fact-vocabulary"
establishes:
  - "crates/hqgit-domain/src/change.rs"
  - "crates/hqgit-domain/src/revision.rs"
  - "crates/hqgit-domain/tests/change.rs"
extends:
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/lib.rs", nature: additive }
  - { spec: "023-domain-fact-vocabulary", unit: "crates/hqgit-domain/src/facts.rs", nature: additive }
summary: >
  The unit of change is a Change with stable identity and an ordered
  sequence of Revisions, never a mutable branch pointer (design §1.1 point
  2; Gerrit's Change-Id, then jj and Sapling). A revision is a tree hash
  plus its base; a force-push is a new revision and destroys nothing; the
  revision number is derived from the ledger's total order so every
  replica numbers identically. This spec adds the Change and Revision
  types, the pure fact builders the CLI and the server call, and the
  ChangeView fold with its state machine (Open, Merged, Abandoned) and
  lineage queries. What changed since a reviewer last looked becomes a
  query in spec 050; this spec makes the sequence it runs over exist.
---

# 024: Change and Revision

## 1. Purpose

Thesis §4.3: "`Change` (stable identity) with ordered `Revision`s, each a
tree hash plus base". GitHub's pull request is a branch name whose history
is rewritten under the reviewer; hqgit's change is an identity that
accumulates revisions. This spec gives the domain that noun, as facts (023)
and a fold (019), so review threads (026), approvals (027), stacks (050),
and semantic deltas (051) have a stable thing to hang off.

## 2. Territory

`change.rs` (the `Change` type, `ChangeState`, the `ChangeView` fold, the
builders) and `revision.rs` (the `Revision` type and lineage queries) in
`crates/hqgit-domain`, plus `tests/change.rs`. Additively: the crate's
`lib.rs` re-exports and the `change.field_set` decoder in `facts.rs`
gaining typed values for `ChangeField`.

## 3. Behavior

- **B-1 (`Change`).** `Change { id: ChangeId, opened_by: Principal, title:
  LwwRegister<String>, description: LwwRegister<String>, state:
  ChangeState, revisions: Vec<RevisionId>, merged_revision:
  Option<RevisionId>, opened_at: Hlc, warnings: Vec<ChangeWarning> }`.
  `ChangeState` is `Open | Merged | Abandoned`. `title` and `description`
  are LWW registers (spec 019) fed by `change.field_set`; the opening title
  is the register's initial value at the opening fact's `Hlc`.
- **B-2 (`Revision`).** `Revision { id: RevisionId, change: ChangeId,
  number: u32, tree: Cid, base: Cid, parent_revision: Option<RevisionId>,
  message: String, submitted_by: Principal, at: Hlc, post_terminal: bool }`.
  `tree` and `base` are spec 013 `Tree` cids; `base` is the tree the change
  was made against (for a git-backed repo, the base commit's tree via 031).
  `number` is 1-based and derived: the position of the revision among the
  change's revisions in total order (018), never carried in a fact, so
  concurrent submissions on two replicas receive the same numbers once
  synced.
- **B-3 (builders are pure).** `open_change(opened_by, title, nonce) ->
  (ChangeId, DomainFact)`, `set_field(change, field, value) ->
  DomainFact`, `submit_revision(view, change, tree, base, parent_revision,
  message, submitted_by, nonce) -> Result<(RevisionId, DomainFact),
  Error>`, `abandon(view, change, reason) -> Result<DomainFact, Error>`,
  `mark_merged(view, change, revision) -> Result<DomainFact, Error>`. They
  return facts for the caller to append (021); they never touch a store.
  The write-path checks: `submit_revision` and `abandon` refuse a change
  that is not `Open` (`Error::Validation`); `submit_revision` refuses a
  `parent_revision` that is not a revision of the same change;
  `mark_merged` refuses a revision that is not the change's.
- **B-4 (the fold accepts everything).** `ChangeView` implements
  `DerivedState`. Facts are immutable and never rejected by a fold
  (constitution VII): a `change.revision_submitted` arriving after
  `change.abandoned` in total order is recorded with `post_terminal: true`
  and a `ChangeWarning::RevisionAfterTerminal`; a `parent_revision` the
  view has not seen yields `ChangeWarning::DanglingParent`; a second
  `change.merged` or `change.abandoned` on a terminal change yields
  `ChangeWarning::DuplicateTerminal` and the first (in total order) wins.
  Warnings are part of the view so a UI can show them; they are never
  silently dropped.
- **B-5 (state machine).** `Open` moves to `Merged` on `change.merged` and
  to `Abandoned` on `change.abandoned`; both are terminal. There is no
  reopen: a new change is opened instead, and a `change.field_set` on a
  terminal change still updates the register (metadata edits on closed
  work are ordinary).
- **B-6 (queries).** `ChangeView::get(&ChangeId) -> Option<&Change>`,
  `changes() -> impl Iterator<Item = &Change>` in id order, `revision(&
  RevisionId) -> Option<&Revision>`, `latest_revision(&ChangeId) ->
  Option<&Revision>`, `revision_lineage(&RevisionId) -> Vec<RevisionId>`
  (following `parent_revision` to the root, newest first, cycle-safe by
  visited set), `revisions_of(&ChangeId) -> &[RevisionId]` in number order.
- **B-7 (determinism).** The view is a pure function of the ordered fact
  sequence; feeding the same facts in any order that respects 018's total
  order yields an equal view, and feeding them in a different total order
  is not a supported input (the runner, 080, guarantees the order).

## 4. Functional requirements

- **FR-001.** Tests: opening mints a stable id across two builds from the
  same inputs; revision numbers are monotonic and match total-order
  position under three interleavings of two submitters; `post_terminal`
  and each `ChangeWarning` variant; every state transition and every
  refused transition in B-3 and B-5; `revision_lineage` on a chain of four
  and on a dangling parent; `latest_revision` after concurrent submissions.
- **FR-002.** A property test (`proptest`) folds a random valid fact
  sequence through two views built from two permutations that agree on
  total order and asserts equality.
- **FR-003.** No builder or view function performs I/O; the only inputs are
  facts, ids, and values.
- **FR-004.** `lib.rs` re-exports `Change`, `ChangeState`, `ChangeView`,
  `Revision`, and the builders; nothing else in the crate changes.

## 5. Acceptance criteria

- **AC-1.** `cargo test -p hqgit-domain --locked change` passes.
- **AC-2.** A fixture sequence (open, two submits, field set, merge, late
  submit) folds to the golden view recorded in `tests/change.rs`, warnings
  included.

## 6. Out of scope

Working-tree snapshots and git bases (031, 033); stacks and interdiff
(050); merge decisions (068, 076); rendering (081, 095).

## 7. Resolved decisions

None yet. The build session records D-n entries here for choices this spec
is silent on (date, provenance, the decision, the alternative rejected).

## Verification

```verify:cli
cargo test -p hqgit-domain --locked change
```
